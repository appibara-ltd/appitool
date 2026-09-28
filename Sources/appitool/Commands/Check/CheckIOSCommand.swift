import ArgumentParser
import Foundation
import AppleServices
import GoogleServices
import Rainbow

struct CheckIOSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Checks iOS application and build information from distribution providers."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to adhoc.")
    var distribution: BuildCommand.Distribution = .adhoc

    @Option(name: .shortAndLong, help: "Target iOS bundle identifier (defaults to APPLE_BUNDLE_ID in .env).")
    var bundleId: String?

    @Option(name: .long, help: "Firebase App ID for iOS (defaults to FIREBASE_IOS_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        let env = ProcessInfo.processInfo.environment

        switch distribution {
        case .adhoc:
            guard let resolvedAppId = firebaseAppId ?? env["FIREBASE_IOS_APP_ID"], !resolvedAppId.isEmpty else {
                print("Error: ".red.bold + "Missing Firebase App ID for iOS. Provide --firebase-app-id or configure FIREBASE_IOS_APP_ID in .env.")
                return
            }

            let token = env["FIREBASE_TOKEN"]
            let googleKey = env["GOOGLE_KEY"]
            guard let service = try FirebaseService.makeService(token: token, googleKey: googleKey) else {
                print("Error: ".red.bold + "Missing Firebase credentials. Provide GOOGLE_KEY or FIREBASE_TOKEN in .env.")
                return
            }

            print("Checking Firebase iOS App information...".dim)
            let appTask = GetFirebaseAppInfoTask()
            do {
                guard case .ios(let app) = try await appTask.run(.init(platform: .ios, firebaseAppId: resolvedAppId, service: service)) else {
                    return
                }
                print("\n" + "─── Firebase iOS App Information ───".cyan.bold)
                if let appId = app.appId {
                    print("App ID:        ".bold + "\(appId)".green)
                }
                if let resolvedBundleId = app.bundleId {
                    print("Bundle ID:     ".bold + "\(resolvedBundleId)".yellow)
                }
                if let displayName = app.displayName {
                    print("Display Name:  ".bold + "\(displayName)")
                }
                if let projectId = app.projectId {
                    print("Project ID:    ".bold + "\(projectId)")
                }
                if let appStoreId = app.appStoreId {
                    print("App Store ID:  ".bold + "\(appStoreId)")
                }
                if let teamId = app.teamId {
                    print("Team ID:       ".bold + "\(teamId)")
                }
                if let state = app.state {
                    print("State:         ".bold + "\(state.rawValue)")
                }

                let buildTask = GetLatestBuildNumberTask()
                if let buildInfo = try? await buildTask.run(.init(
                    target: .ios(bundleId: bundleId ?? app.bundleId, firebaseAppId: resolvedAppId, firebaseService: service),
                    distribution: .adhoc
                )) {
                    print("Latest Build:  ".bold + "v\(buildInfo.version) (\(buildInfo.buildNumber))".green.bold)
                }
                print("────────────────────────────────────".cyan.dim + "\n")
            } catch {
                print("Error: ".red.bold + "Failed to retrieve Firebase iOS App info: \(error.localizedDescription)")
            }

        case .appstore:
            guard let targetBundleId = bundleId ?? env["APPLE_BUNDLE_ID"], !targetBundleId.isEmpty else {
                print("Error: ".red.bold + "No bundle identifier specified. Provide -b, --bundle-id or configure APPLE_BUNDLE_ID in .env.")
                return
            }

            guard let service = try appleCredentials.makeService() else {
                print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
                return
            }

            print("Fetching latest build from App Store Connect for ".dim + "\(targetBundleId)".bold + "...".dim)
            let task = GetLatestBuildNumberTask()
            do {
                let info = try await task.run(.init(
                    target: .ios(bundleId: targetBundleId, service: service),
                    distribution: .appstore
                ))
                print("\n" + "─── App Store Connect Build Information ───".cyan.bold)
                print("Bundle ID:     ".bold + "\(targetBundleId)".yellow)
                print("Version:       ".bold + "\(info.version)".green)
                print("Build Number:  ".bold + "\(info.buildNumber)".green.bold)
                print("───────────────────────────────────────────".cyan.dim + "\n")
            } catch {
                print("Error: ".red.bold + "Failed to retrieve App Store Connect build: \(error.localizedDescription)")
            }

        case .development:
            print("Development distribution has no remote information to check.".yellow)
        }
    }
}
