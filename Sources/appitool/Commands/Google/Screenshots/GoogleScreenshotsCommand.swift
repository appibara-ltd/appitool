import ArgumentParser
import Foundation

struct GoogleScreenshotsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshots",
        abstract: "List, upload, and delete Google Play Console store screenshots and graphics.",
        subcommands: [
            GoogleScreenshotsListCommand.self,
            GoogleScreenshotsUploadCommand.self,
            GoogleScreenshotsDownloadCommand.self,
            GoogleScreenshotsDeleteCommand.self,
            GoogleScreenshotsTypesCommand.self,
        ]
    )
}
