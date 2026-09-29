import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleCreateIdentifierCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-identifier",
        abstract: "Registers a new App/Bundle Identifier with optional capabilities on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "App/Bundle identifier (e.g. com.example.app).")
    var bundleId: String?

    @Option(name: .shortAndLong, help: "Alternative flag for bundle identifier.")
    var appIdentifier: String?

    @Option(name: .shortAndLong, help: "Description or name of the App Identifier.")
    var name: String?

    @Option(name: .customLong("platform"), help: "Platform: universal, ios, macos. Defaults to universal.")
    var platform: String = "universal"

    @Option(name: .shortAndLong, help: "Comma-separated list of capabilities to enable (e.g. push-notifications,in-app-purchase).")
    var capabilities: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let rawTarget = bundleId ?? appIdentifier
        guard let targetIdentifier = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines), !targetIdentifier.isEmpty else {
            print("Error: ".red.bold + "Missing bundle identifier. Provide -b, --bundle-id <bundle-id>.")
            return
        }

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        let parsedPlatform: Components.Schemas.BundleIdPlatform
        switch platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "universal": parsedPlatform = .UNIVERSAL
        case "ios": parsedPlatform = .IOS
        case "macos", "mac": parsedPlatform = .MAC_OS
        default:
            print("Error: ".red.bold + "Unsupported platform '\(platform)'. Supported: universal, ios, macos.")
            return
        }

        // Parse capabilities if provided
        var capabilitiesToEnable: [Components.Schemas.CapabilityType] = []
        if let capsString = capabilities?.trimmingCharacters(in: .whitespacesAndNewlines), !capsString.isEmpty {
            let capItems = capsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for item in capItems {
                guard let cap = parseCapability(item) else {
                    print("Error: ".red.bold + "Unknown capability '\(item)'.")
                    print("💡 Supported capabilities include: push-notifications, in-app-purchase, game-center, icloud, sign-in-with-apple, app-groups, associated-domains, apple-pay, healthkit, homekit, sirikit, wallet, nfc, data-protection, etc.".yellow)
                    return
                }
                capabilitiesToEnable.append(cap)
            }
        }

        let identifierName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🚀 Registering App Identifier '\(targetIdentifier)' on Apple Developer Portal...".dim)

        let created: Components.Schemas.BundleId
        do {
            created = try await service.createBundleId(
                identifier: targetIdentifier,
                name: identifierName,
                platform: parsedPlatform
            )
        } catch {
            print("Error: ".red.bold + "Failed to create App Identifier: \(error.localizedDescription)")
            return
        }

        let createdName = created.attributes?.name ?? (identifierName ?? targetIdentifier)
        let portalId = created.id
        let platformStr = created.attributes?.platform?.rawValue ?? parsedPlatform.rawValue
        let seedId = created.attributes?.seedId ?? "-"

        print("\n✓ App Identifier registered successfully!".green.bold)
        print("  • Identifier: ".cyan + "\(targetIdentifier)".bold)
        print("  • Name: ".cyan + "\(createdName)")
        print("  • Portal ID: ".cyan + "\(portalId)")
        print("  • Platform: ".cyan + "\(platformStr)")
        print("  • Prefix/Seed ID: ".cyan + "\(seedId)")

        // Enable capabilities if requested
        if !capabilitiesToEnable.isEmpty {
            print("\n⚙️  Configuring capabilities...".dim)
            var enabledCount = 0
            for cap in capabilitiesToEnable {
                do {
                    try await service.addCapability(bundleIdPortalId: portalId, capabilityType: cap)
                    enabledCount += 1
                    print("  ✓ Enabled: ".green + "\(cap.rawValue)".bold)
                } catch {
                    print("  ❌ Failed to enable '\(cap.rawValue)': \(error.localizedDescription)".red)
                }
            }
            print("\n✓ Capabilities configured: \(enabledCount)/\(capabilitiesToEnable.count) enabled.".green.bold)
        }
        print("")
    }

    // MARK: - Helpers

    private func parseCapability(_ raw: String) -> Components.Schemas.CapabilityType? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "push", "push-notifications", "push_notifications":
            return .PUSH_NOTIFICATIONS
        case "iap", "in-app-purchase", "in_app_purchase":
            return .IN_APP_PURCHASE
        case "game-center", "game_center":
            return .GAME_CENTER
        case "icloud":
            return .ICLOUD
        case "sign-in-with-apple", "apple-id-auth", "apple_id_auth", "apple-sign-in":
            return .APPLE_ID_AUTH
        case "app-groups", "app_groups":
            return .APP_GROUPS
        case "associated-domains", "associated_domains":
            return .ASSOCIATED_DOMAINS
        case "apple-pay", "apple_pay":
            return .APPLE_PAY
        case "healthkit":
            return .HEALTHKIT
        case "homekit":
            return .HOMEKIT
        case "sirikit":
            return .SIRIKIT
        case "wallet", "passbook":
            return .WALLET
        case "nfc", "nfc-tag-reading", "nfc_tag_reading":
            return .NFC_TAG_READING
        case "maps":
            return .MAPS
        case "personal-vpn", "personal_vpn":
            return .PERSONAL_VPN
        case "network-extensions", "network_extensions":
            return .NETWORK_EXTENSIONS
        case "access-wifi-information", "wifi-info", "access_wifi_information":
            return .ACCESS_WIFI_INFORMATION
        case "data-protection", "data_protection":
            return .DATA_PROTECTION
        case "autofill-credential-provider", "autofill_credential_provider":
            return .AUTOFILL_CREDENTIAL_PROVIDER
        case "classkit":
            return .CLASSKIT
        case "multipath":
            return .MULTIPATH
        case "inter-app-audio", "inter_app_audio":
            return .INTER_APP_AUDIO
        case "wireless-accessory-configuration", "wireless_accessory_configuration":
            return .WIRELESS_ACCESSORY_CONFIGURATION
        case "system-extension-install", "system_extension_install":
            return .SYSTEM_EXTENSION_INSTALL
        case "user-management", "user_management":
            return .USER_MANAGEMENT
        case "coremedia-hls-low-latency", "coremedia_hls_low_latency":
            return .COREMEDIA_HLS_LOW_LATENCY
        case "network-custom-protocol", "network_custom_protocol":
            return .NETWORK_CUSTOM_PROTOCOL
        case "hot-spot", "hot_spot":
            return .HOT_SPOT
        default:
            let rawEnum = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_").uppercased()
            return Components.Schemas.CapabilityType(rawValue: rawEnum)
        }
    }
}
