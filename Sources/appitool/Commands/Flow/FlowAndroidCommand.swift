import ArgumentParser
import Foundation

struct FlowAndroidCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Executes the automated 7-stage release flow for Android."
    )

    static var handlesErrors: Bool { false }

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Flag(name: .long, help: "Run in dry-run mode without modifying project files or uploading to stores.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @Option(name: .long, help: "Packaging format (aab or apk). Defaults to apk for adhoc/development, aab for appstore.")
    var format: GradleTask.BuildFormat?

    @Option(name: .long, help: "Gradle product flavor (e.g. production, staging). Defaults to ANDROID_FLAVOR in .env.")
    var flavor: String?

    @Option(name: .long, help: "Firebase App ID for Android (defaults to FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup var googleCredentials: GoogleCredentialsOptions
    @OptionGroup var matchOptions: MatchStorageOptions
    @OptionGroup var notificationOptions: NotificationOptions
    @OptionGroup var releaseNotesOptions: ReleaseNotesOptions

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress xcodebuild standard output and logs.")
    var silent: Bool = true

    func execute() async throws {
        let notifications = notificationOptions.resolve()
        let resolvedNotes = releaseNotesOptions.resolve()
        let resolvedPackageName = packageName ?? EnvLoader.value(for: "GOOGLE_PACKAGE_NAME")
        let resolvedFirebaseAppId = firebaseAppId ?? EnvLoader.value(for: "FIREBASE_ANDROID_APP_ID")
        let resolvedGoogleKey = googleCredentials.resolveKey()
        let resolvedFormat = format ?? (distribution == .appstore ? .aab : .apk)
        let resolvedFlavor = (flavor ?? EnvLoader.value(for: "ANDROID_FLAVOR"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let match = matchOptions.resolve()

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
            matchGitUrl: match.gitUrl,
            matchGitBranch: match.gitBranch,
            matchGitToken: match.gitToken,
            matchPassword: match.password,
            firebaseAppId: resolvedFirebaseAppId,
            googleKey: resolvedGoogleKey,
            slackUrl: notifications.slackUrl,
            kokonoUrl: notifications.kokonoUrl,
            kokonoPublicKey: notifications.kokonoPublicKey,
            preset: preset,
            androidFlavor: (resolvedFlavor?.isEmpty == false) ? resolvedFlavor : nil,
            androidFormat: resolvedFormat,
            changelog: resolvedNotes.releaseNotes,
            releaseNotesFrom: resolvedNotes.notesFrom,
            releaseNotesLocale: resolvedNotes.notesLocale,
            silent: silent
        )

        let runner = FlowRunner()
        try await runner.run(context: &context)
    }
}
