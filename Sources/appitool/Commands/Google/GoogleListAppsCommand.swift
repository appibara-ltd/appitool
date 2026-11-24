import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Lists the Google Play apps the service account (`-g, --google-key` / `GOOGLE_KEY`) can access.
struct GoogleListAppsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-apps",
        abstract: "Lists Google Play apps accessible with the service account key (package name and Play Console title)."
    )

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by app title (case-insensitive substring).")
    var name: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let service = try googleCredentials.requireService()
        Log("🔍 Searching apps accessible to the service account...".dim)

        let apps: [GooglePlayAccessibleApp]
        do {
            apps = try await service.searchAccessibleApps()
        } catch let error as GooglePlayImageError {
            throw CommandError("Failed to list accessible apps: \(error.localizedDescription)", hint: Self.hint(for: error))
        }

        let filtered = Self.filter(apps, name: name, limit: limit)
        if filtered.isEmpty {
            Log("🟡 No accessible apps found\(name.map { " matching '\($0)'" } ?? "").".yellow)
            Log("   Make sure the service account is invited to the apps in Play Console.".dim)
            return
        }

        Log("\nFound \(filtered.count) app(s):".bold)
        for app in filtered {
            Log("  • ".cyan + "\(app.displayName ?? "-")".bold + " [\(app.packageName ?? app.name ?? "-")]".dim)
        }
        Log("")
    }

    /// Sorts by title and applies the optional title filter and limit.
    static func filter(_ apps: [GooglePlayAccessibleApp], name: String?, limit: Int?) -> [GooglePlayAccessibleApp] {
        let sorted = apps
            .filter { app in
                guard let needle = CLIValues.trimmedNonEmpty(name) else { return true }
                return (app.displayName ?? "").localizedCaseInsensitiveContains(needle)
            }
            .sorted { ($0.displayName ?? $0.packageName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? $1.packageName ?? "") == .orderedAscending }
        return limit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
    }

    static func hint(for error: GooglePlayImageError) -> String? {
        guard case .apiError(let status, _) = error else { return nil }
        switch status {
        case 403:
            return "Enable the 'Google Play Developer Reporting API' in the service account's Google Cloud project and make sure the account has access to the apps in Play Console."
        case 401:
            return "Check the service account key (-g, --google-key / GOOGLE_KEY)."
        default:
            return nil
        }
    }
}
