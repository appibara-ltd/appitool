import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleListUsersCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists users of the Play Console account (accepted access; see invitations list for pending ones)."
    )

    @OptionGroup
    var account: GooglePlayAccountOptions

    @Option(name: .shortAndLong, help: "Filter by email address.")
    var email: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        let users = try await GoogleUserSupport.run("list users") { try await service.listUsers(developerId: accountId) }
            .filter { !$0.isInvitation }
            .filter { user in CLIValues.trimmedNonEmpty(email).map { user.email?.caseInsensitiveCompare($0) == .orderedSame } ?? true }
        let shown = limit.map { Array(users.prefix(max(0, $0))) } ?? users

        if shown.isEmpty {
            Log("🟡 No users found.".yellow)
            return
        }
        Log("\nFound \(shown.count) user(s):".bold)
        shown.forEach(GoogleUserSupport.log)
        Log("")
    }
}

struct GoogleListInvitationsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists pending (or expired) invitations to the Play Console account."
    )

    @OptionGroup
    var account: GooglePlayAccountOptions

    @Option(name: .shortAndLong, help: "Filter by invitee email address.")
    var email: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        let invitations = try await GoogleUserSupport.run("list invitations") { try await service.listUsers(developerId: accountId) }
            .filter(\.isInvitation)
            .filter { user in CLIValues.trimmedNonEmpty(email).map { user.email?.caseInsensitiveCompare($0) == .orderedSame } ?? true }
        let shown = limit.map { Array(invitations.prefix(max(0, $0))) } ?? invitations

        if shown.isEmpty {
            Log("🟡 No pending invitations found.".yellow)
            return
        }
        Log("\nFound \(shown.count) invitation(s):".bold)
        shown.forEach(GoogleUserSupport.log)
        Log("")
    }
}
