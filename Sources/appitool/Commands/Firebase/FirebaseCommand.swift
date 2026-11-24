import ArgumentParser
import Foundation

struct FirebaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firebase",
        abstract: "Manage Firebase apps, App Distribution releases/groups, Auth users, and Cloud Firestore.",
        subcommands: [
            FirebaseListAppsCommand.self,
            FirebaseAddAppCommand.self,
            FirebaseDeleteAppCommand.self,
            FirebaseSyncFingerprintsCommand.self,
            FirebaseListReleasesCommand.self,
            FirebaseListGroupsCommand.self,
            FirebaseListUsersCommand.self,
            FirebaseDeleteUserCommand.self,
            FirebaseExportUsersCommand.self,
            FirebaseCreateGroupCommand.self,
            FirebaseCreateReleaseCommand.self,
            FirebaseUpdateReleaseCommand.self,
            FirebaseFirestoreCommand.self,
        ]
    )
}
