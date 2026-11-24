import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleInviteUserCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Invites a user to the Play Console account, optionally with access to one app."
    )

    @OptionGroup
    var account: GooglePlayAccountOptions

    @Option(name: .shortAndLong, help: "Invitee email address.")
    var email: String

    @Option(name: .long, help: "Comma-separated account-wide permissions (e.g. can-see-all-apps, can-reply-to-reviews; the _GLOBAL suffix is optional).")
    var permissions: String?

    @Option(name: .long, help: "Grant access to this app (package name) right after inviting; requires --app-permissions.")
    var packageName: String?

    @Option(name: .long, help: "Comma-separated permissions for --package-name (e.g. can-access-app, can-manage-public-listing).")
    var appPermissions: String?

    @Option(name: .long, help: "Access expiration (ISO 8601, e.g. 2027-01-01T00:00:00Z).")
    var expiration: String?

    func validate() throws {
        let accountPermissions = try GoogleUserSupport.permissions(permissions, developerLevel: true)
        let app = try GoogleUserSupport.permissions(appPermissions, developerLevel: false)
        _ = try GoogleUserSupport.expiration(expiration)
        if accountPermissions == nil && app == nil {
            throw ValidationError("Provide --permissions and/or --app-permissions (with --package-name); a user without permissions cannot do anything.")
        }
        if app != nil && CLIValues.trimmedNonEmpty(packageName) == nil {
            throw ValidationError("--app-permissions requires --package-name.")
        }
        if app == nil && CLIValues.trimmedNonEmpty(packageName) != nil {
            throw ValidationError("--package-name requires --app-permissions.")
        }
    }

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        let accountPermissions = try GoogleUserSupport.permissions(permissions, developerLevel: true) ?? []
        let appGrant = try GoogleUserSupport.permissions(appPermissions, developerLevel: false)
        let expirationTime = try GoogleUserSupport.expiration(expiration)

        Log("✉️  Inviting \(email) to Play Console account \(accountId)...".dim)
        let user = try await GoogleUserSupport.run("invite \(email)") {
            try await service.createUser(developerId: accountId, email: email, permissions: accountPermissions, expirationTime: expirationTime)
        }
        Log("🟢 Invited \(user.email ?? email) [\(user.accessState ?? "INVITED")].".green.bold)

        if let appGrant, let package = CLIValues.trimmedNonEmpty(packageName) {
            try await GoogleUserSupport.run("grant \(email) access to \(package)") {
                try await service.createGrant(developerId: accountId, email: email, packageName: package, permissions: appGrant)
            }
            Log("🟢 Granted access to \(package): \(appGrant.map(GoogleUserSupport.displayPermission).joined(separator: ", ")).".green)
        }
    }
}

struct GoogleUpdateUserCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Updates a Play Console user's account-wide permissions and/or access expiration."
    )

    @OptionGroup
    var account: GooglePlayAccountOptions

    @Option(name: .shortAndLong, help: "User email address.")
    var email: String

    @Option(name: .long, help: "Comma-separated account-wide permissions to set (replaces the current list).")
    var permissions: String?

    @Option(name: .long, help: "New access expiration (ISO 8601, e.g. 2027-01-01T00:00:00Z).")
    var expiration: String?

    func validate() throws {
        let accountPermissions = try GoogleUserSupport.permissions(permissions, developerLevel: true)
        let expirationTime = try GoogleUserSupport.expiration(expiration)
        if accountPermissions == nil && expirationTime == nil {
            throw ValidationError("Provide --permissions and/or --expiration. Use users grant / users revoke for per-app permissions.")
        }
    }

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        let accountPermissions = try GoogleUserSupport.permissions(permissions, developerLevel: true)
        let expirationTime = try GoogleUserSupport.expiration(expiration)

        Log("🔧 Updating \(email)...".dim)
        let user = try await GoogleUserSupport.run("update \(email)") {
            try await service.updateUser(developerId: accountId, email: email, permissions: accountPermissions, expirationTime: expirationTime)
        }
        Log("🟢 Updated \(user.email ?? email).".green.bold)
        GoogleUserSupport.log(user)
    }
}
