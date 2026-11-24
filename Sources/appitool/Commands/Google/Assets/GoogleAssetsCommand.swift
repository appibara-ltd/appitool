import ArgumentParser
import Foundation

struct GoogleAssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assets",
        abstract: "List, upload, download, and delete Google Play Console store screenshots and graphics.",
        subcommands: [
            GoogleAssetsListCommand.self,
            GoogleAssetsUploadCommand.self,
            GoogleAssetsDownloadCommand.self,
            GoogleAssetsDeleteCommand.self,
            GoogleAssetsTypesCommand.self,
        ]
    )
}
