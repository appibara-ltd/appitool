import ArgumentParser

// Resource groups: `<resource> <action>` (e.g. `users list`).

struct GoogleAppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List apps the service account can access.",
        subcommands: [
            GoogleListAppsCommand.self,
        ]
    )
}

struct GoogleSigningCertsGroupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signing-certs",
        abstract: "Show Play App Signing certificate fingerprints.",
        subcommands: [
            GoogleSigningCertsCommand.self,
        ]
    )
}

struct GoogleUsersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "List, invite, update, and delete Play Console users, and grant or revoke per-app access.",
        subcommands: [
            GoogleListUsersCommand.self,
            GoogleInviteUserCommand.self,
            GoogleUpdateUserCommand.self,
            GoogleDeleteUserCommand.self,
            GoogleGrantAccessCommand.self,
            GoogleRevokeAccessCommand.self,
        ]
    )
}

struct GoogleInvitationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invitations",
        abstract: "List and cancel pending Play Console user invitations.",
        subcommands: [
            GoogleListInvitationsCommand.self,
            GoogleCancelInvitationCommand.self,
        ]
    )
}
