import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleInviteUserCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite-user",
        abstract: "Invites a new User to join your App Store Connect team."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Invitee email address.")
    var email: String

    @Option(name: .long, help: "Invitee first name.")
    var firstName: String

    @Option(name: .long, help: "Invitee last name.")
    var lastName: String

    @Option(name: .shortAndLong, help: "Comma-separated roles (e.g. admin, developer, app-manager, marketing, finance).")
    var roles: String

    @Option(name: .long, help: "Comma-separated App Store Connect App IDs or bundle IDs to grant access when restricting visibility.")
    var visibleApps: String?

    @Flag(inversion: .prefixedNo, help: "Grant visibility to all apps (--all-apps-visible / --no-all-apps-visible; defaults to true unless --visible-apps is provided).")
    var allAppsVisible: Bool?

    @Flag(inversion: .prefixedNo, help: "Allow access to certificates, identifiers, and profiles (--provisioning-allowed / --no-provisioning-allowed).")
    var provisioningAllowed: Bool?

    func execute() async throws {
        let parsedRoles = CLIValues.commaSeparated(roles)
        guard !parsedRoles.isEmpty else {
            throw CommandError("At least one role is required. Provide -r, --roles <roles>.")
        }

        let service = try appleCredentials.requireService()
        let rawApps = CLIValues.commaSeparated(visibleApps)
        let resolvedAppIds = rawApps.isEmpty ? [] : try await service.resolveAppIds(rawApps)

        Log("✉️  Sending App Store Connect team invitation to '\(email)'...".dim)
        let invitation = try await service.inviteUser(
            email: email,
            firstName: firstName,
            lastName: lastName,
            roles: parsedRoles,
            allAppsVisible: allAppsVisible,
            provisioningAllowed: provisioningAllowed,
            visibleAppIds: resolvedAppIds
        )

        let invitedEmail = invitation.attributes?.email ?? email
        let invitedRoles = (invitation.attributes?.roles ?? []).map(\.rawValue).joined(separator: ", ")
        let allAppsStr = invitation.attributes?.allAppsVisible.map { $0 ? "true" : "false" } ?? "-"
        let expiresStr = invitation.attributes?.expirationDate.map(AppleCommandHelpers.formatDate) ?? "-"

        Log("\n🟢 User invitation sent successfully!".green.bold)
        Log("  • Invitation ID: ".cyan + "\(invitation.id)".bold)
        Log("  • Email: ".cyan + "\(invitedEmail)")
        Log("  • Name: ".cyan + "\(firstName) \(lastName)")
        Log("  • Roles: ".cyan + "\(invitedRoles)")
        Log("  • All Apps Visible: ".cyan + "\(allAppsStr)")
        if !resolvedAppIds.isEmpty {
            Log("  • Visible App IDs: ".cyan + "\(resolvedAppIds.joined(separator: ", "))")
        }
        Log("  • Expires: ".cyan + "\(expiresStr)".dim)
        Log("")
    }
}
