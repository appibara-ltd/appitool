import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleScreenshotsDownloadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Downloads Google Play Console store screenshots and graphics locally."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .long, help: "Filter by BCP-47 language code (e.g. en-US, tr-TR). Omit to download all listing languages.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Filter by image type (e.g. phone, tablet7, tablet10, feature-graphic, icon). Omit to download all types.")
    var type: String?

    @Option(name: .shortAndLong, help: "Output directory (defaults to ~/.appitool/screenshots/<package-name>/google/).")
    var output: String?

    @Flag(name: .long, help: "Preview images that would be downloaded without writing files.")
    var dryRun: Bool = false

    func execute() async throws {
        let parsedType = try type
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { try GooglePlayImageType.parse($0) }

        let targetTypes = parsedType.map { [$0] } ?? GooglePlayImageType.allCases
        let packageName = try app.requirePackageName()
        let service = try app.requireService()
        let explicitLocale = locale?.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseDir: URL
        if let explicitOutput = output?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitOutput.isEmpty {
            baseDir = ScreenshotFileResolver.expandPath(explicitOutput)
        } else {
            baseDir = AppitoolPaths.screenshotsDirectory(project: packageName, store: "google")
        }

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

        if dryRun {
            Log("\n🟡 [Dry Run] Would download \(totalImages) image(s) to \(baseDir.path):".yellow.bold)
            for entry in entries {
                for (offset, image) in entry.images.enumerated() {
                    let filename = ScreenshotFileResolver.orderPrefixedFilename(
                        index: offset + 1,
                        totalCount: entry.images.count,
                        originalName: nil,
                        fileExtension: "png"
                    )
                    if let rawUrl = image.url,
                       let fullResUrl = GooglePlayService.fullResolutionImageURL(from: rawUrl) {
                        Log("  • \(entry.language)/\(entry.imageType.cliKey)/\(filename)".dim + " <- \(fullResUrl.absoluteString)".dim)
                    } else {
                        Log("  • \(entry.language)/\(entry.imageType.cliKey)/\(filename) (unavailable — image URL missing)".yellow)
                    }
                }
            }
            Log("")
            return
        }

        Log("📥 Downloading \(totalImages) image(s) to \(baseDir.path)...".dim)
        let fm = FileManager.default
        var downloadedCount = 0
        var skippedCount = 0

        for entry in entries {
            let targetDir = baseDir
                .appendingPathComponent(entry.language)
                .appendingPathComponent(entry.imageType.cliKey)
            var createdDir = false

            for (offset, image) in entry.images.enumerated() {
                guard let rawUrl = image.url,
                      let fullResUrl = GooglePlayService.fullResolutionImageURL(from: rawUrl) else {
                    skippedCount += 1
                    Log("  🟡 Skipped image '\(image.id)' (\(entry.language)/\(entry.imageType.cliKey)): download URL unavailable.".yellow)
                    continue
                }

                let (data, contentType) = try await service.downloadImageData(from: fullResUrl)
                let ext = ScreenshotFileResolver.detectImageExtension(
                    contentType: contentType,
                    data: data,
                    fallback: "png"
                )
                let filename = ScreenshotFileResolver.orderPrefixedFilename(
                    index: offset + 1,
                    totalCount: entry.images.count,
                    originalName: nil,
                    fileExtension: ext
                )

                if !createdDir {
                    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    createdDir = true
                }

                let destination = targetDir.appendingPathComponent(filename)
                try data.write(to: destination, options: .atomic)
                downloadedCount += 1
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                Log("  ✔ \(entry.language)/\(entry.imageType.cliKey)/\(filename) ".green + "(\(sizeStr))".dim)
            }
        }

        Log("\n🟢 Downloaded \(downloadedCount) image(s) to \(baseDir.path)".green.bold + (skippedCount > 0 ? " (\(skippedCount) skipped)".yellow : "") + "\n")
    }
}
