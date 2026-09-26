import ArgumentParser
import Foundation

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Checks and retrieves application information from remote stores or distribution platforms.",
        subcommands: [
            CheckIOSCommand.self,
            CheckAndroidCommand.self,
        ]
    )
}
