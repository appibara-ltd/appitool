import ArgumentParser
import Foundation

/// Group command for Apple code signing via Git storage (Fastlane match equivalent).
///
/// Actions are subcommands: `sync` (default), `nuke`, and `prune`.
struct MatchIOSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Syncs, nukes, or prunes Apple certificates and provisioning profiles using Git storage (Fastlane match equivalent).",
        subcommands: [
            MatchIOSSyncCommand.self,
            MatchIOSNukeCommand.self,
            MatchIOSPruneCommand.self,
        ],
        defaultSubcommand: MatchIOSSyncCommand.self
    )
}
