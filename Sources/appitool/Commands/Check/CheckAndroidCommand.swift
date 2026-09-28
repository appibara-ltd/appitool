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

    @Option(name: .shortAndLong, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @Option(name: .long, help: "Firebase App ID for Android (defaults to FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        let env = ProcessInfo.processInfo.environment

        switch distribution {
        case .adhoc:
            guard let resolvedAppId = firebaseAppId ?? env["FIREBASE_ANDROID_APP_ID"], !resolvedAppId.isEmpty else {
                print("Error: ".red.bold + "Missing Firebase App ID for Android. Provide --firebase-app-id or configure FIREBASE_ANDROID_APP_ID in .env.")
                return
            }

            let token = env["FIREBASE_TOKEN"]
            let googleKey = env["GOOGLE_KEY"]
            guard let service = try FirebaseService.makeService(token: token, googleKey: googleKey) else {
                print("Error: ".red.bold + "Missing Firebase credentials. Provide GOOGLE_KEY or FIREBASE_TOKEN in .env.")
                return
            }

            print("Checking Firebase Android App information...".dim)
            let appTask = GetFirebaseAppInfoTask()
            do {
                guard case .android(let app) = try await appTask.run(.init(platform: .android, firebaseAppId: resolvedAppId, service: service)) else {
                    return
                }
                print("\n" + "─── Firebase Android App Information ───".cyan.bold)
                if let appId = app.appId {
                    print("App ID:        ".bold + "\(appId)".green)
                }
                if let resolvedPackageName = app.packageName {
                    print("Package Name:  ".bold + "\(resolvedPackageName)".yellow)
                }
                if let displayName = app.displayName {
                    print("Display Name:  ".bold + "\(displayName)")
                }
                if let projectId = app.projectId {
                    print("Project ID:    ".bold + "\(projectId)")
                }
                if let state = app.state {
                    print("State:         ".bold + "\(state.rawValue)")
                }

                let buildTask = GetLatestBuildNumberTask()
                if let buildInfo = try? await buildTask.run(.init(
                    target: .android(packageName: packageName ?? app.packageName, firebaseAppId: resolvedAppId, firebaseService: service),
                    distribution: .adhoc
                )) {
                    print("Latest Build:  ".bold + "v\(buildInfo.version) (\(buildInfo.buildNumber))".green.bold)
                }
                print("────────────────────────────────────────".cyan.dim + "\n")
            } catch {
                print("Error: ".red.bold + "Failed to retrieve Firebase Android App info: \(error.localizedDescription)")
            }

        case .appstore:
            guard let targetPackageName = packageName ?? env["GOOGLE_PACKAGE_NAME"], !targetPackageName.isEmpty else {
                print("Error: ".red.bold + "No package name specified. Provide -p, --package-name or configure GOOGLE_PACKAGE_NAME in .env.")
                return
            }

            guard let service = try googleCredentials.makeService() else {
                print("Error: ".red.bold + "Missing Google Play Service Account credentials (provide --google-key or configure GOOGLE_KEY in .env).")
                return
            }

            print("Fetching latest build from Google Play Console for ".dim + "\(targetPackageName)".bold + "...".dim)
            let task = GetLatestBuildNumberTask()
            do {
                let info = try await task.run(.init(
                    target: .android(packageName: targetPackageName, service: service),
                    distribution: .appstore
                ))
                print("\n" + "─── Google Play Store Build Information ───".cyan.bold)
                print("Package Name:  ".bold + "\(targetPackageName)".yellow)
                print("Version:       ".bold + "\(info.version)".green)
                print("Build Number:  ".bold + "\(info.buildNumber)".green.bold)
                print("───────────────────────────────────────────".cyan.dim + "\n")
            } catch {
                print("Error: ".red.bold + "Failed to retrieve Google Play build: \(error.localizedDescription)")
            }

        case .development:
            print("Development distribution has no remote information to check.".yellow)
        }
    }
}
