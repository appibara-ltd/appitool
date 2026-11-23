import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteUserCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-user",
        abstract: "Removes an active team User from App Store Connect."
    )

    var destructiveCommandDescription: String { "apple delete-user" }

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .shortAndLong, help: "User resource ID to remove.")
    var id: String?

    @Option(name: .shortAndLong, help: "User username (Apple ID email) to remove.")
    var username: String?

    func execute() async throws {
        let targetId = AppleCommandHelpers.trimmedNonEmpty(id)
        let targetUsername = AppleCommandHelpers.trimmedNonEmpty(username)
        guard targetId != nil || targetUsername != nil else {
            throw CommandError("Missing target user. Provide -i, --id or -u, --username.")
        }

        let service = try appleCredentials.requireService()
        let label = targetUsername ?? targetId ?? "unknown"

        let resolvedUserId: String
        if let targetId {
            resolvedUserId = targetId
        } else if let targetUsername {
            Log("🔍 Searching for user '\(targetUsername)' in App Store Connect...".dim)
            guard let matched = try await service.findUser(identifier: targetUsername) else {
                Log("🟡️ User '\(targetUsername)' does not exist in App Store Connect (already absent).".yellow)
                return
            }
            resolvedUserId = matched.id
        } else {
            return
        }

        Log("🗑️ Removing user '\(label)' [ID: \(resolvedUserId)] from App Store Connect...".dim)
        let deleted = try await service.deleteUser(id: resolvedUserId)
        if deleted {
            Log("🟢 Successfully removed user '\(label)' from App Store Connect.".green.bold)
        } else {
            Log("🟡️ User '\(label)' does not exist in App Store Connect (already absent).".yellow)
        }
    }
}
