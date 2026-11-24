import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleMetadataListCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Shows the Google Play store listing text per language."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .long, help: "Filter by BCP-47 language code (e.g. en-US, tr-TR). Omit to list all languages.")
    var locale: String?

    func execute() async throws {
        let packageName = try app.requirePackageName()
        let service = try app.requireService()
        Log("🔍 Fetching Google Play store listings for '\(packageName)'...".dim)
        let listings = GoogleMetadataSupport.filter(
            try await GoogleMetadataSupport.fetchListings(service: service, packageName: packageName),
            locale: locale
        )
        if listings.isEmpty {
            Log("🟡 No store listings found\(locale.map { " for '\($0)'" } ?? "").".yellow)
            return
        }

        if CLIValues.trimmedNonEmpty(locale) == nil {
            let details = try await GoogleMetadataSupport.fetchDetails(service: service, packageName: packageName)
            Log("\n  [app]".cyan.bold + " (app-level)".dim)
            for field in GoogleStoreField.allCases.map(\.field) {
                MetadataListFormatter.log(field: field, value: details.metadataValues[field.key] ?? nil)
            }
        }
        for listing in listings.sorted(by: { $0.language < $1.language }) {
            let remote = listing.metadataValues
            Log("\n  [\(listing.language)]".cyan.bold)
            for field in GoogleMetadataField.allCases.map(\.field) {
                MetadataListFormatter.log(field: field, value: remote[field.key] ?? nil)
            }
        }
        Log("")
    }
}
