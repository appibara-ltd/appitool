import ArgumentParser
import Foundation

struct FirebaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firebase",
        abstract: "Manage and query Firebase App Distribution releases, tester groups, and Auth users.",
        subcommands: [
            FirebaseListReleasesCommand.self,
            FirebaseListGroupsCommand.self,
            FirebaseListUsersCommand.self,
            FirebaseDeleteUserCommand.self,
            FirebaseExportUsersCommand.self,
            FirebaseCreateGroupCommand.self,
            FirebaseCreateReleaseCommand.self,
            FirebaseUpdateReleaseCommand.self,
        ]
    )
}
