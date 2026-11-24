import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleListAppsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists applications registered in App Store Connect."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by bundle identifier (e.g. com.example.app).")
    var bundleId: String?

    @Option(name: .shortAndLong, help: "Filter by application name.")
    var name: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let service = try appleCredentials.requireService()

        Log("🔍 Fetching apps from App Store Connect...".dim)
        let apps = try await service.fetchApps(limit: limit, bundleId: bundleId, name: name)

        if apps.isEmpty {
            if let filter = bundleId ?? name {
                Log("No applications matching '\(filter)' found in App Store Connect.".yellow)
            } else {
                Log("No applications found in App Store Connect.".yellow)
            }
            return
        }

        Log("\nFound \(apps.count) application(s):".bold)
        for app in apps {
            let nameStr = app.attributes?.name ?? "unnamed"
            let bundleIdStr = app.attributes?.bundleId ?? "no bundle ID"
            let appId = app.id
            let skuStr = app.attributes?.sku ?? "-"
            let localeStr = app.attributes?.primaryLocale ?? "-"

            Log("  • ".cyan + "\(nameStr)".bold + " (\(bundleIdStr))".green + " [App ID: \(appId), SKU: \(skuStr), Primary Locale: \(localeStr)]".dim)
        }
        Log("")
    }
}
