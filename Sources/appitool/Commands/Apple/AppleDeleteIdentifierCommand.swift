import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteIdentifierCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Deletes an App/Bundle Identifier from Apple Developer Portal."
    )

    var destructiveCommandDescription: String { "apple identifiers delete" }

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .shortAndLong, help: "App/Bundle identifier to delete (e.g., com.example.app).")
    var bundleId: String?

    func execute() async throws {
        guard let targetIdentifier = bundleId, !targetIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError("Missing bundle identifier. Provide -b, --bundle-id <bundle-id>.")
        }

        let service = try appleCredentials.requireService()

        Log("🔍 Checking bundle identifier '\(targetIdentifier)' on Apple Developer Portal...".dim)

        do {
            let (deleted, portalId) = try await service.deleteBundleIdByIdentifier(identifier: targetIdentifier)
            if let portalId, deleted {
                Log("🗑️ Deleting bundle identifier ".red + "\(targetIdentifier)".bold + " (Portal ID: \(portalId))...".dim)
                Log("🟢 Successfully deleted bundle identifier '\(targetIdentifier)' from Apple Developer Portal.".green.bold)
                Log("🟡️ Note: Any provisioning profiles tied to this bundle identifier have been invalidated by Apple.".dim)
            } else {
                Log("🟡️ Bundle identifier '\(targetIdentifier)' does not exist on Apple Developer Portal (already absent).".yellow)
            }
        } catch {
            throw CommandError(
                "Failed to delete bundle identifier: \(error.localizedDescription)",
                hint: "💡 Tip: Apple does not allow deleting bundle identifiers that are actively linked to App records in App Store Connect."
            )
        }
    }
}
