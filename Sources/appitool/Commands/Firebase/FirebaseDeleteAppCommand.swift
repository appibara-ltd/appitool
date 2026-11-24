import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Removes an app from a Firebase project (restorable for 30 days unless `--immediate`).
struct FirebaseDeleteAppCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Removes an app from a Firebase project (restorable for 30 days unless --immediate)."
    )

    var destructiveCommandDescription: String { "firebase apps delete" }

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .customLong("firebase-app-id"), help: "Firebase App ID of the app to remove (or use -p with -b / --package-name).")
    var firebaseAppId: String?

    @Option(name: .shortAndLong, help: "Platform of the app to look up (ios, android, web); used with -b, --package-name, or -n.")
    var platform: FirebaseAppPlatformOption?

    @Option(name: .shortAndLong, help: "iOS bundle identifier of the app to remove (-p ios).")
    var bundleId: String?

    @Option(name: .long, help: "Android package name of the app to remove (-p android).")
    var packageName: String?

    @Option(name: .shortAndLong, help: "Display name of the web app to remove (-p web).")
    var name: String?

    @Flag(name: .long, help: "Delete permanently right away instead of the 30-day restorable removal.")
    var immediate: Bool = false

    @Flag(name: .long, help: "Validate the removal without removing the app.")
    var dryRun: Bool = false

    func validate() throws {
        let lookup = [bundleId, packageName, name].compactMap { CLIValues.trimmedNonEmpty($0) }
        if CLIValues.trimmedNonEmpty(firebaseAppId) != nil {
            guard platform == nil, lookup.isEmpty else {
                throw ValidationError("Use either --firebase-app-id or -p with -b / --package-name / -n, not both.")
            }
            return
        }
        guard let platform, lookup.count == 1 else {
            throw ValidationError("Missing app to remove. Provide --firebase-app-id, or -p with -b (ios), --package-name (android), or -n (web).")
        }
        let matches = switch platform {
        case .ios: bundleId != nil
        case .android: packageName != nil
        case .web: name != nil
        }
        guard matches else {
            throw ValidationError("-p ios uses -b, --bundle-id; -p android uses --package-name; -p web uses -n, --name.")
        }
    }

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject(fallbackAppId: firebaseAppId)

        let apps: [FirebaseAppSummary]
        do {
            apps = try await service.listApps(project: project)
        } catch let error as FirebaseAppsError {
            throw CommandError(error.localizedDescription, hint: FirebaseAppSupport.hint(for: error))
        }
        let app = try Self.findApp(in: apps, appId: firebaseAppId, platform: platform, identifier: bundleId ?? packageName, displayName: name)
        guard let platform = FirebaseAppPlatform(rawValue: app.platform ?? "") else {
            throw CommandError("Unsupported platform '\(app.platform ?? "-")' for app \(app.appId).")
        }

        let mode = immediate ? "permanently" : "(restorable for 30 days)"
        Log("🗑  \(dryRun ? "Validating removal of" : "Removing") \(app.displayName ?? app.appId) [\(app.namespace ?? "-")] \(mode) from Firebase project [\(project)]...".dim)
        do {
            try await service.removeApp(project: project, platform: platform, appId: app.appId, immediate: immediate, validateOnly: dryRun)
        } catch let error as FirebaseAppsError {
            throw CommandError("Failed to remove the app: \(error.localizedDescription)", hint: FirebaseAppSupport.hint(for: error))
        }
        if dryRun {
            Log("🟢 Validation passed; \(app.appId) was not removed (--dry-run).".green)
        } else {
            Log("🟢 Removed \(app.appId) \(mode).".green.bold)
        }
    }

    /// The app matching the given App ID, or the platform plus bundle ID / package name / web display name.
    static func findApp(
        in apps: [FirebaseAppSummary],
        appId: String?,
        platform: FirebaseAppPlatformOption?,
        identifier: String?,
        displayName: String?
    ) throws -> FirebaseAppSummary {
        let active = apps.filter { $0.state != "DELETED" }
        if let appId = CLIValues.trimmedNonEmpty(appId) {
            guard let app = active.first(where: { $0.appId == appId }) else {
                throw CommandError("No app with App ID \(appId) in this Firebase project.", hint: "Run 'appitool firebase apps list' to see the registered apps.")
            }
            return app
        }
        let platformValue = platform?.apiPlatform.rawValue
        let matches = active.filter { app in
            guard app.platform == platformValue else { return false }
            if let identifier { return app.namespace == identifier }
            return app.displayName == displayName
        }
        guard let app = matches.first else {
            throw CommandError("No \(platform?.rawValue ?? "") app '\(identifier ?? displayName ?? "")' in this Firebase project.", hint: "Run 'appitool firebase apps list' to see the registered apps.")
        }
        guard matches.count == 1 else {
            throw CommandError("\(matches.count) apps match '\(identifier ?? displayName ?? "")'.", hint: "Pass --firebase-app-id to choose one.")
        }
        return app
    }
}
