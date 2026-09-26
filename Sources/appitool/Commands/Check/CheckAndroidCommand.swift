import ArgumentParser
import Foundation
import Rainbow

struct CheckAndroidCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Checks Android application information from distribution providers."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to adhoc.")
    var distribution: BuildCommand.Distribution = .adhoc

    @Option(name: .long, help: "Firebase App ID for Android (defaults to FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        switch distribution {
        case .adhoc:
            guard let resolvedAppId = firebaseAppId ?? ProcessInfo.processInfo.environment["FIREBASE_ANDROID_APP_ID"], !resolvedAppId.isEmpty else {
                print("Error: ".red.bold + "Missing Firebase App ID for Android. Provide --firebase-app-id or configure FIREBASE_ANDROID_APP_ID in .env.")
                return
            }

            let token = ProcessInfo.processInfo.environment["FIREBASE_TOKEN"]
            let googleKey = ProcessInfo.processInfo.environment["GOOGLE_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]
            guard let service = try FirebaseService.makeService(token: token, googleKey: googleKey) else {
                print("Error: ".red.bold + "Missing Firebase credentials. Provide GOOGLE_KEY, GOOGLE_APPLICATION_CREDENTIALS, or FIREBASE_TOKEN in .env.")
                return
            }

            print("Checking Firebase Android App information...".dim)
            let task = GetFirebaseAppInfoTask()
            do {
                guard case .android(let app) = try await task.run(.init(platform: .android, firebaseAppId: resolvedAppId, service: service)) else {
                    return
                }
                print("\n" + "─── Firebase Android App Information ───".cyan.bold)
                if let appId = app.appId {
                    print("App ID: ".bold + "\(appId)".green)
                }
                if let packageName = app.packageName {
                    print("Package Name: ".bold + "\(packageName)".yellow)
                }
                if let displayName = app.displayName {
                    print("Display Name: ".bold + "\(displayName)")
                }
                if let projectId = app.projectId {
                    print("Project ID: ".bold + "\(projectId)")
                }
                if let state = app.state {
                    print("State: ".bold + "\(state.rawValue)")
                }
                print("────────────────────────────────────────".cyan.dim + "\n")
            } catch {
                print("Error: ".red.bold + "Failed to retrieve Firebase Android App info: \(error.localizedDescription)")
            }

        case .appstore:
            print("Google Play metadata check is currently not implemented for check command.".yellow)

        case .development:
            print("Development distribution has no remote information to check.".yellow)
        }
    }
}
