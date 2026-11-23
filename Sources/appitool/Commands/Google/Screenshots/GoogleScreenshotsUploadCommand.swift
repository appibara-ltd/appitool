import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleScreenshotsUploadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Uploads store screenshots or graphics to Google Play Console from files, directories, or ~/.appitool/screenshots/<package>/google/."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .long, help: "BCP-47 language code (e.g. en-US, tr-TR). Required for flat files; optional filter for directory trees.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Image type (e.g. phone, tablet7, tablet10, tv, wear, icon, feature-graphic, tv-banner). Defaults to phone for flat files; optional filter for directory trees.")
    var type: String?

    @Flag(name: .long, help: "Delete existing images in each target slot before uploading.")
    var replace: Bool = false

    @Flag(name: .long, help: "Validate the edit session without committing changes.")
    var validateOnly: Bool = false

    @Flag(name: .long, help: "Commit changes without automatically sending them for review.")
    var changesNotSentForReview: Bool = false

    @Flag(name: .long, help: "Validate files and preview upload without contacting Google Play.")
    var dryRun: Bool = false

    @Argument(help: "Optional image file(s), directory, or <locale>/<type>/ tree (defaults to ~/.appitool/screenshots/<package>/google/).")
    var paths: [String] = []

    func execute() async throws {
        let packageName = try app.requirePackageName()

        let (sourceRoot, batches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: paths,
            defaultDirectory: { AppitoolPaths.screenshotsDirectory(project: packageName, store: "google") },
            localeFilter: locale,
            typeFilter: type,
            defaultFlatType: .phoneScreenshots,
            storeDisplayName: "Google Play",
            downloadHintCommand: "appitool google screenshots download",
            parseType: GooglePlayImageType.parse
        )

        let totalFiles = batches.reduce(0) { $0 + $1.files.count }

        if dryRun {
            Log("\n🟡 [Dry Run] Google Play Visual Upload Preview".yellow.bold)
            Log("  • Package:       ".cyan + packageName)
            if let sourceRoot {
                Log("  • Source Root:   ".cyan + sourceRoot.path)
            }
            Log("  • Replace:       ".cyan + "\(replace)")
            Log("  • Validate Only: ".cyan + "\(validateOnly)")
            Log("  • Plan:          ".cyan + "\(totalFiles) image(s) across \(batches.count) slot(s)")
            for batch in batches {
                Log("  • [\(batch.locale) | \(batch.type.cliKey) (\(batch.type.rawValue))] (\(batch.files.count) file(s))".bold)
                for file in batch.files {
                    Log("    - \(file.lastPathComponent) (\(file.path))".dim)
                }
            }
            Log("")
            return
        }

        let service = try app.requireService()
        let actionVerb = validateOnly ? "Validating" : "Uploading"
        Log("📤 \(actionVerb) \(totalFiles) image(s) across \(batches.count) slot(s) in Google Play Console (\(packageName))...".dim)

        struct UploadedItem {
            let locale: String
            let imageType: GooglePlayImageType
            let url: URL
            let image: GooglePlayImage
        }

        let (deletedCount, uploaded): (Int, [UploadedItem]) = try await service.withEditSession(
            packageName: packageName,
            commit: true,
            validateOnly: validateOnly,
            changesNotSentForReview: changesNotSentForReview ? true : nil
        ) { editId in
            var removed = 0
            var results: [UploadedItem] = []

            for batch in batches {
                if replace {
                    let deleted = try await service.deleteAllImages(
                        packageName: packageName,
                        editId: editId,
                        language: batch.locale,
                        imageType: batch.type
                    )
                    removed += deleted.count
                }

                for file in batch.files {
                    let img = try await service.uploadImage(
                        packageName: packageName,
                        editId: editId,
                        language: batch.locale,
                        imageType: batch.type,
                        fileUrl: file
                    )
                    results.append(UploadedItem(locale: batch.locale, imageType: batch.type, url: file, image: img))
                }
            }
            return (removed, results)
        }

        if validateOnly {
            Log("\n🟢 Google Play image upload validated successfully (edit discarded without commit).".green.bold)
        } else {
            Log("\n🟢 Google Play image upload committed successfully!".green.bold)
        }
        if let sourceRoot {
            Log("  • Source Root:  ".cyan + sourceRoot.path)
        }
        Log("  • Slots Updated: ".cyan + "\(batches.count)")
        if replace {
            Log("  • Replaced existing image(s): ".cyan + "\(deletedCount)")
        }
        Log("  • Uploaded:     ".cyan + "\(uploaded.count) image(s)")
        for item in uploaded {
            Log("  • [\(item.locale) | \(item.imageType.cliKey)] \(item.url.lastPathComponent): ".cyan + "ID \(item.image.id)".bold)
        }
        Log("")
    }
}
