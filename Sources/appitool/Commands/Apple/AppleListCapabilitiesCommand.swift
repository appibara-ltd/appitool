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
                Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
                return
            }

            Log("🔍 Fetching App Identifier '\(targetBundleId)' from Apple Developer Portal...".dim)
            let result: (bundleId: Components.Schemas.BundleId, capabilities: [Components.Schemas.BundleIdCapability])
            do {
                result = try await service.fetchCapabilitiesForIdentifier(identifier: targetBundleId)
            } catch {
                Log("ℹ️ App Identifier '\(targetBundleId)' was not found on Apple Developer Portal.".yellow)
                return
            }

            if result.capabilities.isEmpty {
                Log("\nℹ️ No custom capabilities are currently enabled for '\(targetBundleId)'.".yellow)
                return
            }

            Log("\nEnabled capabilities for '\(targetBundleId)':".bold)
            for cap in result.capabilities {
                let typeStr = cap.attributes?.capabilityType?.rawValue ?? "UNKNOWN"
                let cliKey = typeStr.lowercased().replacingOccurrences(of: "_", with: "-")
                Log("  • ".green + "\(cliKey)".bold + " [API: \(typeStr), ID: \(cap.id)]".dim)
            }
            Log("")
            return
        }

        // Otherwise, list all supported capabilities that can be passed to create-identifier
        Log("\nSupported capabilities for " + "apple create-identifier --capabilities <list>".cyan.bold + ":\n")

        var currentCategory = ""
        for item in AppleTypeMapper.supportedCapabilities {
            if item.category != currentCategory {
                currentCategory = item.category
                Log("[\(currentCategory)]".bold)
            }
            Log("  • ".cyan + "\(item.key)".bold + " [\(item.enumName)]".dim)
            Log("    \(item.description)".dim)
        }

        Log("\n💡 Usage example:")
        Log("  appitool apple create-identifier -b \"com.example.app\" -c \"push-notifications,sign-in-with-apple\"".green)
        Log("\n💡 To view enabled capabilities on an existing App Identifier:")
        Log("  appitool apple list-capabilities -b \"com.example.app\"".yellow)
        Log("")
    }
}
