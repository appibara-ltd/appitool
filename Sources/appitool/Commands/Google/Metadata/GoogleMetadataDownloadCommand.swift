import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleMetadataDownloadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Downloads Google Play store listing text into <locale>/metadata/<field>.txt files."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .long, help: "Filter by BCP-47 language code (e.g. en-US, tr-TR). Omit to download all languages.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Output directory (defaults to $STORE_ASSETS_PATH/google/, or ~/.appitool/assets/<package-name>/google/ when unset).")
    var output: String?

    @Flag(name: .long, help: "Preview files that would be written without writing them.")
    var dryRun: Bool = false

    func execute() async throws {
        let packageName = try app.requirePackageName()
        let service = try app.requireService()
        let root = CLIValues.trimmedNonEmpty(output).map(ScreenshotFileResolver.expandPath)
            ?? GoogleMetadataSupport.defaultStoreRoot(packageName: packageName)

        Log("🔍 Fetching Google Play store listings for '\(packageName)'...".dim)
        let listings = GoogleMetadataSupport.filter(
            try await GoogleMetadataSupport.fetchListings(service: service, packageName: packageName),
            locale: locale
        )
        if listings.isEmpty {
            Log("🟡 No store listings found\(locale.map { " for '\($0)'" } ?? "").".yellow)
            return
        }

        Log((dryRun ? "\n🟡 [Dry Run] Would write metadata to \(root.path):" : "📥 Writing metadata to \(root.path)...").dim)
        var fileCount = 0
        for listing in listings.sorted(by: { $0.language < $1.language }) {
            let remote = listing.metadataValues
            let values = GoogleMetadataField.allCases.map { (field: $0.field, value: remote[$0.rawValue] ?? nil) }
            let nonEmpty = values.filter { !StoreMetadataFiles.normalize($0.value).isEmpty }
            if dryRun {
                Log("  • \(listing.language)/metadata/: \(nonEmpty.map { "\($0.field.key).txt" }.joined(separator: ", "))".dim)
                fileCount += nonEmpty.count
                continue
            }
            let written = try StoreMetadataFiles.write(
                directory: StoreMetadataFiles.directory(storeRoot: root, locale: listing.language),
                values: values
            )
            fileCount += written.count
            Log("  ✔ \(listing.language)/metadata/ ".green + "(\(written.count) file(s))".dim)
        }

        // App-level contact details (all languages mode only).
        if CLIValues.trimmedNonEmpty(locale) == nil {
            let details = try await GoogleMetadataSupport.fetchDetails(service: service, packageName: packageName)
            let values = GoogleStoreField.allCases.map { (field: $0.field, value: details.metadataValues[$0.rawValue] ?? nil) }
            if dryRun {
                let names = values.filter { !StoreMetadataFiles.normalize($0.value).isEmpty }.map { "\($0.field.key).txt" }
                Log("  • metadata/: \(names.joined(separator: ", "))".dim)
                fileCount += names.count
            } else {
                let written = try StoreMetadataFiles.write(directory: StoreMetadataFiles.storeDirectory(storeRoot: root), values: values)
                fileCount += written.count
                Log("  ✔ metadata/ (app-level) ".green + "(\(written.count) file(s))".dim)
            }
        }

        if !dryRun {
            Log("\n🟢 Downloaded \(fileCount) metadata file(s) for \(listings.count) language(s).".green.bold + "\n")
        } else {
            Log("")
        }
    }
}
