import ArgumentParser
import Foundation
import Rainbow

struct BuildIOSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Builds the project and retrieves build information for iOS."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Option(name: .shortAndLong, help: "Target iOS bundle identifier (defaults to APPLE_BUNDLE_ID in .env). Required for App Store.")
    var bundleId: String?

    @Option(name: .long, help: "Firebase App ID for iOS AdHoc distribution (defaults to FIREBASE_IOS_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let task = GetLatestBuildNumberTask()

        switch distribution {
        case .development:
            do {
                _ = try await task.run(.init(target: .ios(bundleId: bundleId), distribution: .development))
            } catch {
                // Warning already printed by task
            }

        case .appstore:
            guard let targetBundleId = bundleId ?? ProcessInfo.processInfo.environment["APPLE_BUNDLE_ID"], !targetBundleId.isEmpty else {
                print("Error: ".red.bold + "No bundle identifier specified. Provide -b, --bundle-id <ID> or set APPLE_BUNDLE_ID in .env.")
                return
            }

            guard let service = try appleCredentials.makeService() else {
                print("Error: ".red.bold + "Missing App Store Connect credentials (provide --apple-key-id, --apple-issuer-id, --apple-key or configure .env).")
                return
            }

            print("Fetching latest build from TestFlight for ".dim + "\(targetBundleId)".bold + "...".dim)
            do {
                let info = try await task.run(.init(
                    target: .ios(bundleId: targetBundleId, service: service),
                    distribution: .appstore
                ))
                print("✓ Latest Remote Build: ".green.bold + "Version \(info.version)".bold + " (Build Number: \(info.buildNumber))".yellow.bold)
            } catch {
                print("Error: ".red.bold + "Failed to retrieve latest TestFlight build: \(error.localizedDescription)")
            }

        case .adhoc:
            let displayTarget = bundleId ?? firebaseAppId ?? ProcessInfo.processInfo.environment["FIREBASE_IOS_APP_ID"] ?? "iOS App"
            print("Fetching latest build from Firebase App Distribution for ".dim + "\(displayTarget)".bold + "...".dim)
            do {
                let info = try await task.run(.init(
                    target: .ios(bundleId: bundleId, firebaseAppId: firebaseAppId),
                    distribution: .adhoc
                ))
                print("✓ Latest Remote Build: ".green.bold + "Version \(info.version)".bold + " (Build Number: \(info.buildNumber))".yellow.bold)
            } catch {
                print("Error: ".red.bold + "Failed to retrieve latest Firebase build: \(error.localizedDescription)")
            }
        }
    }
}
