import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleCreateProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-profile",
        abstract: "Creates and downloads a provisioning profile on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Application Bundle Identifier (e.g. com.example.app).")
    var bundleId: String

    @Option(name: .shortAndLong, help: "Provisioning profile name. Defaults to 'match <type> <bundle-id>' if omitted.")
    var name: String?

    @Option(name: .shortAndLong, help: "Profile distribution type: appstore, development, adhoc, enterprise, developer_id. Defaults to appstore.")
    var type: String = "appstore"

    @Option(name: .customLong("platform"), help: "Target platform: ios, macos, tvos, catalyst. Defaults to ios.")
    var platform: String = "ios"

    @Option(name: .shortAndLong, help: "Certificate Portal ID. If omitted, the first valid active matching certificate is used.")
    var certificateId: String?

    @Option(name: .shortAndLong, help: "Comma-separated device Portal IDs for development/adhoc profiles. If omitted, all enabled devices are included.")
    var deviceIds: String?

    @Option(name: .shortAndLong, help: "Output file path to save the generated provisioning profile.")
    var output: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        let cleanBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleId.isEmpty else {
            print("Error: ".red.bold + "Bundle ID cannot be empty.")
            return
        }

        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Resolve Profile Type
        let targetProfileType: Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload
        do {
            targetProfileType = try mapProfileType(type: normalizedType, platform: normalizedPlatform)
        } catch {
            print("Error: ".red.bold + error.localizedDescription)
            return
        }

        // 2. Resolve Bundle ID Portal ID
        print("🔍 Resolving App Identifier '\(cleanBundleId)' on Apple Developer Portal...".dim)
        let portalBundleId: String
        do {
            portalBundleId = try await service.resolveOrCreateBundleId(bundleId: cleanBundleId)
        } catch {
            print("Error: ".red.bold + "Failed to resolve or create Bundle ID '\(cleanBundleId)': \(error.localizedDescription)")
            return
        }

        // 3. Resolve Certificate ID
        let resolvedCertId: String
        if let explicitCertId = certificateId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitCertId.isEmpty {
            resolvedCertId = explicitCertId
        } else {
            print("🔍 Locating valid certificate on Apple Developer Portal...".dim)
            let certTypes = appleCertificateTypes(for: normalizedType, platform: normalizedPlatform)
            let certs = try await service.fetchCertificates(types: certTypes)
            guard let activeCert = certs.first else {
                print("Error: ".red.bold + "No active \(normalizedType) certificate found on Apple Developer Portal. Please specify -c, --certificate-id or create a certificate first.")
                return
            }
            resolvedCertId = activeCert.id
            let certName = activeCert.attributes?.name ?? activeCert.id
            print("  ✓ Selected certificate: ".green + "\(certName)".bold + " [Portal ID: \(resolvedCertId)]".dim)
        }

        // 4. Resolve Devices (for development / adhoc)
        var resolvedDeviceIds: [String] = []
        let isDevOrAdhoc = normalizedType == "development" || normalizedType == "dev" || normalizedType == "adhoc" || normalizedType == "ad-hoc"
        if let explicitDevices = deviceIds?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitDevices.isEmpty {
            resolvedDeviceIds = explicitDevices.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if isDevOrAdhoc {
            print("🔍 Fetching registered devices for \(normalizedPlatform)...".dim)
            let platformFilter: Operations.devices_getCollection.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload = (normalizedPlatform == "macos" || normalizedPlatform == "mac" || normalizedPlatform == "catalyst") ? .MAC_OS : .IOS
            let allDevices = try await service.fetchDevices(platform: platformFilter)
            resolvedDeviceIds = filterDevices(allDevices, for: normalizedPlatform)
            if resolvedDeviceIds.isEmpty {
                print("Error: ".red.bold + "Development/AdHoc profiles require at least one registered device, but no enabled devices were found on Apple Developer Portal.")
                return
            }
            print("  ✓ Included \(resolvedDeviceIds.count) registered device(s)".green)
        }

        // 5. Determine Profile Name
        let profileName: String
        if let customName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !customName.isEmpty {
            profileName = customName
        } else {
            let typeLabel: String
            switch normalizedType {
            case "development", "dev": typeLabel = "Development"
            case "adhoc", "ad-hoc": typeLabel = "AdHoc"
            case "enterprise", "inhouse": typeLabel = "InHouse"
            case "developer-id", "developer_id", "direct": typeLabel = "DeveloperID"
            default: typeLabel = "AppStore"
            }
            let platformSuffix = (normalizedPlatform == "ios") ? "" : " \(normalizedPlatform)"
            profileName = "match \(typeLabel) \(cleanBundleId)\(platformSuffix)"
        }

        // 6. Create Profile
        print("🚀 Creating provisioning profile '\(profileName)'...".bold)
        do {
            let created = try await service.createProfile(
                name: profileName,
                profileType: targetProfileType,
                bundleIdPortalId: portalBundleId,
                certificateId: resolvedCertId,
                deviceIds: resolvedDeviceIds
            )

            print("\n✓ Provisioning profile created successfully!".green.bold)
            print("  • Name: ".cyan + "\(created.name)".bold)
            print("  • Portal ID: ".cyan + "\(created.id)".bold)
            print("  • UUID: ".cyan + "\(created.uuid)".bold)
            print("  • Type: ".cyan + "\(targetProfileType.rawValue)")
            print("  • Bundle ID: ".cyan + "\(cleanBundleId)")

            // 7. Write to output file if requested
            if let outPath = output?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
                let expandedPath = (outPath as NSString).expandingTildeInPath
                let fileURL = URL(fileURLWithPath: expandedPath)
                let parentDir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try created.profileData.write(to: fileURL)
                print("  💾 Saved to: ".green.bold + "\(fileURL.path)")
            } else {
                print("ℹ️ To save the profile to a file, re-run with -o, --output <path>.".dim)
            }
            print("")
        } catch {
            print("Error: ".red.bold + "Failed to create provisioning profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func mapProfileType(
        type: String,
        platform: String
    ) throws -> Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload {
        switch platform {
        case "ios":
            switch type {
            case "appstore", "app-store": return .IOS_APP_STORE
            case "adhoc", "ad-hoc": return .IOS_APP_ADHOC
            case "development", "dev": return .IOS_APP_DEVELOPMENT
            case "enterprise", "inhouse": return .IOS_APP_INHOUSE
            default:
                throw ValidationError("Unsupported profile type '\(type)' for iOS. Supported: appstore, development, adhoc, enterprise")
            }
        case "tvos":
            switch type {
            case "appstore", "app-store": return .TVOS_APP_STORE
            case "adhoc", "ad-hoc": return .TVOS_APP_ADHOC
            case "development", "dev": return .TVOS_APP_DEVELOPMENT
            case "enterprise", "inhouse": return .TVOS_APP_INHOUSE
            default:
                throw ValidationError("Unsupported profile type '\(type)' for tvOS. Supported: appstore, development, adhoc, enterprise")
            }
        case "macos", "mac":
            switch type {
            case "appstore", "app-store": return .MAC_APP_STORE
            case "adhoc", "ad-hoc", "development", "dev": return .MAC_APP_DEVELOPMENT
            case "enterprise", "developer-id", "developer_id", "direct": return .MAC_APP_DIRECT
            default:
                throw ValidationError("Unsupported profile type '\(type)' for macOS. Supported: appstore, development, adhoc, developer_id")
            }
        case "catalyst":
            switch type {
            case "appstore", "app-store": return .MAC_CATALYST_APP_STORE
            case "adhoc", "ad-hoc", "development", "dev": return .MAC_CATALYST_APP_DEVELOPMENT
            case "enterprise", "developer-id", "developer_id", "direct": return .MAC_CATALYST_APP_DIRECT
            default:
                throw ValidationError("Unsupported profile type '\(type)' for Catalyst. Supported: appstore, development, adhoc, developer_id")
            }
        default:
            throw ValidationError("Unsupported platform '\(platform)'. Supported: ios, macos, tvos, catalyst")
        }
    }

    private func appleCertificateTypes(
        for type: String,
        platform: String
    ) -> [Operations.certificates_getCollection.Input.Query.filter_lbrack_certificateType_rbrack_PayloadPayload] {
        switch type {
        case "development", "dev":
            if platform == "macos" || platform == "mac" {
                return [.DEVELOPMENT, .MAC_APP_DEVELOPMENT]
            }
            return [.DEVELOPMENT, .IOS_DEVELOPMENT]
        case "adhoc", "ad-hoc", "appstore", "app-store", "enterprise", "inhouse":
            if platform == "macos" || platform == "mac" {
                return [.DISTRIBUTION, .MAC_APP_DISTRIBUTION]
            }
            return [.DISTRIBUTION, .IOS_DISTRIBUTION]
        case "developer-id", "developer_id", "direct":
            return [.DEVELOPER_ID_APPLICATION]
        default:
            return [.DISTRIBUTION, .IOS_DISTRIBUTION]
        }
    }

    private func filterDevices(_ devices: [Components.Schemas.Device], for platform: String) -> [String] {
        return devices.compactMap { device in
            guard let cls = device.attributes?.deviceClass else { return device.id }
            switch platform {
            case "ios":
                if cls != .IPHONE && cls != .IPAD && cls != .IPOD { return nil }
            case "tvos":
                if cls != .APPLE_TV { return nil }
            case "macos", "mac", "catalyst":
                if cls != .MAC { return nil }
            default:
                break
            }
            return device.id
        }
    }
}
