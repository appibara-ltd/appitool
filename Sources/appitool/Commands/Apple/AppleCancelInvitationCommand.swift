import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleCancelInvitationCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancels a pending User Invitation in App Store Connect."
    )

    var destructiveCommandDescription: String { "apple invitations cancel" }

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .long, help: "Invitation resource ID to cancel.")
    var id: String?

    @Option(name: .shortAndLong, help: "Invitee email address whose pending invitation should be canceled.")
    var email: String?

    func execute() async throws {
        let targetId = CLIValues.trimmedNonEmpty(id)
        let targetEmail = CLIValues.trimmedNonEmpty(email)
        guard targetId != nil || targetEmail != nil else {
            throw CommandError("Missing target invitation. Provide --id or -e, --email.")
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
