import ArgumentParser
import Foundation
import Rainbow

struct BuildAndroidCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Builds the project and retrieves build information for Android."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Option(name: .shortAndLong, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env). Required for App Store.")
    var packageName: String?

    @Option(name: .long, help: "Firebase App ID for Android AdHoc distribution (defaults to FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let task = GetLatestBuildNumberTask()

        switch distribution {
        case .development:
            do {
                _ = try await task.run(.init(target: .android(packageName: packageName), distribution: .development))
            } catch {
                // Warning already printed by task
            }

        case .appstore:
            guard let targetPackageName = packageName ?? ProcessInfo.processInfo.environment["GOOGLE_PACKAGE_NAME"], !targetPackageName.isEmpty else {
                print("Error: ".red.bold + "No package name specified. Provide -p, --package-name <PACKAGE> or set GOOGLE_PACKAGE_NAME in .env.")
                return
            }

            guard let service = try googleCredentials.makeService() else {
                print("Error: ".red.bold + "Missing Google Play Service Account credentials (provide --google-key or configure GOOGLE_KEY in .env).")
                return
            }

            print("Fetching latest build from Google Play Console for ".dim + "\(targetPackageName)".bold + "...".dim)
            do {
                let info = try await task.run(.init(
                    target: .android(packageName: targetPackageName, service: service),
                    distribution: .appstore
                ))
                print("✓ Latest Remote Build: ".green.bold + "Version \(info.version)".bold + " (Build Number: \(info.buildNumber))".yellow.bold)
            } catch {
                print("Error: ".red.bold + "Failed to retrieve latest Google Play build: \(error.localizedDescription)")
            }

        case .adhoc:
            let resolvedAppId = firebaseAppId ?? ProcessInfo.processInfo.environment["FIREBASE_ANDROID_APP_ID"]
            let displayTarget = packageName ?? resolvedAppId ?? "Android App"
            print("Fetching latest build from Firebase App Distribution for ".dim + "\(displayTarget)".bold + "...".dim)

            guard let targetAppId = resolvedAppId, !targetAppId.isEmpty else {
                print("Error: ".red.bold + "Missing Firebase App ID for Android. Provide --firebase-app-id or configure FIREBASE_ANDROID_APP_ID in .env.")
                return
            }

            let token = ProcessInfo.processInfo.environment["FIREBASE_TOKEN"]
            let googleKey = googleCredentials.resolveKey() ?? ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]
            guard let firebaseService = try FirebaseService.makeService(token: token, googleKey: googleKey) else {
                print("Error: ".red.bold + "Missing Firebase credentials. Provide FIREBASE_TOKEN or GOOGLE_KEY / GOOGLE_APPLICATION_CREDENTIALS in .env.")
                return
            }

            do {
                let info = try await task.run(.init(
                    target: .android(packageName: packageName, firebaseAppId: targetAppId, firebaseService: firebaseService),
                    distribution: .adhoc
                ))
                print("✓ Latest Remote Build: ".green.bold + "Version \(info.version)".bold + " (Build Number: \(info.buildNumber))".yellow.bold)
            } catch {
                print("Error: ".red.bold + "Failed to retrieve latest Firebase build: \(error.localizedDescription)")
            }
        }
    }
}
