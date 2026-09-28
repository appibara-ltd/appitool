import Foundation
import OpenAPIURLSession
import OpenAPIRuntime
import AppStoreConnectAPI

/// Interacts with the Apple Developer Portal (via App Store Connect API) to validate,
/// generate, and revoke (nuke) certificates and provisioning profiles.
public final class ApplePortalService: Sendable {
    private let client: Client

    public init(
        keyId: String,
        issuerId: String,
        key: String,
        transport: any ClientTransport = URLSessionTransport()
    ) throws {
        let middleware = try AppStoreConnectAuthMiddleware(
            keyId: keyId,
            issuerId: issuerId,
            key: key
        )
        let configuration = Configuration(dateTranscoder: FlexibleDateTranscoder())
        self.client = Client(
            serverURL: try Servers.Server1.url(),
            configuration: configuration,
            transport: transport,
            middlewares: [middleware]
        )
    }

    // MARK: - Certificate Validation

    /// Fetches all active certificate IDs from Apple Developer Portal matching the given profile type.
    public func fetchActiveCertificateIds(for type: MatchProfileType) async throws -> Set<String> {
        let response = try await client.certificates_getCollection(query: .init(
            limit: 200
        ))

        switch response {
        case .ok(let okResponse):
            guard case .json(let collection) = okResponse.body else {
                return []
            }
            return Set(collection.data.map(\.id))
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            print("⚠️ [Match] Failed to query active certificates: \(msg)".yellow)
            return []
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            print("⚠️ [Match] Forbidden querying active certificates: \(msg)".yellow)
            return []
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            print("⚠️ [Match] Unauthorized querying active certificates: \(msg)".yellow)
            return []
        default:
            return []
        }
    }

    // MARK: - Certificate Generation

    /// Generates a local 2048-bit RSA key, creates a CSR, signs it on Apple Developer Portal,
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
        let csrPath = tempDir.appendingPathComponent("request.csr").path
        let cerPath = tempDir.appendingPathComponent("certificate.cer").path
        let p12Path = tempDir.appendingPathComponent("certificate.p12").path

        let cn = teamName ?? "Appitool Match \(type.rawValue.capitalized)"

        // 1. Generate RSA 2048-bit Private Key and CSR
        let reqProcess = Process()
        reqProcess.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        reqProcess.arguments = [
            "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath,
            "-out", csrPath,
            "-subj", "/CN=\(cn)/C=US"
        ]
        reqProcess.standardInput = FileHandle.nullDevice
        try reqProcess.run()
        reqProcess.waitUntilExit()

        guard reqProcess.terminationStatus == 0,
              let csrContent = try? String(contentsOfFile: csrPath, encoding: .utf8) else {
            throw MatchError.keychainError("Failed to generate RSA private key and CSR.")
        }

        // 2. Submit CSR to Apple Developer Portal
        let targetType: Components.Schemas.CertificateType
        switch type {
        case .development:
            targetType = .DEVELOPMENT
        case .adhoc, .appstore, .enterprise:
            targetType = .DISTRIBUTION
        case .developerId:
            targetType = .DEVELOPER_ID_APPLICATION
        }

        let createPayload = Components.Schemas.CertificateCreateRequest(
            data: .init(
                _type: .certificates,
                attributes: .init(
                    csrContent: csrContent,
                    certificateType: targetType
                )
            )
        )

        let response = try await client.certificates_createInstance(body: .json(createPayload))
        let instance: Components.Schemas.Certificate
        switch response {
        case .created(let createdResponse):
            guard case .json(let createdInstance) = createdResponse.body else {
                throw MatchError.keychainError("Apple Developer Portal returned invalid certificate response.")
            }
            instance = createdInstance.data
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw MatchError.keychainError("Apple API Bad Request: \(msg)")
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw MatchError.keychainError("Apple API Forbidden: \(msg)")
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw MatchError.keychainError("Apple API Conflict: \(msg)")
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw MatchError.keychainError("Apple API Unprocessable Content: \(msg)")
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw MatchError.keychainError("Apple API Unauthorized: \(msg)")
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw MatchError.keychainError("Apple API Rate Limited: \(msg)")
        case .undocumented(let statusCode, _):
            throw MatchError.keychainError("Apple API returned unexpected status code \(statusCode).")
        }

        let certId = instance.id
        guard let base64Cert = instance.attributes?.certificateContent,
              let cerData = Data(base64Encoded: base64Cert, options: [.ignoreUnknownCharacters]) else {
            throw MatchError.keychainError("Apple Developer Portal returned invalid certificate content.")
        }

        try cerData.write(to: URL(fileURLWithPath: cerPath))

        // 3. Convert DER certificate to PEM format for OpenSSL pkcs12 export
        let pemCertPath = tempDir.appendingPathComponent("cert.pem").path
        let x509Process = Process()
        x509Process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        x509Process.arguments = [
            "x509", "-inform", "DER",
            "-in", cerPath,
            "-out", pemCertPath
        ]
        x509Process.standardInput = FileHandle.nullDevice
        try x509Process.run()
        x509Process.waitUntilExit()

        guard x509Process.terminationStatus == 0 else {
            throw MatchError.keychainError("Failed to convert certificate from DER to PEM.")
        }

        // 4. Package .pem certificate and private key into passwordless .p12
        let p12Process = Process()
        p12Process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p12Process.arguments = [
            "pkcs12", "-export",
            "-inkey", keyPath,
            "-in", pemCertPath,
            "-out", p12Path,
            "-passout", "pass:"
        ]
        p12Process.standardInput = FileHandle.nullDevice
        p12Process.standardOutput = FileHandle.nullDevice
        p12Process.standardError = FileHandle.nullDevice
        try p12Process.run()
        p12Process.waitUntilExit()

        guard p12Process.terminationStatus == 0,
              let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
            throw MatchError.keychainError("Failed to export .p12 certificate archive.")
        }

        return (certId, cerData, p12Data)
    }

    // MARK: - Provisioning Profile Generation

    /// Ensures bundle ID and devices exist, then generates and downloads the provisioning profile.
    public func createProfile(
        type: MatchProfileType,
        platform: MatchPlatform = .ios,
        bundleId: String,
        certificateId: String
    ) async throws -> (name: String, uuid: String, profileData: Data) {
        // 1. Resolve or create bundle ID on portal
        let portalBundleId = try await resolveOrCreateBundleId(bundleId: bundleId)

        // 2. Resolve devices if development or adhoc
        var deviceIds: [String] = []
        if type == .development || type == .adhoc {
            deviceIds = try await fetchActiveDeviceIds(for: type, platform: platform)
            if deviceIds.isEmpty {
                let devName = (platform == .tvos) ? "Apple TV" : ((platform == .macos || platform == .catalyst) ? "Mac" : "iOS (iPhone/iPad)")
                throw MatchError.profileParsingFailed("Cannot create \(type.rawValue) profile: No enabled \(devName) devices registered on Apple Developer Portal. \(type.rawValue.capitalized) profiles require at least one registered device.")
            }
        }

        // 3. Determine profile type enum
        let targetAppleProfileType = appleProfileType(type: type, platform: platform)

        let profileName = "match \(type.profilePrefix) \(bundleId)\(platform.portalNameSuffix)"

        // 4. Submit Profile creation request
        let createPayload = Components.Schemas.ProfileCreateRequest(
            data: .init(
                _type: .profiles,
                attributes: .init(
                    name: profileName,
                    profileType: targetAppleProfileType
                ),
                relationships: .init(
                    bundleId: .init(data: .init(_type: .bundleIds, id: portalBundleId)),
                    devices: deviceIds.isEmpty ? nil : .init(data: deviceIds.map { .init(_type: .devices, id: $0) }),
                    certificates: .init(data: [.init(_type: .certificates, id: certificateId)])
                )
            )
        )

        var finalProfileName = profileName
        var response = try await client.profiles_createInstance(body: .json(createPayload))

        // Fastlane Match parity: If profile name is already taken (HTTP 409 Conflict),
        // retry creating with Unix timestamp appended to make the name globally unique
        if case .conflict = response {
            let timestamp = Int(Date().timeIntervalSince1970)
            finalProfileName = "\(profileName) \(timestamp)"
            let retryPayload = Components.Schemas.ProfileCreateRequest(
                data: .init(
                    _type: .profiles,
                    attributes: .init(
                        name: finalProfileName,
                        profileType: targetAppleProfileType
                    ),
                    relationships: .init(
                        bundleId: .init(data: .init(_type: .bundleIds, id: portalBundleId)),
                        devices: deviceIds.isEmpty ? nil : .init(data: deviceIds.map { .init(_type: .devices, id: $0) }),
                        certificates: .init(data: [.init(_type: .certificates, id: certificateId)])
                    )
                )
            )
            response = try await client.profiles_createInstance(body: .json(retryPayload))
        }

        switch response {
        case .created(let createdResponse):
            guard case .json(let instance) = createdResponse.body else {
                throw MatchError.profileParsingFailed("Apple Developer Portal returned invalid response body.")
            }
            let uuid = instance.data.attributes?.uuid ?? UUID().uuidString
            guard let base64Profile = instance.data.attributes?.profileContent,
                  let profileData = Data(base64Encoded: base64Profile, options: [.ignoreUnknownCharacters]) else {
                throw MatchError.profileParsingFailed("Apple Developer Portal returned invalid profile content.")
            }
            return (finalProfileName, uuid, profileData)
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw MatchError.profileParsingFailed("Apple API Bad Request: \(msg)")
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw MatchError.profileParsingFailed("Apple API Forbidden: \(msg)")
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw MatchError.profileParsingFailed("Apple API Conflict: \(msg)")
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw MatchError.profileParsingFailed("Apple API Unprocessable Content: \(msg)")
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw MatchError.profileParsingFailed("Apple API Unauthorized: \(msg)")
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw MatchError.profileParsingFailed("Apple API Rate Limited: \(msg)")
        case .undocumented(let statusCode, _):
            throw MatchError.profileParsingFailed("Apple API returned unexpected status code \(statusCode).")
        }
    }

    /// Fetches all active, non-invalidated profile UUIDs from Apple Developer Portal for the given type and platform.
    public func fetchActiveProfileUUIDs(for type: MatchProfileType, platform: MatchPlatform = .ios) async throws -> Set<String> {
        let response = try await client.profiles_getCollection(query: .init(
            limit: 200
        ))
        guard case .ok(let okProf) = response, case .json(let profCollection) = okProf.body else {
            return []
        }

        var activeUUIDs = Set<String>()
        for profile in profCollection.data {
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

        // 1. Revoke certificates
        let certTypes = appleCertificateTypes(for: type)
        let certResponse = try await client.certificates_getCollection(query: .init(
            filter_lbrack_certificateType_rbrack_: certTypes
        ))

        if case .ok(let okCert) = certResponse, case .json(let certCollection) = okCert.body {
            for cert in certCollection.data {
                let delResp = try await client.certificates_deleteInstance(path: .init(id: cert.id))
                if case .noContent = delResp {
                    revokedCerts.append(cert.id)
                }
            }
        }

        // 2. Delete profiles
        let profResponse = try await client.profiles_getCollection(query: .init())
        if case .ok(let okProf) = profResponse, case .json(let profCollection) = okProf.body {
            for profile in profCollection.data {
                let profTypeStr = profile.attributes?.profileType?.rawValue ?? ""
                if matchesProfileType(profTypeStr: profTypeStr, target: type, platform: platform) {
                    let delResp = try await client.profiles_deleteInstance(path: .init(id: profile.id))
                    if case .noContent = delResp {
                        deletedProfiles.append(profile.id)
                    }
                }
            }
        }

        return (revokedCerts, deletedProfiles)
    }

    // MARK: - Private Helpers

    private func resolveOrCreateBundleId(bundleId: String) async throws -> String {
        let response = try await client.bundleIds_getCollection(query: .init(
            filter_lbrack_identifier_rbrack_: [bundleId]
        ))

        if case .ok(let okResp) = response, case .json(let collection) = okResp.body {
            if let matched = collection.data.first(where: { $0.attributes?.identifier == bundleId && $0.attributes?.platform != .SERVICES })
                ?? collection.data.first(where: { $0.attributes?.identifier == bundleId })
                ?? collection.data.first {
                return matched.id
            }
        }

        // Create bundle ID if not found
        let createPayload = Components.Schemas.BundleIdCreateRequest(
            data: .init(
                _type: .bundleIds,
                attributes: .init(
                    name: bundleId.replacingOccurrences(of: ".", with: " "),
                    platform: .UNIVERSAL,
                    identifier: bundleId
                )
            )
        )

        let createResp = try await client.bundleIds_createInstance(body: .json(createPayload))
        guard case .created(let createdResp) = createResp, case .json(let instance) = createdResp.body else {
            throw MatchError.profileNotFound(bundleId: bundleId, type: .appstore, expectedPath: "Portal Bundle ID")
        }
        return instance.data.id
    }

    private func fetchActiveDeviceIds(for type: MatchProfileType, platform: MatchPlatform) async throws -> [String] {
        let platformFilter: Operations.devices_getCollection.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload = (platform == .macos || platform == .catalyst) ? .MAC_OS : .IOS
        let response = try await client.devices_getCollection(query: .init(
            filter_lbrack_platform_rbrack_: [platformFilter],
            filter_lbrack_status_rbrack_: [.ENABLED]
        ))
        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            return []
        }

        return collection.data.compactMap { device in
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

    private func formatAppleErrors(_ errors: [Components.Schemas.ErrorResponse.errorsPayloadPayload]?) -> String {
        guard let errors = errors, !errors.isEmpty else { return "No detailed error provided by Apple" }
        return errors.map { "\($0.title) (\($0.code)): \($0.detail)" }.joined(separator: " | ")
    }
}

