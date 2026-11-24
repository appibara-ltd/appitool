import ArgumentParser
import Foundation
import GoogleServices

struct GoogleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "google",
        abstract: "Manage Google Play Console store visuals and resources.",
        subcommands: [
            GoogleAppsCommand.self,
            GoogleSigningCertsGroupCommand.self,
            GoogleUsersCommand.self,
            GoogleInvitationsCommand.self,
            GoogleAssetsCommand.self,
            GoogleMetadataCommand.self,
        ]
    )
}

/// Shared CLI options and resolution helpers for Google Play Console app commands.
struct GooglePlayAppOptions: ParsableArguments, Sendable {
    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    @Option(name: .long, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env or local Android project).")
    var packageName: String?

    func requirePackageName() throws -> String {
        if let resolved = AppIdentifierResolver.androidPackageName(explicit: packageName) {
            return resolved
        }
        throw ValidationError(
            "Missing Android package name. Provide --package-name, set GOOGLE_PACKAGE_NAME in .env, or run inside an Android project."
        )
    }

    func requireService() throws -> GooglePlayService {
        try googleCredentials.requireService()
    }
}
