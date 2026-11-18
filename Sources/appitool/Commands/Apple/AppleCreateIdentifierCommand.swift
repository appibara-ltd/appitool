import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleCreateIdentifierCommand: BaseCommand {
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

    func execute() async throws {
        let rawTarget = bundleId ?? appIdentifier
        guard let targetIdentifier = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines), !targetIdentifier.isEmpty else {
            Log("Error: ".red.bold + "Missing bundle identifier. Provide -b, --bundle-id <bundle-id>.")
            return
        }

        guard let service = try appleCredentials.makeService() else {
            Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        let capList: [String] = capabilities?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        Log("🚀 Registering App Identifier '\(targetIdentifier)' on Apple Developer Portal...".dim)

        let result: RegisterBundleIdResult
        do {
            result = try await service.registerBundleIdWithCapabilities(
                identifier: targetIdentifier,
                name: name,
                platform: platform,
                capabilities: capList
            )
        } catch {
            Log("Error: ".red.bold + "Failed to create App Identifier: \(error.localizedDescription)")
            return
        }

        let createdName = result.bundleId.attributes?.name ?? (name ?? targetIdentifier)
        let portalId = result.bundleId.id
        let platformStr = result.bundleId.attributes?.platform?.rawValue ?? platform.uppercased()
        let seedId = result.bundleId.attributes?.seedId ?? "-"

        Log("\n🟢 App Identifier registered successfully!".green.bold)
        Log("  • Identifier: ".cyan + "\(targetIdentifier)".bold)
        Log("  • Name: ".cyan + "\(createdName)")
        Log("  • Portal ID: ".cyan + "\(portalId)")
        Log("  • Platform: ".cyan + "\(platformStr)")
        Log("  • Prefix/Seed ID: ".cyan + "\(seedId)")

        if !capList.isEmpty {
            Log("\n⚙️  Configuring capabilities...".dim)
            for cap in result.enabledCapabilities {
                Log("  🟢 Enabled: ".green + "\(cap.rawValue)".bold)
            }
            for fail in result.failedCapabilities {
                Log("  🔴 Failed to enable '\(fail.capability.rawValue)': \(fail.error)".red)
            }
            Log("\n🟢 Capabilities configured: \(result.enabledCapabilities.count)/\(capList.count) enabled.".green.bold)
        }
        Log("")
    }
}
