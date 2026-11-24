import ArgumentParser
import Foundation

struct FirebaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firebase",
        abstract: "Manage Firebase apps, App Distribution releases/groups, Auth users, and Cloud Firestore.",
        subcommands: [
            FirebaseAppsCommand.self,
            FirebaseFingerprintsCommand.self,
            FirebaseReleasesCommand.self,
            FirebaseGroupsCommand.self,
            FirebaseUsersCommand.self,
            FirebaseFirestoreCommand.self,
        ]
    )
}
