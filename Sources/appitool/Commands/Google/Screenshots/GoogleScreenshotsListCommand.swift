import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleScreenshotsListCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists store screenshots and graphics registered in Google Play Console."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .shortAndLong, help: "Filter by BCP-47 language code (e.g. en-US, tr-TR). Omit to list all listing languages.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Filter by image type (e.g. phone, tablet7, tablet10, feature-graphic, icon). Omit to list all types.")
    var type: String?

    func execute() async throws {
        let parsedType = try type
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { try GooglePlayImageType.parse($0) }

        let targetTypes = parsedType.map { [$0] } ?? GooglePlayImageType.allCases
        let packageName = try app.requirePackageName()
        let service = try app.requireService()

        let explicitLocale = locale?.trimmingCharacters(in: .whitespacesAndNewlines)

        Log("🔍 Fetching Google Play store visuals for '\(packageName)'...".dim)

        let entries: [(language: String, imageType: GooglePlayImageType, images: [GooglePlayImage])] = try await service.withEditSession(
            packageName: packageName,
            commit: false
        ) { editId in
            let languages: [String]
            if let explicitLocale, !explicitLocale.isEmpty {
                languages = [explicitLocale]
            } else {
                languages = try await service.listListingLanguages(packageName: packageName, editId: editId)
            }

            var collected: [(String, GooglePlayImageType, [GooglePlayImage])] = []
            for lang in languages {
                for imageType in targetTypes {
                    let images = try await service.listImages(
                        packageName: packageName,
                        editId: editId,
                        language: lang,
                        imageType: imageType
                    )
                    if !images.isEmpty {
                        collected.append((lang, imageType, images))
                    }
                }
            }
            return collected
        }

        if entries.isEmpty {
            Log("🟡 No Google Play store visuals found matching your filter criteria.".yellow)
            return
        }

        let totalImages = entries.reduce(0) { $0 + $1.images.count }
        Log("\nFound \(totalImages) image(s) across \(entries.count) slot(s):".bold)
        for entry in entries {
            Log("  [\(entry.language)] ".cyan.bold + "\(entry.imageType.rawValue)".bold + " (\(entry.images.count))".dim)
            for image in entry.images {
                let shaPrefix = image.sha256.map { String($0.prefix(12)) + "..." } ?? "-"
                let urlSuffix = image.url.map { ", URL: \($0)" } ?? ""
                Log("    • ID: ".cyan + "\(image.id)".bold + " [SHA256: \(shaPrefix)\(urlSuffix)]".dim)
            }
        }
        Log("")
    }
}
