import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleListCapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-capabilities",
        abstract: "Lists all available App Identifier capabilities or shows capabilities enabled for a specific App ID."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Application Bundle Identifier (e.g. com.example.app) to inspect enabled capabilities.")
    var bundleId: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        // If bundle ID is specified, query Apple Developer Portal for enabled capabilities
        if let targetBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !targetBundleId.isEmpty {
            guard let service = try appleCredentials.makeService() else {
                print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
                return
            }

            print("🔍 Fetching App Identifier '\(targetBundleId)' from Apple Developer Portal...".dim)
            let bundleIds = try await service.fetchBundleIds(limit: 20, identifier: targetBundleId)
            guard let matched = bundleIds.first(where: { $0.attributes?.identifier == targetBundleId }) else {
                print("ℹ️ App Identifier '\(targetBundleId)' was not found on Apple Developer Portal.".yellow)
                return
            }

            let portalId = matched.id
            let capabilities = try await service.fetchCapabilities(bundleIdPortalId: portalId)

            if capabilities.isEmpty {
                print("\nℹ️ No custom capabilities are currently enabled for '\(targetBundleId)'.".yellow)
                return
            }

            print("\nEnabled capabilities for '\(targetBundleId)':".bold)
            for cap in capabilities {
                let typeStr = cap.attributes?.capabilityType?.rawValue ?? "UNKNOWN"
                let cliKey = typeStr.lowercased().replacingOccurrences(of: "_", with: "-")
                print("  • ".green + "\(cliKey)".bold + " [API: \(typeStr), ID: \(cap.id)]".dim)
            }
            print("")
            return
        }

        // Otherwise, list all supported capabilities that can be passed to create-identifier
        print("\nSupported capabilities for " + "apple create-identifier --capabilities <list>".cyan.bold + ":\n")

        let items: [(category: String, key: String, enumName: String, desc: String)] = [
            ("Push & Communication", "push-notifications", "PUSH_NOTIFICATIONS", "APNs remote push notifications (alias: push)"),
            ("Push & Communication", "inter-app-audio", "INTER_APP_AUDIO", "Real-time audio streaming with host apps"),
            ("Push & Communication", "coremedia-hls-low-latency", "COREMEDIA_HLS_LOW_LATENCY", "Low-Latency HTTP Live Streaming (HLS)"),
            ("Authentication & Security", "sign-in-with-apple", "APPLE_ID_AUTH", "Sign in with Apple authentication (aliases: apple-sign-in, apple-id-auth)"),
            ("Authentication & Security", "data-protection", "DATA_PROTECTION", "Hardware-based file-level encryption"),
            ("Authentication & Security", "autofill-credential-provider", "AUTOFILL_CREDENTIAL_PROVIDER", "AutoFill password manager extensions"),
            ("App Integration & Domains", "associated-domains", "ASSOCIATED_DOMAINS", "Universal Links, App Clips, Web Credentials"),
            ("App Integration & Domains", "app-groups", "APP_GROUPS", "Shared container access for App Extensions & Widgets"),
            ("App Integration & Domains", "icloud", "ICLOUD", "CloudKit database and iCloud document storage"),
            ("App Integration & Domains", "game-center", "GAME_CENTER", "Game Center leaderboards, achievements & multiplayer"),
            ("App Integration & Domains", "in-app-purchase", "IN_APP_PURCHASE", "In-App Purchases & StoreKit (alias: iap)"),
            ("Payments & Wallet", "apple-pay", "APPLE_PAY", "Apple Pay in-app payment processing"),
            ("Payments & Wallet", "wallet", "WALLET", "Passes, tickets, and boarding passes in Apple Wallet (alias: passbook)"),
            ("Hardware & Networking", "nfc-tag-reading", "NFC_TAG_READING", "Near Field Communication (NFC) tag reading (alias: nfc)"),
            ("Hardware & Networking", "access-wifi-information", "ACCESS_WIFI_INFORMATION", "Access current Wi-Fi network SSID/BSSID (alias: wifi-info)"),
            ("Hardware & Networking", "hot-spot", "HOT_SPOT", "Wi-Fi HotSpot network configuration"),
            ("Hardware & Networking", "personal-vpn", "PERSONAL_VPN", "Personal VPN tunnels and connections"),
            ("Hardware & Networking", "network-extensions", "NETWORK_EXTENSIONS", "Custom network tunnels, DNS proxies, and content filters"),
            ("Hardware & Networking", "network-custom-protocol", "NETWORK_CUSTOM_PROTOCOL", "Custom network protocol extensions"),
            ("Hardware & Networking", "multipath", "MULTIPATH", "Multipath TCP for concurrent Wi-Fi and Cellular data"),
            ("Hardware & Networking", "wireless-accessory-configuration", "WIRELESS_ACCESSORY_CONFIGURATION", "MFi accessory Wi-Fi configuration"),
            ("Health & Home", "healthkit", "HEALTHKIT", "HealthKit health and fitness records"),
            ("Health & Home", "homekit", "HOMEKIT", "HomeKit smart home automation & accessories"),
            ("Siri & Maps & System", "sirikit", "SIRIKIT", "SiriKit voice shortcuts and intents"),
            ("Siri & Maps & System", "maps", "MAPS", "MapKit turn-by-turn routing and directions"),
            ("Siri & Maps & System", "classkit", "CLASSKIT", "ClassKit student progress & educational activities"),
            ("Siri & Maps & System", "system-extension-install", "SYSTEM_EXTENSION_INSTALL", "macOS system extensions & driver extensions"),
            ("Siri & Maps & System", "user-management", "USER_MANAGEMENT", "Multi-user management on Shared iPad"),
        ]

        var currentCategory = ""
        for item in items {
            if item.category != currentCategory {
                currentCategory = item.category
                print("[\(currentCategory)]".bold)
            }
            print("  • ".cyan + "\(item.key)".bold + " [\(item.enumName)]".dim)
            print("    \(item.desc)".dim)
        }

        print("\n💡 Usage example:")
        print("  appitool apple create-identifier -b \"com.example.app\" -c \"push-notifications,sign-in-with-apple\"".green)
        print("\n💡 To view enabled capabilities on an existing App Identifier:")
        print("  appitool apple list-capabilities -b \"com.example.app\"".yellow)
        print("")
    }
}
