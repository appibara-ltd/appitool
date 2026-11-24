import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleMetadataDownloadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Downloads App Store listing text into <locale>/metadata/<field>.txt files."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "Filter by App Store locale (e.g. en-US, tr). Omit to download all localizations.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Output directory (defaults to $STORE_ASSETS_PATH/apple/, or ~/.appitool/assets/<project>/apple/ when unset).")
    var output: String?

    @Flag(name: .long, help: "Preview files that would be written without writing them.")
    var dryRun: Bool = false

    func execute() async throws {
        Log("🔍 Resolving App Store version and app info...".dim)
        let context = try await AppleMetadataContext.resolve(app: app)
        let root = CLIValues.trimmedNonEmpty(output).map(ScreenshotFileResolver.expandPath) ?? context.defaultStoreRoot()
        let locales = context.remoteLocales.filter {
            guard let filter = CLIValues.trimmedNonEmpty(locale) else { return true }
            return $0.caseInsensitiveCompare(filter) == .orderedSame
        }
        if locales.isEmpty {
            Log("🟡 No localizations found\(locale.map { " for '\($0)'" } ?? "").".yellow)
            return
        }

        Log((dryRun ? "\n🟡 [Dry Run] Would write metadata to \(root.path):" : "📥 Writing metadata to \(root.path)...").dim)
        var fileCount = 0
        for code in locales {
            let remote = context.remoteValues(code)
            let values = AppleMetadataField.allCases.map { (field: $0.field, value: remote[$0.rawValue] ?? nil) }
            let nonEmpty = values.filter { !StoreMetadataFiles.normalize($0.value).isEmpty }
            if dryRun {
                Log("  • \(code)/metadata/: \(nonEmpty.map { "\($0.field.key).txt" }.joined(separator: ", "))".dim)
                fileCount += nonEmpty.count
                continue
            }
            let written = try StoreMetadataFiles.write(directory: StoreMetadataFiles.directory(storeRoot: root, locale: code), values: values)
            fileCount += written.count
            Log("  ✔ \(code)/metadata/ ".green + "(\(written.count) file(s))".dim)
        }

        // App-level fields (all locales mode only). The demo account password is never written.
        if CLIValues.trimmedNonEmpty(locale) == nil {
            let remote = try await context.fetchStoreRemote().values
            let values = AppleStoreField.allCases.filter { !$0.field.isSecret }.map { (field: $0.field, value: remote[$0.rawValue] ?? nil) }
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
            Log("\n🟢 Downloaded \(fileCount) metadata file(s) for \(locales.count) localization(s) from version \(context.versionLabel).".green.bold + "\n")
        } else {
            Log("")
        }
    }
}
