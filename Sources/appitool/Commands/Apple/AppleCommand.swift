import ArgumentParser
import Foundation

struct AppleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple",
        abstract: "Manage and query Apple App Store Connect and Developer Portal resources.",
        subcommands: [
            AppleAppsCommand.self,
            AppleVersionsCommand.self,
            AppleIdentifiersCommand.self,
            AppleCapabilitiesCommand.self,
            AppleProfilesCommand.self,
            AppleCertificatesCommand.self,
            AppleDevicesCommand.self,
            AppleUsersCommand.self,
            AppleInvitationsCommand.self,
            AppleAssetsCommand.self,
            AppleMetadataCommand.self,
        ]
    )
}

enum AppleCommandHelpers {
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
