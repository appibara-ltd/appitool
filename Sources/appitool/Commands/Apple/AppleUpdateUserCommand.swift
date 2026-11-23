import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleUpdateUserCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-user",
        abstract: "Updates an active team User's roles or permissions in App Store Connect."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .long, help: "User resource ID in App Store Connect.")
    var id: String?

    @Option(name: .long, help: "User username (Apple ID email) in App Store Connect.")
    var username: String?

    @Option(name: .shortAndLong, help: "Comma-separated roles to assign (e.g. admin, developer, app-manager).")
    var roles: String?

    @Option(name: .long, help: "Comma-separated App Store Connect App IDs or bundle IDs to set as visible apps.")
    var visibleApps: String?

    @Flag(inversion: .prefixedNo, help: "Grant or restrict visibility to all apps (--all-apps-visible / --no-all-apps-visible).")
    var allAppsVisible: Bool?

    @Flag(inversion: .prefixedNo, help: "Allow or disallow certificates, identifiers, and profiles access (--provisioning-allowed / --no-provisioning-allowed).")
    var provisioningAllowed: Bool?

    func execute() async throws {
        let targetId = AppleCommandHelpers.trimmedNonEmpty(id)
        let targetUsername = AppleCommandHelpers.trimmedNonEmpty(username)
        guard targetId != nil || targetUsername != nil else {
            throw CommandError("Missing target user. Provide --id or --username.")
        }

        let parsedRoles = AppleCommandHelpers.trimmedNonEmpty(roles).map { AppleCommandHelpers.parseCommaSeparated($0) }
        let rawApps = AppleCommandHelpers.trimmedNonEmpty(visibleApps).map { AppleCommandHelpers.parseCommaSeparated($0) }
        guard parsedRoles != nil || rawApps != nil || allAppsVisible != nil || provisioningAllowed != nil else {
            throw CommandError("Nothing to update. Provide --roles, --visible-apps, --all-apps-visible/--no-all-apps-visible, or --provisioning-allowed/--no-provisioning-allowed.")
        }

        let service = try appleCredentials.requireService()

        let resolvedUserId: String
        if let targetId {
            resolvedUserId = targetId
        } else if let targetUsername {
            Log("🔍 Searching for user '\(targetUsername)' in App Store Connect...".dim)
            guard let user = try await service.findUser(identifier: targetUsername) else {
                throw CommandError("User '\(targetUsername)' was not found in App Store Connect.")
            }
            resolvedUserId = user.id
        } else {
            throw CommandError("Missing target user.")
        }

        let resolvedAppIds: [String]?
        if let rawApps {
            resolvedAppIds = try await service.resolveAppIds(rawApps)
        } else {
            resolvedAppIds = nil
        }

        Log("🔄 Updating user '\(resolvedUserId)' in App Store Connect...".dim)
        let updated = try await service.updateUser(
            id: resolvedUserId,
            roles: parsedRoles,
            allAppsVisible: allAppsVisible,
            provisioningAllowed: provisioningAllowed,
            visibleAppIds: resolvedAppIds
        )

        let updatedUsername = updated.attributes?.username ?? targetUsername ?? "-"
        let updatedRoles = (updated.attributes?.roles ?? []).map(\.rawValue).joined(separator: ", ")
        let allAppsStr = updated.attributes?.allAppsVisible.map { $0 ? "true" : "false" } ?? "-"
        let provisioningStr = updated.attributes?.provisioningAllowed.map { $0 ? "true" : "false" } ?? "-"

        Log("\n🟢 User updated successfully!".green.bold)
        Log("  • User ID: ".cyan + "\(updated.id)".bold)
        Log("  • Username: ".cyan + "\(updatedUsername)")
        Log("  • Roles: ".cyan + "\(updatedRoles.isEmpty ? "-" : updatedRoles)")
        Log("  • All Apps Visible: ".cyan + "\(allAppsStr)")
        Log("  • Provisioning Allowed: ".cyan + "\(provisioningStr)")
        Log("")
    }
}
