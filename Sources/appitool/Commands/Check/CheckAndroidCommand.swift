import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct CheckAndroidCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Checks Android application and build information from distribution providers."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to adhoc.")
    var distribution: BuildCommand.Distribution = .adhoc

    @Option(name: .shortAndLong, help: "Target Android package name (defaults to package name from project).")
    var packageName: String?

    @Option(name: .long, help: "Firebase App ID for Android (defaults to FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        let env = ProcessInfo.processInfo.environment

        var targetPackageName = packageName
        if targetPackageName == nil || targetPackageName?.isEmpty == true {
            if AndroidTasks.hasAndroidProject() {
                if let resolved = try? AndroidTasks.getAndroidIdentifiers() {
                    targetPackageName = resolved.applicationId ?? resolved.packageName
                }
            }
        }

        switch distribution {
        case .adhoc:
            guard let resolvedAppId = firebaseAppId ?? env["FIREBASE_ANDROID_APP_ID"], !resolvedAppId.isEmpty else {
                Log("Error: ".red.bold + "Missing Firebase App ID for Android. Provide --firebase-app-id or configure FIREBASE_ANDROID_APP_ID in .env.")
                return
            }

            let googleKey = googleCredentials.resolveKey()
            guard let service = try FirebaseService.makeService(googleKey: googleKey) else {
                Log("Error: ".red.bold + "Missing Firebase credentials. Provide -g, --google-key or configure GOOGLE_KEY in .env.")
                return
            }

            Log("Checking Firebase Android App information...".dim)
            let appTask = GetFirebaseAppInfoTask()
            do {
                guard case .android(let app) = try await appTask.run(.init(platform: .android, firebaseAppId: resolvedAppId, service: service)) else {
                    return
                }
                Log("\n" + "─── Firebase Android App Information ───".cyan.bold)
                if let appId = app.appId {
                    Log("App ID:        ".bold + "\(appId)".green)
                }
                if let resolvedPackageName = app.packageName {
                    Log("Package Name:  ".bold + "\(resolvedPackageName)".yellow)
                }
                if let displayName = app.displayName {
                    Log("Display Name:  ".bold + "\(displayName)")
                }
                if let projectId = app.projectId {
                    Log("Project ID:    ".bold + "\(projectId)")
                }
                if let state = app.state {
                    Log("State:         ".bold + "\(state.rawValue)")
                }

                let buildTask = GetLatestBuildNumberTask()
                if let buildInfo = try? await buildTask.run(.init(
                    target: .android(packageName: targetPackageName ?? app.packageName, firebaseAppId: resolvedAppId, firebaseService: service),
                    distribution: .adhoc
                )) {
                    Log("Latest Build:  ".bold + "v\(buildInfo.version) (\(buildInfo.buildNumber))".green.bold)
                }
                Log("────────────────────────────────────────".cyan.dim + "\n")
            } catch {
                Log("Error: ".red.bold + "Failed to retrieve Firebase Android App info: \(error.localizedDescription)")
            }

        case .appstore:
            guard let targetPackageName, !targetPackageName.isEmpty else {
                Log("Error: ".red.bold + "No package name specified. Provide -p, --package-name or ensure an Android project exists.")
                return
            }

            guard let service = try googleCredentials.makeService() else {
                Log("Error: ".red.bold + "Missing Google Play Service Account credentials (provide --google-key or configure GOOGLE_KEY in .env).")
                return
            }

            Log("Fetching latest build from Google Play Console for ".dim + "\(targetPackageName)".bold + "...".dim)
            let task = GetLatestBuildNumberTask()
            do {
                let info = try await task.run(.init(
                    target: .android(packageName: targetPackageName, service: service),
                    distribution: .appstore
                ))
                Log("\n" + "─── Google Play Store Build Information ───".cyan.bold)
                Log("Package Name:  ".bold + "\(targetPackageName)".yellow)
                Log("Version:       ".bold + "\(info.version)".green)
                Log("Build Number:  ".bold + "\(info.buildNumber)".green.bold)
                Log("───────────────────────────────────────────".cyan.dim + "\n")
            } catch {
                Log("Error: ".red.bold + "Failed to retrieve Google Play build: \(error.localizedDescription)")
            }

        case .development:
            Log("Development distribution has no remote information to check.".yellow)
        }
    }
}
