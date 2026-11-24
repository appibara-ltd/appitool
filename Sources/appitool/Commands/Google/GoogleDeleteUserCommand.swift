import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleDeleteUserCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-user",
        abstract: "Removes a user from the Play Console account."
    )

    var destructiveCommandDescription: String { "google delete-user" }

    @OptionGroup
    var account: GooglePlayAccountOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .shortAndLong, help: "User email address to remove.")
    var email: String

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        Log("🗑️  Removing \(email) from Play Console account \(accountId)...".dim)
        try await GoogleUserSupport.run("remove \(email)") {
            try await service.deleteUser(developerId: accountId, email: email)
        }
        Log("🟢 Removed \(email).".green.bold)
    }
}

struct GoogleCancelInvitationCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel-invitation",
        abstract: "Cancels a pending Play Console invitation."
    )

    var destructiveCommandDescription: String { "google cancel-invitation" }

    @OptionGroup
    var account: GooglePlayAccountOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .shortAndLong, help: "Invitee email address whose pending invitation should be canceled.")
    var email: String

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        let users = try await GoogleUserSupport.run("list invitations") { try await service.listUsers(developerId: accountId) }
        guard let user = GoogleUserSupport.findUser(users, email: email) else {
            throw CommandError("No invitation found for \(email).")
        }
        guard user.isInvitation else {
            throw CommandError("\(email) has already accepted the invitation [\(user.accessState ?? "-")]; use delete-user to remove the user.")
        }
        try await GoogleUserSupport.run("cancel the invitation for \(email)") {
            try await service.deleteUser(developerId: accountId, email: email)
        }
        Log("🟢 Canceled the invitation for \(email).".green.bold)
    }
}

struct GoogleGrantAccessCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant-access",
        abstract: "Gives a Play Console user permissions for one app (creates or replaces the app grant)."
    )

    @OptionGroup
    var account: GooglePlayAccountOptions

    @Option(name: .shortAndLong, help: "User email address.")
    var email: String

    @Option(name: .long, help: "App package name (defaults to GOOGLE_PACKAGE_NAME in .env or local Android project).")
    var packageName: String?

    @Option(name: .long, help: "Comma-separated app permissions (e.g. can-access-app, can-reply-to-reviews, can-manage-public-listing).")
    var permissions: String

    func validate() throws {
        _ = try GoogleUserSupport.permissions(permissions, developerLevel: false)
    }

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        guard let package = AppIdentifierResolver.androidPackageName(explicit: packageName) else {
            throw CommandError("Missing package name. Provide --package-name, set GOOGLE_PACKAGE_NAME in .env, or run inside an Android project.")
        }
        let appPermissions = try GoogleUserSupport.permissions(permissions, developerLevel: false) ?? []

        let users = try await GoogleUserSupport.run("list users") { try await service.listUsers(developerId: accountId) }
        guard let user = GoogleUserSupport.findUser(users, email: email) else {
            throw CommandError("\(email) is not a user of Play Console account \(accountId).", hint: "Invite them first with 'appitool google invite-user'.")
        }
        let hasGrant = (user.grants ?? []).contains { $0.packageName == package }
        if hasGrant {
            try await GoogleUserSupport.run("update \(email)'s access to \(package)") {
                try await service.updateGrant(developerId: accountId, email: email, packageName: package, permissions: appPermissions)
            }
        } else {
            try await GoogleUserSupport.run("grant \(email) access to \(package)") {
                try await service.createGrant(developerId: accountId, email: email, packageName: package, permissions: appPermissions)
            }
        }
        Log("🟢 \(hasGrant ? "Updated" : "Granted") \(email)'s access to \(package): \(appPermissions.map(GoogleUserSupport.displayPermission).joined(separator: ", ")).".green.bold)
    }
}

struct GoogleRevokeAccessCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke-access",
        abstract: "Removes a Play Console user's permissions for one app."
    )

    var destructiveCommandDescription: String { "google revoke-access" }

    @OptionGroup
    var account: GooglePlayAccountOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .shortAndLong, help: "User email address.")
    var email: String

    @Option(name: .long, help: "App package name (defaults to GOOGLE_PACKAGE_NAME in .env or local Android project).")
    var packageName: String?

    func execute() async throws {
        let accountId = try account.requireAccountId()
        let service = try account.requireService()
        guard let package = AppIdentifierResolver.androidPackageName(explicit: packageName) else {
            throw CommandError("Missing package name. Provide --package-name, set GOOGLE_PACKAGE_NAME in .env, or run inside an Android project.")
        }
        try await GoogleUserSupport.run("revoke \(email)'s access to \(package)") {
            try await service.deleteGrant(developerId: accountId, email: email, packageName: package)
        }
        Log("🟢 Revoked \(email)'s access to \(package).".green.bold)
    }
}
