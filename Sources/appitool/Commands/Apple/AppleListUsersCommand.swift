import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleListUsersCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-users",
        abstract: "Lists active team Users in App Store Connect."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .long, help: "Filter by username (Apple ID email).")
    var username: String?

    @Option(name: .shortAndLong, help: "Filter by comma-separated roles (e.g. admin, developer, app-manager).")
    var roles: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let service = try appleCredentials.requireService()
        let roleFilters = AppleCommandHelpers.parseCommaSeparated(roles)

        Log("🔍 Fetching team users from App Store Connect...".dim)
        let users = try await service.fetchUsers(
            username: username,
            roles: roleFilters,
            limit: limit
        )

        if users.isEmpty {
            if let filter = AppleCommandHelpers.trimmedNonEmpty(username) ?? AppleCommandHelpers.trimmedNonEmpty(roles) {
                Log("No users matching '\(filter)' found in App Store Connect.".yellow)
            } else {
                Log("No users found in App Store Connect.".yellow)
            }
            return
        }

        Log("\nFound \(users.count) user(s):".bold)
        for user in users {
            let first = user.attributes?.firstName ?? ""
            let last = user.attributes?.lastName ?? ""
            let fullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            let displayName = fullName.isEmpty ? "unnamed" : fullName
            let emailStr = user.attributes?.username ?? "-"
            let rolesStr = (user.attributes?.roles ?? []).map(\.rawValue).joined(separator: ", ")
            let allAppsStr = user.attributes?.allAppsVisible.map { $0 ? "all" : "restricted" } ?? "-"
            let provisioningStr = user.attributes?.provisioningAllowed.map { $0 ? "yes" : "no" } ?? "-"

            Log("  • ".cyan + "\(displayName)".bold + " (\(emailStr))".green + " [ID: \(user.id), Roles: \(rolesStr.isEmpty ? "-" : rolesStr), Apps: \(allAppsStr), Provisioning: \(provisioningStr)]".dim)
        }
        Log("")
    }
}
