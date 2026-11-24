import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Registers an iOS, Android, or web app in a Firebase project (or reports the existing one).
struct FirebaseAddAppCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-app",
        abstract: "Registers an iOS, Android, or web app in a Firebase project (reports the existing app if already registered)."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "Platform of the app (ios, android, web).")
    var platform: FirebaseAppPlatformOption

    @Option(name: .shortAndLong, help: "iOS bundle identifier (defaults to APPLE_BUNDLE_ID in .env, then the local Xcode project).")
    var bundleId: String?

    @Option(name: .long, help: "Android package name (defaults to GOOGLE_PACKAGE_NAME in .env, then the local Android project).")
    var packageName: String?

    @Option(name: .shortAndLong, help: "Display name of the app in Firebase (required for web apps).")
    var name: String?

    @Option(name: .long, help: "iOS only: Apple ID of the app in the App Store.")
    var appStoreId: String?

    @Option(name: .long, help: "iOS only: Apple Developer Team ID.")
    var teamId: String?

    @Option(name: .long, help: "Android only: SHA-1 certificate fingerprint to register (repeatable; e.g. from 'google signing-certs').")
    var sha1: [String] = []

    @Option(name: .long, help: "Android only: SHA-256 certificate fingerprint to register (repeatable).")
    var sha256: [String] = []

    func validate() throws {
        if platform != .ios, bundleId != nil || appStoreId != nil || teamId != nil {
            throw ValidationError("--bundle-id, --app-store-id, and --team-id only apply to -p ios.")
        }
        if platform != .android, packageName != nil || !sha1.isEmpty || !sha256.isEmpty {
            throw ValidationError("--package-name, --sha1, and --sha256 only apply to -p android.")
        }
        if platform == .web, CLIValues.trimmedNonEmpty(name) == nil {
            throw ValidationError("Web apps need a display name: pass -n, --name.")
        }
        try FirebaseAppSupport.validateFingerprints(sha1: sha1, sha256: sha256)
    }

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject()
        let identifier = try await resolveIdentifier()

        // Idempotent: report an app that is already registered instead of failing.
        let existing: [FirebaseAppSummary]
        do {
            existing = try await service.listApps(project: project)
        } catch let error as FirebaseAppsError {
            throw CommandError(error.localizedDescription, hint: FirebaseAppSupport.hint(for: error))
        }
        if let identifier, let app = existing.first(where: { $0.platform == platform.apiPlatform.rawValue && $0.namespace == identifier }) {
            Log("🟡 \(identifier) is already registered in Firebase project [\(project)].".yellow)
            printApp(app)
            return
        }

        let request = FirebaseAppCreateRequest(
            platform: platform.apiPlatform,
            displayName: CLIValues.trimmedNonEmpty(name),
            identifier: identifier,
            appStoreId: CLIValues.trimmedNonEmpty(appStoreId),
            teamId: CLIValues.trimmedNonEmpty(teamId),
            sha1Hashes: sha1,
            sha256Hashes: sha256
        )
        Log("➕ Registering \(platform.rawValue) app \(identifier ?? name ?? "") in Firebase project [\(project)]...".dim)
        let app: FirebaseAppSummary
        do {
            app = try await service.createApp(project: project, request: request)
        } catch let error as FirebaseAppsError {
            throw CommandError("Failed to register the app: \(error.localizedDescription)", hint: FirebaseAppSupport.hint(for: error))
        }
        Log("🟢 App registered.".green.bold)
        printApp(app)
    }

    /// Bundle ID (iOS) or package name (Android); `nil` for web.
    private func resolveIdentifier() async throws -> String? {
        switch platform {
        case .ios:
            guard let value = await AppIdentifierResolver.iosBundleId(explicit: bundleId) else {
                throw ValidationError("Missing iOS bundle identifier. Provide -b, --bundle-id, set APPLE_BUNDLE_ID in .env, or run inside an Xcode project.")
            }
            return value
        case .android:
            guard let value = AppIdentifierResolver.androidPackageName(explicit: packageName) else {
                throw ValidationError("Missing Android package name. Provide --package-name, set GOOGLE_PACKAGE_NAME in .env, or run inside an Android project.")
            }
            return value
        case .web:
            return nil
        }
    }

    private func printApp(_ app: FirebaseAppSummary) {
        Log("   Name:   ".dim + (app.displayName ?? "-"))
        Log("   ID:     ".dim + (app.namespace ?? "-"))
        Log("   App ID: ".dim + app.appId.bold)
        if let envVar = FirebaseAppSupport.appIdEnvVar(for: app.platform) {
            Log("   Set \(envVar)=\(app.appId) in .env to use it with other appitool commands.".dim)
        }
    }
}
