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
            AppleCreateCertificateCommand.self,
            AppleDeleteCertificateCommand.self,
            ApplePruneCertificatesCommand.self,
            AppleListDevicesCommand.self,
            AppleAddDeviceCommand.self,
            AppleDisableDeviceCommand.self,
            AppleListUsersCommand.self,
            AppleInviteUserCommand.self,
            AppleUpdateUserCommand.self,
            AppleDeleteUserCommand.self,
            AppleListInvitationsCommand.self,
            AppleCancelInvitationCommand.self,
            AppleScreenshotsCommand.self,
        ]
    )
}

enum AppleCommandHelpers {
    static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func parseCommaSeparated(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
