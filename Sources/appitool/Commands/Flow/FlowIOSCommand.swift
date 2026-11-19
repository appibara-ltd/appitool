import ArgumentParser
import Foundation

struct FlowIOSCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Executes the automated 7-stage release flow for iOS."
    )

    static var handlesErrors: Bool { false }

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Flag(name: .long, help: "Run in dry-run mode without modifying project files or uploading to stores.")
    var dryRun: Bool = false

    @Option(name: .shortAndLong, help: "Target iOS bundle identifier (defaults to APPLE_BUNDLE_ID in .env).")
    var bundleId: String?

    @Option(name: .shortAndLong, help: "Xcode scheme to build (defaults to XCODE_SCHEME in .env).")
    var scheme: String?

    @Option(name: .shortAndLong, help: "Build configuration (Debug, Release). Defaults to XCODE_CONFIGURATION in .env.")
    var configuration: String?

    @Option(name: .long, help: "Firebase App ID for iOS (defaults to FIREBASE_IOS_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup var appleCredentials: AppleCredentialsOptions
    @OptionGroup var googleCredentials: GoogleCredentialsOptions
    @OptionGroup var matchOptions: MatchOptions
    @OptionGroup var notificationOptions: NotificationOptions

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress xcodebuild standard output and logs.")
    var silent: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Wait for App Store Connect build processing to apply TestFlight release notes.")
    var waitProcessing: Bool = true

    func execute() async throws {
        let notifications = notificationOptions.resolve()
        let resolvedBundleId = bundleId ?? EnvLoader.value(for: "APPLE_BUNDLE_ID")
        let resolvedScheme = scheme ?? EnvLoader.value(for: "XCODE_SCHEME")
        let resolvedConfiguration = configuration ?? EnvLoader.value(for: "XCODE_CONFIGURATION")
        let appleCreds = appleCredentials.resolve()
        let match = matchOptions.resolve()
        let resolvedTeamId = match.teamId
        let resolvedFirebaseAppId = firebaseAppId ?? EnvLoader.value(for: "FIREBASE_IOS_APP_ID")
        let resolvedGoogleKey = googleCredentials.resolveKey()

        let preset: (any FlowPreset) = {
            switch distribution {
            case .adhoc, .development:
                return IOSAdHocPreset()
            case .appstore:
                return IOSInternalPreset()
            }
        }()

        var context = FlowContext(
            platform: .ios,
            distribution: distribution,
            isDryRun: dryRun,
            bundleId: resolvedBundleId,
            scheme: resolvedScheme,
            configuration: resolvedConfiguration,
            matchGitUrl: match.gitUrl,
            matchGitBranch: match.gitBranch,
            matchGitToken: match.gitToken,
            matchPassword: match.password,
            matchKeychainName: match.keychainName,
            matchKeychainPassword: match.keychainPassword,
            matchReadonly: match.readonly,
            teamId: resolvedTeamId,
            appleKeyId: appleCreds?.keyId,
            appleIssuerId: appleCreds?.issuerId,
            appleKey: appleCreds?.key,
            firebaseAppId: resolvedFirebaseAppId,
            googleKey: resolvedGoogleKey,
            slackUrl: notifications.slackUrl,
            kokonoUrl: notifications.kokonoUrl,
            kokonoPublicKey: notifications.kokonoPublicKey,
            preset: preset,
            silent: silent,
            waitForProcessing: waitProcessing,
        )

        let runner = FlowRunner()
        try await runner.run(context: &context)
    }
}
