import ArgumentParser

// Resource groups: `<resource> <action>` (e.g. `users list`).

struct AppleAppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List App Store Connect apps.",
        subcommands: [
            AppleListAppsCommand.self,
        ]
    )
}

struct AppleVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions",
        abstract: "Create and delete App Store versions.",
        subcommands: [
            AppleCreateVersionCommand.self,
            AppleDeleteVersionCommand.self,
        ]
    )
}

struct AppleIdentifiersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identifiers",
        abstract: "List, create, and delete bundle identifiers.",
        subcommands: [
            AppleListIdentifiersCommand.self,
            AppleCreateIdentifierCommand.self,
            AppleDeleteIdentifierCommand.self,
        ]
    )
}

struct AppleCapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List bundle identifier capabilities.",
        subcommands: [
            AppleListCapabilitiesCommand.self,
        ]
    )
}

struct AppleProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "List, create, delete, and prune provisioning profiles.",
        subcommands: [
            AppleListProfilesCommand.self,
            AppleCreateProfileCommand.self,
            AppleDeleteProfileCommand.self,
            ApplePruneProfilesCommand.self,
        ]
    )
}

struct AppleCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "certificates",
        abstract: "List, create, delete, and prune signing certificates.",
        subcommands: [
            AppleListCertificatesCommand.self,
            AppleCreateCertificateCommand.self,
            AppleDeleteCertificateCommand.self,
            ApplePruneCertificatesCommand.self,
        ]
    )
}

struct AppleDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List, register, and disable devices.",
        subcommands: [
            AppleListDevicesCommand.self,
            AppleAddDeviceCommand.self,
            AppleDisableDeviceCommand.self,
        ]
    )
}

struct AppleUsersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "List, invite, update, and delete App Store Connect users.",
        subcommands: [
            AppleListUsersCommand.self,
            AppleInviteUserCommand.self,
            AppleUpdateUserCommand.self,
            AppleDeleteUserCommand.self,
        ]
    )
}

struct AppleInvitationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invitations",
        abstract: "List and cancel pending App Store Connect user invitations.",
        subcommands: [
            AppleListInvitationsCommand.self,
            AppleCancelInvitationCommand.self,
        ]
    )
}
