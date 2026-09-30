import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteIdentifierCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-identifier",
        abstract: "Deletes an App/Bundle Identifier from Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "App/Bundle identifier to delete (e.g., com.example.app).")
    var appIdentifier: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let targetIdentifier = appIdentifier, !targetIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Error: ".red.bold + "Missing app identifier. Provide -a, --app-identifier <bundle-id>.")
            return
        }

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        print("🔍 Checking bundle identifier '\(targetIdentifier)' on Apple Developer Portal...".dim)

        do {
            let (deleted, portalId) = try await service.deleteBundleIdByIdentifier(identifier: targetIdentifier)
            if let portalId, deleted {
                print("🗑️ Deleting bundle identifier ".red + "\(targetIdentifier)".bold + " (Portal ID: \(portalId))...".dim)
                print("✓ Successfully deleted bundle identifier '\(targetIdentifier)' from Apple Developer Portal.".green.bold)
                print("ℹ️ Note: Any provisioning profiles tied to this bundle identifier have been invalidated by Apple.".dim)
            } else {
                print("ℹ️ Bundle identifier '\(targetIdentifier)' does not exist on Apple Developer Portal (already absent).".yellow)
            }
        } catch {
            print("Error: ".red.bold + "Failed to delete bundle identifier: \(error.localizedDescription)")
            print("💡 Tip: Apple does not allow deleting bundle identifiers that are actively linked to App records in App Store Connect.".yellow)
        }
    }
}
