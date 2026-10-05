import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseListReleasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-releases",
        abstract: "Lists uploaded releases for a Firebase application."
    )

    @OptionGroup
    var credentials: FirebaseCredentialsOptions

    @Option(name: .shortAndLong, help: "Maximum number of releases to return (1-100; defaults to 25).")
    var limit: Int?

    @Option(name: .shortAndLong, help: "Ordering of the results (e.g. 'createTime desc').")
    var orderBy: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try credentials.makeService() else {
            Log("Error: ".red.bold + "Missing Google credentials (configure GOOGLE_KEY in .env or via --google-key).")
            return
        }

        guard let appId = credentials.resolveAppId() else {
            Log("Error: ".red.bold + "Missing Firebase App ID (configure FIREBASE_IOS_APP_ID / FIREBASE_ANDROID_APP_ID in .env or via --firebase-app-id).")
            return
        }

        Log("🔍 Fetching releases from Firebase App Distribution [App: \(appId)]...".dim)
        let (rawReleases, _) = try await service.listReleases(
            firebaseAppId: appId,
            pageSize: limit,
            orderBy: orderBy
        )

        let releases: [FirebaseAppDistributionRelease] = {
            if let limit, limit > 0 {
                return Array(rawReleases.prefix(limit))
            }
            return rawReleases
        }()

        if releases.isEmpty {
            Log("No releases found for Firebase App ID: \(appId)".yellow)
            return
        }

        Log("\nFound \(releases.count) release(s):".bold)
        for r in releases {
            let version = r.displayVersion ?? "-"
            let build = r.buildVersion ?? "-"
            let created = formatHumanReadableDate(r.createTime)
            let notes = r.releaseNotes?.text?.replacingOccurrences(of: "\n", with: " ") ?? "-"

            Log("  • ".cyan + "v\(version) (\(build))".bold.green)
            Log("    Created: \(created.bold)".dim)
            Log("    Notes: \(notes)".dim)
            if let consoleUri = r.firebaseConsoleUri {
                Log("    Console: \(consoleUri.bold)".dim)
            }
        }
        Log("")
    }

    private func formatHumanReadableDate(_ dateString: String?) -> String {
        guard let dateString, !dateString.isEmpty else { return "-" }
        guard let date = try? Date(dateString, strategy: .iso8601) else { return dateString }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
