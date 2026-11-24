import ArgumentParser

// Resource groups: `<resource> <action>` (e.g. `users list`).

struct FirebaseAppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List, register, and delete Firebase apps.",
        subcommands: [
            FirebaseListAppsCommand.self,
            FirebaseAddAppCommand.self,
            FirebaseDeleteAppCommand.self,
        ]
    )
}

struct FirebaseFingerprintsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fingerprints",
        abstract: "Sync certificate fingerprints of Firebase Android apps.",
        subcommands: [
            FirebaseSyncFingerprintsCommand.self,
        ]
    )
}

struct FirebaseReleasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "releases",
        abstract: "List, create, and update App Distribution releases.",
        subcommands: [
            FirebaseListReleasesCommand.self,
            FirebaseCreateReleaseCommand.self,
            FirebaseUpdateReleaseCommand.self,
        ]
    )
}

struct FirebaseGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List and create App Distribution tester groups.",
        subcommands: [
            FirebaseListGroupsCommand.self,
            FirebaseCreateGroupCommand.self,
        ]
    )
}

struct FirebaseUsersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "List, delete, and export Firebase Authentication users.",
        subcommands: [
            FirebaseListUsersCommand.self,
            FirebaseDeleteUserCommand.self,
            FirebaseExportUsersCommand.self,
        ]
    )
}
