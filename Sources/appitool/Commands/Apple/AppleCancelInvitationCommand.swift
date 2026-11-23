import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleCancelInvitationCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel-invitation",
        abstract: "Cancels a pending User Invitation in App Store Connect."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Invitation resource ID to cancel.")
    var id: String?

    @Option(name: .shortAndLong, help: "Invitee email address whose pending invitation should be canceled.")
    var email: String?

    func execute() async throws {
        let targetId = AppleCommandHelpers.trimmedNonEmpty(id)
        let targetEmail = AppleCommandHelpers.trimmedNonEmpty(email)
        guard targetId != nil || targetEmail != nil else {
            throw CommandError("Missing target invitation. Provide -i, --id or -e, --email.")
        }

        let service = try appleCredentials.requireService()
        let label = targetEmail ?? targetId ?? "unknown"

        let resolvedInvitationId: String
        if let targetId {
            resolvedInvitationId = targetId
        } else if let targetEmail {
            Log("🔍 Searching for pending invitation for '\(targetEmail)' in App Store Connect...".dim)
            guard let matched = try await service.findUserInvitation(identifier: targetEmail) else {
                Log("🟡️ No pending invitation for '\(targetEmail)' exists in App Store Connect (already absent).".yellow)
                return
            }
            resolvedInvitationId = matched.id
        } else {
            return
        }

        Log("🚫 Canceling invitation for '\(label)' [ID: \(resolvedInvitationId)]...".dim)
        let canceled = try await service.cancelUserInvitation(id: resolvedInvitationId)
        if canceled {
            Log("🟢 Successfully canceled invitation for '\(label)'.".green.bold)
        } else {
            Log("🟡️ Invitation '\(label)' does not exist in App Store Connect (already absent).".yellow)
        }
    }
}
