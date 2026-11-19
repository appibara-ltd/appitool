import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteProfileCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-profile",
        abstract: "Deletes a single provisioning profile from Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Provisioning profile name to delete.")
    var name: String?

    @Option(name: .shortAndLong, help: "Provisioning profile UUID to delete.")
    var uuid: String?

    @Option(name: .shortAndLong, help: "Provisioning profile Portal ID to delete.")
    var portalId: String?

    func execute() async throws {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUUID = uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = portalId?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedName != nil && !trimmedName!.isEmpty) ||
              (trimmedUUID != nil && !trimmedUUID!.isEmpty) ||
              (trimmedId != nil && !trimmedId!.isEmpty) else {
            throw CommandError("Missing target profile. Provide -n, --name, -u, --uuid, or -p, --portal-id.")
        }

        let service = try appleCredentials.requireService()

        let targetDescription = trimmedName ?? trimmedUUID ?? trimmedId ?? "unknown"
        Log("🔍 Searching for provisioning profile '\(targetDescription)' on Apple Developer Portal...".dim)

        let result = try await service.deleteProvisioningProfile(
            name: trimmedName,
            uuid: trimmedUUID,
            portalId: trimmedId
        )

        if result.deleted {
            let displayName = result.matchedProfile?.attributes?.name ?? result.targetDescription
            Log("🟢 Successfully deleted provisioning profile '\(displayName)'.".green.bold)
        } else {
            Log("🟡️ Provisioning profile '\(result.targetDescription)' does not exist on Apple Developer Portal (already absent).".yellow)
        }
    }
}
