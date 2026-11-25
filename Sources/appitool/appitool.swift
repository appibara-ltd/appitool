import ArgumentParser
import Foundation

@main
struct appitool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appitool",
        abstract: "A unified CLI utility for Apple App Store Connect and Google Play operations.",
        version: "0.11.1",
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
            GoogleCommand.self,
            FirebaseCommand.self,
            InspectCommand.self,
            NotesCommand.self,
        ]
    )
    @OptionGroup
    var ciOptions: GlobalCIOptions
}
