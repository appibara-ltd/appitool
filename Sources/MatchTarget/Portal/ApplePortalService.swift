import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

/// Interacts with the Apple Developer Portal (via AppleServices / AppStoreService) to validate,
/// generate, and revoke (nuke) certificates and provisioning profiles for Match.
public final class ApplePortalService: Sendable {
    private let appStoreService: AppStoreService

    public init(
        keyId: String,
        issuerId: String,
        key: String
    ) throws {
        self.appStoreService = try AppStoreService(
            keyId: keyId,
            issuerId: issuerId,
            key: key
        )
    }

    // MARK: - Certificate Validation

    /// Fetches all active certificate IDs from Apple Developer Portal matching the given profile type.
    public func fetchActiveCertificateIds(for type: MatchProfileType) async throws -> Set<String> {
        try await appStoreService.fetchActiveCertificateIds(limit: 200)
    }

    // MARK: - Certificate Generation

    /// Generates a local 2048-bit RSA key, creates a CSR, signs it on Apple Developer Portal via AppleServices,
    /// and packages the resulting `.cer` and passwordless `.p12` data.
    public func createCertificate(
        type: MatchProfileType,
        teamName: String? = nil
    ) async throws -> (id: String, cerData: Data, p12Data: Data) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let keyPath = tempDir.appendingPathComponent("private_key.pem").path
        let cerPath = tempDir.appendingPathComponent("certificate.cer").path
        let p12Path = tempDir.appendingPathComponent("certificate.p12").path

        let cn = teamName ?? "Appitool Match \(type.rawValue.capitalized)"

        // 1. Generate RSA 2048-bit Private Key and CSR using swift-crypto
        let csrResult: CSRGenerator.CSRResult
        do {
            csrResult = try CSRGenerator.generate(commonName: cn)
        } catch {
            throw MatchError.keychainError("Failed to generate RSA private key and CSR: \(error.localizedDescription)")
        }

        // Write private key to temp file for openssl pkcs12 consumption
        try Data(csrResult.privateKeyPEM.utf8).write(to: URL(fileURLWithPath: keyPath))

        // 2. Submit CSR to Apple Developer Portal via AppleServices
        let targetType: Components.Schemas.CertificateType
        switch type {
        case .development:
            targetType = .DEVELOPMENT
        case .adhoc, .appstore, .enterprise:
            targetType = .DISTRIBUTION
        case .developerId:
            targetType = .DEVELOPER_ID_APPLICATION
        }

        let instance: Components.Schemas.Certificate
        do {
            instance = try await appStoreService.createCertificate(csrContent: csrResult.csrPEM, certificateType: targetType)
        } catch {
            throw MatchError.keychainError(error.localizedDescription)
        }

        let certId = instance.id
        guard let base64Cert = instance.attributes?.certificateContent,
              let cerData = Data(base64Encoded: base64Cert, options: [.ignoreUnknownCharacters]) else {
            throw MatchError.keychainError("Apple Developer Portal returned invalid certificate content.")
        }

        try cerData.write(to: URL(fileURLWithPath: cerPath))

        // 3. Package .pem certificate and private key into passwordless .p12 using P12Exporter
        let p12Data: Data
        do {
            p12Data = try P12Exporter.export(
                cerData: cerData,
                privateKeyPEM: csrResult.privateKeyPEM,
                password: ""
            )
            try p12Data.write(to: URL(fileURLWithPath: p12Path))
        } catch {
            throw MatchError.keychainError("Failed to export .p12 certificate archive: \(error.localizedDescription)")
        }

        return (certId, cerData, p12Data)
    }

    // MARK: - Provisioning Profile Generation

    /// Ensures bundle ID and devices exist, then generates and downloads the provisioning profile via AppleServices.
    public func createProfile(
        type: MatchProfileType,
        platform: MatchPlatform = .ios,
        bundleId: String,
        certificateId: String
    ) async throws -> (name: String, uuid: String, profileData: Data) {
        // 1. Resolve or create bundle ID on portal via AppleServices
        let portalBundleId: String
        do {
            portalBundleId = try await appStoreService.resolveOrCreateBundleId(bundleId: bundleId)
        } catch {
            throw MatchError.profileNotFound(bundleId: bundleId, type: .appstore, expectedPath: "Portal Bundle ID")
        }

        // 2. Resolve devices if development or adhoc
        var deviceIds: [String] = []
        if type == .development || type == .adhoc {
            deviceIds = try await fetchActiveDeviceIds(for: type, platform: platform)
            if deviceIds.isEmpty {
                let devName = (platform == .tvos) ? "Apple TV" : ((platform == .macos || platform == .catalyst) ? "Mac" : "iOS (iPhone/iPad)")
                throw MatchError.profileParsingFailed("Cannot create \(type.rawValue) profile: No enabled \(devName) devices registered on Apple Developer Portal. \(type.rawValue.capitalized) profiles require at least one registered device.")
            }
        }

        // 3. Determine profile type enum and profile name
        let targetAppleProfileType = appleProfileType(type: type, platform: platform)
        let profileName = "match \(type.profilePrefix) \(bundleId)\(platform.portalNameSuffix)"

        // 4. Submit Profile creation request via AppleServices
        do {
            let res = try await appStoreService.createProfile(
                name: profileName,
                profileType: targetAppleProfileType,
                bundleIdPortalId: portalBundleId,
                certificateId: certificateId,
                deviceIds: deviceIds
            )
            return (res.name, res.uuid, res.profileData)
        } catch {
            throw MatchError.profileParsingFailed(error.localizedDescription)
        }
    }

    /// Fetches all active, non-invalidated profile UUIDs from Apple Developer Portal for the given type and platform.
    public func fetchActiveProfileUUIDs(for type: MatchProfileType, platform: MatchPlatform = .ios) async throws -> Set<String> {
        let profiles = try await appStoreService.fetchProfiles(limit: 200)

        var activeUUIDs = Set<String>()
        for profile in profiles {
            let profTypeStr = profile.attributes?.profileType?.rawValue ?? ""
            let state = profile.attributes?.profileState
            if matchesProfileType(profTypeStr: profTypeStr, target: type, platform: platform) && state == .ACTIVE {
                if let uuid = profile.attributes?.uuid {
                    activeUUIDs.insert(uuid)
                }
            }
        }
        return activeUUIDs
    }

    // MARK: - Nuke (Revocation & Deletion)

    /// Revokes all certificates and deletes all provisioning profiles of the given type and platform from Apple Developer Portal.
    public func nuke(type: MatchProfileType, platform: MatchPlatform = .ios) async throws -> (revokedCertIds: [String], deletedProfileIds: [String]) {
        var revokedCerts: [String] = []
        var deletedProfiles: [String] = []

        // 1. Revoke certificates via AppleServices
        let certTypes = appleCertificateTypes(for: type)
        let certs = try await appStoreService.fetchCertificates(types: certTypes)
        for cert in certs {
            if try await appStoreService.deleteCertificate(id: cert.id) {
                revokedCerts.append(cert.id)
            }
        }

        // 2. Delete profiles via AppleServices
        let profiles = try await appStoreService.fetchProfiles()
        for profile in profiles {
            let profTypeStr = profile.attributes?.profileType?.rawValue ?? ""
            if matchesProfileType(profTypeStr: profTypeStr, target: type, platform: platform) {
                if try await appStoreService.deleteProfile(id: profile.id) {
                    deletedProfiles.append(profile.id)
                }
            }
        }

        return (revokedCerts, deletedProfiles)
    }

    // MARK: - Device and Type Helpers

    private func fetchActiveDeviceIds(for type: MatchProfileType, platform: MatchPlatform) async throws -> [String] {
        let platformFilter: Operations.devices_getCollection.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload = (platform == .macos || platform == .catalyst) ? .MAC_OS : .IOS
        let devices = try await appStoreService.fetchDevices(platform: platformFilter)

        return devices.compactMap { device in
            guard let cls = device.attributes?.deviceClass else { return device.id }
            switch platform {
            case .ios:
                // Only iPhones, iPads, iPods, and Apple Vision Pro
                if cls == .MAC || cls == .APPLE_TV || cls == .APPLE_WATCH { return nil }
            case .tvos:
                // Only Apple TVs
                if cls != .APPLE_TV { return nil }
            case .macos, .catalyst:
                // Only Macs
                if cls != .MAC { return nil }
            }
            return device.id
        }
    }

    private func appleProfileType(
        type: MatchProfileType,
        platform: MatchPlatform
    ) -> Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload {
        switch platform {
        case .ios:
            switch type {
            case .appstore: return .IOS_APP_STORE
            case .adhoc: return .IOS_APP_ADHOC
            case .development: return .IOS_APP_DEVELOPMENT
            case .enterprise: return .IOS_APP_INHOUSE
            case .developerId: return .MAC_APP_DIRECT
            }
        case .tvos:
            switch type {
            case .appstore: return .TVOS_APP_STORE
            case .adhoc: return .TVOS_APP_ADHOC
            case .development: return .TVOS_APP_DEVELOPMENT
            case .enterprise: return .TVOS_APP_INHOUSE
            case .developerId: return .MAC_APP_DIRECT
            }
        case .macos:
            switch type {
            case .appstore: return .MAC_APP_STORE
            case .adhoc: return .MAC_APP_DEVELOPMENT
            case .development: return .MAC_APP_DEVELOPMENT
            case .enterprise: return .MAC_APP_DIRECT
            case .developerId: return .MAC_APP_DIRECT
            }
        case .catalyst:
            switch type {
            case .appstore: return .MAC_CATALYST_APP_STORE
            case .adhoc: return .MAC_CATALYST_APP_DEVELOPMENT
            case .development: return .MAC_CATALYST_APP_DEVELOPMENT
            case .enterprise: return .MAC_CATALYST_APP_DIRECT
            case .developerId: return .MAC_CATALYST_APP_DIRECT
            }
        }
    }

    private func appleCertificateTypes(for type: MatchProfileType) -> [Operations.certificates_getCollection.Input.Query.filter_lbrack_certificateType_rbrack_PayloadPayload] {
        switch type {
        case .development:
            return [.DEVELOPMENT, .IOS_DEVELOPMENT]
        case .adhoc, .appstore, .enterprise:
            return [.DISTRIBUTION, .IOS_DISTRIBUTION]
        case .developerId:
            return [.DEVELOPER_ID_APPLICATION]
        }
    }

    private func matchesProfileType(profTypeStr: String, target: MatchProfileType, platform: MatchPlatform) -> Bool {
        let prefixMatches: Bool
        switch platform {
        case .ios: prefixMatches = profTypeStr.hasPrefix("IOS_")
        case .tvos: prefixMatches = profTypeStr.hasPrefix("TVOS_")
        case .macos: prefixMatches = profTypeStr.hasPrefix("MAC_APP_")
        case .catalyst: prefixMatches = profTypeStr.hasPrefix("MAC_CATALYST_")
        }
        guard prefixMatches else { return false }

        switch target {
        case .appstore: return profTypeStr.contains("APP_STORE") || profTypeStr.contains("STORE")
        case .adhoc: return profTypeStr.contains("ADHOC")
        case .development: return profTypeStr.contains("DEVELOPMENT")
        case .enterprise: return profTypeStr.contains("INHOUSE") || profTypeStr.contains("DIRECT")
        case .developerId: return profTypeStr.contains("DIRECT")
        }
    }
}
