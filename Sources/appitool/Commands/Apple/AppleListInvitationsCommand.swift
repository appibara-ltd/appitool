import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleListInvitationsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-invitations",
        abstract: "Lists pending team User Invitations in App Store Connect."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by invitee email address.")
    var email: String?

    @Option(name: .shortAndLong, help: "Filter by comma-separated roles (e.g. admin, developer, app-manager).")
    var roles: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let service = try appleCredentials.requireService()
        let roleFilters = AppleCommandHelpers.parseCommaSeparated(roles)

        Log("🔍 Fetching pending user invitations from App Store Connect...".dim)
        let invitations = try await service.fetchUserInvitations(
            email: email,
            roles: roleFilters,
            limit: limit
        )

        if invitations.isEmpty {
            if let filter = AppleCommandHelpers.trimmedNonEmpty(email) ?? AppleCommandHelpers.trimmedNonEmpty(roles) {
                Log("No pending user invitations matching '\(filter)' found in App Store Connect.".yellow)
            } else {
                Log("No pending user invitations found in App Store Connect.".yellow)
            }
            return
        }

        Log("\nFound \(invitations.count) pending invitation(s):".bold)
        for invitation in invitations {
            let first = invitation.attributes?.firstName ?? ""
            let last = invitation.attributes?.lastName ?? ""
            let fullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            let displayName = fullName.isEmpty ? "unnamed" : fullName
            let emailStr = invitation.attributes?.email ?? "-"
            let rolesStr = (invitation.attributes?.roles ?? []).map(\.rawValue).joined(separator: ", ")
            let expiresStr = invitation.attributes?.expirationDate.map(AppleCommandHelpers.formatDate) ?? "-"

            Log("  • ".cyan + "\(displayName)".bold + " (\(emailStr))".green + " [ID: \(invitation.id), Roles: \(rolesStr.isEmpty ? "-" : rolesStr), Expires: \(expiresStr)]".dim)
        }
        Log("")
    }
}
