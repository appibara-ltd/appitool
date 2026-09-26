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

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var firebaseCredentials: FirebaseCredentialsOptions

    @OptionGroup
    var notificationOptions: NotificationOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let notifications = notificationOptions.resolve()
        let resolvedBundleId = bundleId ?? ProcessInfo.processInfo.environment["APPLE_BUNDLE_ID"]

        let runner = FlowRunner(
            platform: .ios,
            distribution: distribution,
            isDryRun: dryRun,
            bundleId: resolvedBundleId,
            slackUrl: notifications.slackUrl,
            kokonoUrl: notifications.kokonoUrl,
            kokonoPublicKey: notifications.kokonoPublicKey
        )

        try await runner.run()
    }
}
