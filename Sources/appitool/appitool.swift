import ArgumentParser
import Foundation

@main
struct appitool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appitool",
        abstract: "A unified CLI utility for Apple App Store Connect and Google Play operations.",
        version: "0.8.4",
        subcommands: [
            StatusCommand.self,
            BuildCommand.self,
            CleanCommand.self,
            CheckCommand.self,
            FlowCommand.self,
            KokonoCommand.self,
            SelfUpdateCommand.self,
            MatchCommand.self,
            AppleCommand.self,
            FirebaseCommand.self,
            ListIdentifiersCommand.self,
        ]
    )
}
