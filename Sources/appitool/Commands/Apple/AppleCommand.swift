import ArgumentParser
import Foundation

struct AppleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple",
        abstract: "Manage and query Apple App Store Connect and Developer Portal resources.",
        subcommands: [
            AppleListAppsCommand.self,
            AppleListIdentifiersCommand.self,
            AppleCreateIdentifierCommand.self,
            AppleDeleteIdentifierCommand.self,
            AppleListCapabilitiesCommand.self,
            AppleListProfilesCommand.self,
            AppleCreateProfileCommand.self,
            AppleDeleteProfileCommand.self,
            ApplePruneProfilesCommand.self,
            AppleListCertificatesCommand.self,
            AppleDeleteCertificateCommand.self,
            ApplePruneCertificatesCommand.self,
        ]
    )
}
