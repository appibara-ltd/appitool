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

        // Apply CLI option overrides to process environment
        if let packageName, !packageName.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "GOOGLE_PACKAGE_NAME", value: packageName)
        }
        googleCredentials.applyEnvironmentOverrides()
        firebaseCredentials.applyEnvironmentOverrides(platformAppIdKey: "FIREBASE_ANDROID_APP_ID")
        notificationOptions.applyEnvironmentOverrides()

        let runner = FlowRunner(
            platform: .android,
            distribution: distribution,
            isDryRun: dryRun,
            kokonoUrl: notificationOptions.kokonoUrl,
            kokonoPublicKey: notificationOptions.kokonoPublicKey
        )

        try await runner.run()
    }
}
