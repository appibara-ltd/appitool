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

    @Option(name: .shortAndLong, help: "Target iOS bundle identifier (defaults to APPLE_BUNDLE_ID in .env).")
    var bundleId: String?

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let targetBundleId = bundleId ?? ProcessInfo.processInfo.environment["APPLE_BUNDLE_ID"], !targetBundleId.isEmpty else {
            print("Error: ".red.bold + "No bundle identifier specified. Provide -b, --bundle-id <ID> or set APPLE_BUNDLE_ID in .env.")
            return
        }

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (provide --apple-key-id, --apple-issuer-id, --apple-key or configure .env).")
            return
        }

        print("Fetching latest build from TestFlight for ".dim + "\(targetBundleId)".bold + "...".dim)
        let task = GetLatestBuildNumberTask()
        do {
            let info = try await task.run(.init(target: .ios(bundleId: targetBundleId, service: service)))
            print("✓ Latest Remote Build: ".green.bold + "Version \(info.version)".bold + " (Build Number: \(info.buildNumber))".yellow.bold)
        } catch {
            print("Error: ".red.bold + "Failed to retrieve latest TestFlight build: \(error.localizedDescription)")
        }
    }
}
