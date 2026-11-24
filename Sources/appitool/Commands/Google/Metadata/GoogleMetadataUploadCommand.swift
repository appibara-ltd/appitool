import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleMetadataUploadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Uploads changed Google Play listing text from <locale>/metadata/<field>.txt files in one edit (only fields that differ are sent)."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .long, help: "Upload only this BCP-47 language (e.g. en-US). Omit to upload every local language.")
    var locale: String?

    @Flag(name: .long, help: "Validate the edit session without committing changes.")
    var validateOnly: Bool = false

    @Flag(name: .long, help: "Commit changes without automatically sending them for review.")
    var changesNotSentForReview: Bool = false

    @Flag(name: .long, help: "Show the per-field changes without sending them.")
    var dryRun: Bool = false

    @Argument(help: "Metadata root containing <locale>/metadata/ folders (defaults to $STORE_ASSETS_PATH/google/, or ~/.appitool/assets/<package-name>/google/ when unset).")
    var path: String?

    func execute() async throws {
        let packageName = try app.requirePackageName()
        let service = try app.requireService()
        let root = CLIValues.trimmedNonEmpty(path).map(ScreenshotFileResolver.expandPath)
            ?? GoogleMetadataSupport.defaultStoreRoot(packageName: packageName)

        let localeFilter = CLIValues.trimmedNonEmpty(locale)
        let localLocales = StoreMetadataFiles.locales(storeRoot: root, localeFilter: localeFilter)
        // App-level contact details are uploaded only without --locale.
        let includeStore = localeFilter == nil && StoreMetadataFiles.hasStoreDirectory(storeRoot: root)
        guard !localLocales.isEmpty || includeStore else {
            throw CommandError(
                "No <locale>/metadata/ or metadata/ folders found under \(root.path)\(locale.map { " for '\($0)'" } ?? "").",
                hint: "Run 'appitool google metadata download' first."
            )
        }

        Log("🔍 Fetching Google Play store listings for '\(packageName)'...".dim)
        let listings = try await GoogleMetadataSupport.fetchListings(service: service, packageName: packageName)

        let fields = GoogleMetadataField.allCases.map(\.field)
        var changes: [StoreMetadataChange] = []
        var errors: [String] = []

        if includeStore {
            let storeFields = GoogleStoreField.allCases.map(\.field)
            let local = try StoreMetadataFiles.read(directory: StoreMetadataFiles.storeDirectory(storeRoot: root), fields: storeFields)
            let details = try await GoogleMetadataSupport.fetchDetails(service: service, packageName: packageName)
            changes += StoreMetadataFiles.diff(locale: StoreMetadataFiles.appLevelLabel, fields: storeFields, local: local, remote: details.metadataValues)
        }
        for code in localLocales {
            guard let listing = listings.first(where: { $0.language.caseInsensitiveCompare(code) == .orderedSame }) else {
                Log("🟡 [\(code)] has no Google Play store listing; skipped (add the language in Play Console first).".yellow)
                continue
            }
            let local = try StoreMetadataFiles.read(directory: StoreMetadataFiles.directory(storeRoot: root, locale: code), fields: fields)
            errors += StoreMetadataFiles.lengthErrors(locale: code, fields: fields, local: local)
            changes += StoreMetadataFiles.diff(locale: listing.language, fields: fields, local: local, remote: listing.metadataValues)
        }
        guard errors.isEmpty else {
            throw CommandError("Metadata upload aborted before making changes:\n" + errors.map { "  • \($0)" }.joined(separator: "\n"))
        }

        Log("\n🔄 Google Play listing changes for \(packageName):".bold)
        if changes.isEmpty {
            Log("  No changes — Google Play already matches the local files.".dim + "\n")
            return
        }
        for change in changes {
            Log("  [\(change.locale)] ".cyan + StoreMetadataFiles.describe(change))
        }
        if dryRun {
            Log("\n🟡 [Dry Run] No changes were made.".yellow.bold + "\n")
            return
        }

        let appLevel = changes.filter { $0.locale == StoreMetadataFiles.appLevelLabel }
        let languages = Array(Set(changes.map(\.locale))).filter { $0 != StoreMetadataFiles.appLevelLabel }.sorted()
        try await service.withEditSession(
            packageName: packageName,
            commit: true,
            validateOnly: validateOnly,
            changesNotSentForReview: changesNotSentForReview ? true : nil
        ) { editId in
            if !appLevel.isEmpty {
                try await service.patchAppDetails(packageName: packageName, editId: editId, changes: GooglePlayAppDetails.changes(from: appLevel))
                Log("  ✔ [app] updated \(appLevel.count) field(s)".green)
            }
            for language in languages {
                try await service.patchListing(
                    packageName: packageName,
                    editId: editId,
                    changes: Self.listingChanges(language: language, changes: changes)
                )
                Log("  ✔ [\(language)] updated \(changes.filter { $0.locale == language }.count) field(s)".green)
            }
        }

        Log(validateOnly
            ? "\n🟢 Google Play listing changes validated (edit discarded without commit).".green.bold + "\n"
            : "\n🟢 Google Play listing changes committed: \(changes.count) field(s) (\(languages.count) language(s)\(appLevel.isEmpty ? "" : " + app details")).".green.bold + "\n")
    }

    /// The patch body for one language: only changed fields are set.
    static func listingChanges(language: String, changes: [StoreMetadataChange]) -> GooglePlayListing {
        let values = Dictionary(changes.filter { $0.locale == language }.map { ($0.field.key, $0.local) }, uniquingKeysWith: { first, _ in first })
        return GooglePlayListing(
            language: language,
            title: values[GoogleMetadataField.title.rawValue],
            shortDescription: values[GoogleMetadataField.shortDescription.rawValue],
            fullDescription: values[GoogleMetadataField.fullDescription.rawValue],
            video: values[GoogleMetadataField.video.rawValue]
        )
    }
}
