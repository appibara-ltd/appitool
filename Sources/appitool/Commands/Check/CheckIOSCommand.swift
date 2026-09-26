import ArgumentParser
import Foundation
import Rainbow

struct CheckIOSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Checks iOS application information from distribution providers."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to adhoc.")
    var distribution: BuildCommand.Distribution = .adhoc

    @Option(name: .long, help: "Firebase App ID for iOS (defaults to FIREBASE_IOS_APP_ID in .env).")
    var firebaseAppId: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        switch distribution {
        case .adhoc:
            guard let resolvedAppId = firebaseAppId ?? ProcessInfo.processInfo.environment["FIREBASE_IOS_APP_ID"], !resolvedAppId.isEmpty else {
                print("Error: ".red.bold + "Missing Firebase App ID for iOS. Provide --firebase-app-id or configure FIREBASE_IOS_APP_ID in .env.")
                return
            }

            let token = ProcessInfo.processInfo.environment["FIREBASE_TOKEN"]
            let googleKey = ProcessInfo.processInfo.environment["GOOGLE_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]
            guard let service = try FirebaseService.makeService(token: token, googleKey: googleKey) else {
                print("Error: ".red.bold + "Missing Firebase credentials. Provide GOOGLE_KEY, GOOGLE_APPLICATION_CREDENTIALS, or FIREBASE_TOKEN in .env.")
                return
            }

            print("Checking Firebase iOS App information...".dim)
            let task = GetFirebaseAppInfoTask()
            do {
                guard case .ios(let app) = try await task.run(.init(platform: .ios, firebaseAppId: resolvedAppId, service: service)) else {
                    return
                }
                print("\n" + "─── Firebase iOS App Information ───".cyan.bold)
                if let appId = app.appId {
                    print("App ID: ".bold + "\(appId)".green)
                }
                if let bundleId = app.bundleId {
                    print("Bundle ID: ".bold + "\(bundleId)".yellow)
                }
                if let displayName = app.displayName {
                    print("Display Name: ".bold + "\(displayName)")
                }
                if let projectId = app.projectId {
                    print("Project ID: ".bold + "\(projectId)")
                }
                if let appStoreId = app.appStoreId {
                    print("App Store ID: ".bold + "\(appStoreId)")
                }
                if let teamId = app.teamId {
                    print("Team ID: ".bold + "\(teamId)")
                }
                if let state = app.state {
                    print("State: ".bold + "\(state.rawValue)")
                }
                print("────────────────────────────────────".cyan.dim + "\n")
            } catch {
                print("Error: ".red.bold + "Failed to retrieve Firebase iOS App info: \(error.localizedDescription)")
            }

        case .appstore:
            print("App Store metadata check is currently not implemented for check command.".yellow)

        case .development:
            print("Development distribution has no remote information to check.".yellow)
        }
    }
}
