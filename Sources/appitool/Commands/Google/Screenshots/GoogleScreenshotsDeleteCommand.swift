import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleScreenshotsDeleteCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Deletes store screenshots or graphics from Google Play Console."
    )

    var destructiveCommandDescription: String { "google screenshots delete" }

    @OptionGroup
    var app: GooglePlayAppOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .long, help: "BCP-47 language code (e.g. en-US, tr-TR).")
    var locale: String

    @Option(name: .shortAndLong, help: "Image type (e.g. phone, tablet7, tablet10, tv, wear, icon, feature-graphic, tv-banner).")
    var type: String

    @Option(name: .long, help: "Specific image ID to delete.")
    var id: String?

    @Flag(name: .long, help: "Delete all images of the specified type for the language.")
    var all: Bool = false

    @Flag(name: .long, help: "Commit changes without automatically sending them for review.")
    var changesNotSentForReview: Bool = false

    @Flag(name: .long, help: "Preview images to be deleted without deleting them.")
    var dryRun: Bool = false

    func execute() async throws {
        let cleanLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLocale.isEmpty else {
            throw CommandError("Locale cannot be empty. Provide --locale <bcp47-code>.")
        }

        let trimmedId = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasId = trimmedId?.isEmpty == false
        if all && hasId {
            throw CommandError("Cannot combine --all with --id.")
        }
        guard all || hasId else {
            throw CommandError("Missing deletion target. Provide --id <image-id> or --all.")
        }

        let imageType = try GooglePlayImageType.parse(type)
        let packageName = try app.requirePackageName()
        let service = try app.requireService()

        if dryRun {
            Log("🔍 [Dry Run] Inspecting Google Play images for '\(packageName)' (\(cleanLocale) | \(imageType.rawValue))...".dim)
            let matches: [GooglePlayImage] = try await service.withEditSession(
                packageName: packageName,
                commit: false
            ) { editId in
                let existing = try await service.listImages(
                    packageName: packageName,
                    editId: editId,
                    language: cleanLocale,
                    imageType: imageType
                )
                if let targetId = trimmedId, !targetId.isEmpty {
                    return existing.filter { $0.id == targetId }
                }
                return existing
            }

            if matches.isEmpty {
                Log("🟡 [Dry Run] No matching image(s) found for '\(cleanLocale)' (\(imageType.rawValue)).".yellow)
            } else {
                Log("\n🟡 [Dry Run] Would delete \(matches.count) image(s):".yellow.bold)
                for img in matches {
                    Log("  • ID: \(img.id)".dim)
                }
                Log("")
            }
            return
        }

        if let targetId = trimmedId, !targetId.isEmpty {
            Log("🗑️  Deleting Google Play image '\(targetId)' (\(packageName) | \(cleanLocale) | \(imageType.rawValue))...".dim)
            try await service.withEditSession(
                packageName: packageName,
                commit: true,
                changesNotSentForReview: changesNotSentForReview ? true : nil
            ) { editId in
                try await service.deleteImage(
                    packageName: packageName,
                    editId: editId,
                    language: cleanLocale,
                    imageType: imageType,
                    imageId: targetId
                )
            }
            Log("🟢 Successfully deleted Google Play image '\(targetId)'.".green.bold)
        } else {
            Log("🗑️  Deleting all Google Play images for \(cleanLocale) | \(imageType.rawValue) (\(packageName))...".dim)
            let deleted = try await service.withEditSession(
                packageName: packageName,
                commit: true,
                changesNotSentForReview: changesNotSentForReview ? true : nil
            ) { editId in
                try await service.deleteAllImages(
                    packageName: packageName,
                    editId: editId,
                    language: cleanLocale,
                    imageType: imageType
                )
            }
            Log("🟢 Successfully deleted \(deleted.count) image(s) from Google Play Console.".green.bold)
        }
    }
}
