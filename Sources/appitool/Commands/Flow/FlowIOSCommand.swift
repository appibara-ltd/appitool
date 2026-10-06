import ArgumentParser
import Foundation

struct FlowIOSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Executes the automated 7-stage release flow for iOS."
    )

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

    @OptionGroup var appleCredentials: AppleCredentialsOptions
    @OptionGroup var firebaseCredentials: FirebaseCredentialsOptions
    @OptionGroup var matchOptions: MatchOptions
    @OptionGroup var notificationOptions: NotificationOptions

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress xcodebuild standard output and logs.")
    var silent: Bool = true

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let notifications = notificationOptions.resolve()
        let resolvedBundleId = bundleId ?? ProcessInfo.processInfo.environment["APPLE_BUNDLE_ID"]
        let resolvedScheme = scheme ?? ProcessInfo.processInfo.environment["XCODE_SCHEME"]
        let resolvedConfiguration = configuration ?? ProcessInfo.processInfo.environment["XCODE_CONFIGURATION"]
        let appleCreds = appleCredentials.resolve()
        let match = matchOptions.resolve()
        let resolvedTeamId = match.teamId ?? ProcessInfo.processInfo.environment["APPLE_TEAM_ID"]
        let resolvedFirebaseAppId = firebaseCredentials.resolveAppId(for: .ios)
        let resolvedGoogleKey = firebaseCredentials.resolveKey() ?? ProcessInfo.processInfo.environment["GOOGLE_KEY"]

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
        )

        let runner = FlowRunner()
        try await runner.run(context: &context)
    }
}
