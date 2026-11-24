import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Lists the iOS, Android, and web apps registered in a Firebase project.
struct FirebaseListAppsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists the iOS, Android, and web apps registered in a Firebase project."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "Only list apps of this platform (ios, android, web).")
    var platform: FirebaseAppPlatformOption?

    @Flag(name: .long, help: "Also list apps deleted within the last 30 days.")
    var showDeleted: Bool = false

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject()

        Log("🔍 Fetching apps for Firebase project [\(project)]...".dim)
        let all: [FirebaseAppSummary]
        do {
            all = try await service.listApps(project: project, showDeleted: showDeleted)
        } catch let error as FirebaseAppsError {
            throw CommandError(error.localizedDescription, hint: FirebaseAppSupport.hint(for: error))
        }
        let apps = all.filter { platform == nil || $0.platform == platform?.apiPlatform.rawValue }

        guard !apps.isEmpty else {
            Log("No apps found in Firebase project: \(project)".yellow)
            return
        }

        Log("\nFound \(apps.count) app(s):".bold)
        for platformValue in FirebaseAppPlatform.allCases.map(\.rawValue) + [nil] {
            let group = apps.filter { app in
                platformValue.map { app.platform == $0 } ?? !FirebaseAppPlatform.allCases.map(\.rawValue).contains(app.platform ?? "")
            }
            guard !group.isEmpty else { continue }
            Log("\n  \(platformValue ?? "OTHER")".cyan.bold)
            for app in group {
                let deleted = app.state == "DELETED" ? " (deleted)".red : ""
                Log("  • ".cyan + (app.displayName ?? "-").bold + " [\(app.namespace ?? "-")]".green + deleted)
                Log("    App ID: ".dim + app.appId)
            }
        }
        Log("")
    }
}
