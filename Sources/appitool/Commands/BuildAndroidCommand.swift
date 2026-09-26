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

    @Option(name: .shortAndLong, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let targetPackageName = packageName ?? ProcessInfo.processInfo.environment["GOOGLE_PACKAGE_NAME"], !targetPackageName.isEmpty else {
            print("Error: ".red.bold + "No package name specified. Provide -p, --package-name <PACKAGE> or set GOOGLE_PACKAGE_NAME in .env.")
            return
        }

        guard let service = try googleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing Google Play Service Account credentials (provide --google-key or configure GOOGLE_KEY in .env).")
            return
        }

        print("Fetching latest build from Google Play Console for ".dim + "\(targetPackageName)".bold + "...".dim)
        let task = GetLatestBuildNumberTask()
        do {
            let info = try await task.run(.init(target: .android(packageName: targetPackageName, service: service)))
            print("✓ Latest Remote Build: ".green.bold + "Version \(info.version)".bold + " (Build Number: \(info.buildNumber))".yellow.bold)
        } catch {
            print("Error: ".red.bold + "Failed to retrieve latest Google Play build: \(error.localizedDescription)")
        }
    }
}
