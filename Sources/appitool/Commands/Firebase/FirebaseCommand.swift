import ArgumentParser
import Foundation

struct FirebaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firebase",
        abstract: "Manage and query Firebase App Distribution releases, tester groups, and builds.",
        subcommands: [
            FirebaseListReleasesCommand.self,
            FirebaseListGroupsCommand.self,
            FirebaseCreateGroupCommand.self,
            FirebaseCreateReleaseCommand.self,
            FirebaseUpdateReleaseCommand.self,
        ]
    )
}
