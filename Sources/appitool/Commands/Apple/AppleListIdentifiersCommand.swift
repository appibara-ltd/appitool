import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleListIdentifiersCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-identifiers",
        abstract: "Lists App/Bundle Identifiers registered on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by bundle identifier (e.g. com.example.app).")
    var bundleId: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func execute() async throws {
        let service = try appleCredentials.requireService()

        Log("🔍 Fetching bundle identifiers from Apple Developer Portal...".dim)
        let bundleIds = try await service.fetchBundleIds(limit: limit, identifier: bundleId)

        if bundleIds.isEmpty {
            if let filter = bundleId {
                Log("No bundle identifiers matching '\(filter)' found on Apple Developer Portal.".yellow)
            } else {
                Log("No bundle identifiers found on Apple Developer Portal.".yellow)
            }
            return
        }

        Log("\nFound \(bundleIds.count) bundle identifier(s):".bold)
        for item in bundleIds {
            let idStr = item.attributes?.identifier ?? "unknown"
            let nameStr = item.attributes?.name ?? "unnamed"
            let platformStr = item.attributes?.platform?.rawValue ?? "UNIVERSAL"
            let portalId = item.id
            let seedId = item.attributes?.seedId ?? "-"

            Log("  • ".cyan + "\(idStr)".bold + " (\(nameStr))".dim + " [Platform: \(platformStr), Portal ID: \(portalId), Prefix/Seed ID: \(seedId)]".dim)
        }
        Log("")
    }
}
