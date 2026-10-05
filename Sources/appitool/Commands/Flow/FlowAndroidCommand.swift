import ArgumentParser
import Foundation

struct FlowAndroidCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Executes the automated 7-stage release flow for Android."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Flag(name: .long, help: "Run in dry-run mode without modifying project files or uploading to stores.")
    var dryRun: Bool = false

    @Option(name: .shortAndLong, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    @OptionGroup
    var firebaseCredentials: FirebaseCredentialsOptions

    @OptionGroup
    var notificationOptions: NotificationOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let notifications = notificationOptions.resolve()
        let resolvedPackageName = packageName ?? ProcessInfo.processInfo.environment["GOOGLE_PACKAGE_NAME"]
        let resolvedFirebaseAppId = firebaseCredentials.firebaseAppId ?? ProcessInfo.processInfo.environment["FIREBASE_ANDROID_APP_ID"]
        let resolvedGoogleKey = googleCredentials.resolveKey()

        let preset: (any FlowPreset) = {
            switch distribution {
            case .adhoc, .development:
                return AndroidAdHocPreset()
            case .appstore:
                return AndroidInternalPreset()
            }
        }()

        var context = FlowContext(
            platform: .android,
            distribution: distribution,
            isDryRun: dryRun,
            bundleId: resolvedPackageName,
            firebaseAppId: resolvedFirebaseAppId,
            googleKey: resolvedGoogleKey,
            slackUrl: notifications.slackUrl,
            kokonoUrl: notifications.kokonoUrl,
            kokonoPublicKey: notifications.kokonoPublicKey,
            preset: preset
        )

        let runner = FlowRunner()
        try await runner.run(context: &context)
    }
}
