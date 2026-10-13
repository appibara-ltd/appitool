import ArgumentParser
import Foundation

/// Root command for Match code signing and keystore management.
struct MatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "match",
        abstract: "Syncs, nukes, or manages certificates, profiles, and Android keystores using Git storage.",
        subcommands: [
            MatchIOSCommand.self,
            MatchAndroidCommand.self,
        ],
        defaultSubcommand: MatchIOSCommand.self
    )
}
