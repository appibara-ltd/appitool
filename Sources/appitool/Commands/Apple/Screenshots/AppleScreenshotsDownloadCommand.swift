import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleScreenshotsDownloadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Downloads App Store Connect screenshots locally organized by locale and display type."
    )

    @OptionGroup
    var app: AppleScreenshotAppOptions

    @Option(name: .long, help: "Filter by App Store locale (e.g. en-US, tr). Omit to download all locales.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Filter by screenshot display type (e.g. iphone-67, ipad-pro-129). Omit to download all sets.")
    var type: String?

    @Option(name: .shortAndLong, help: "Output directory (defaults to ~/.appitool/screenshots/<project>/apple/).")
    var output: String?

    @Flag(name: .long, help: "Preview screenshots that would be downloaded without writing files.")
    var dryRun: Bool = false

    func execute() async throws {
        let parsedPlatform = try app.parsedPlatform()
        let parsedType = try AppleCommandHelpers.trimmedNonEmpty(type).map {
            try AppleTypeMapper.parseScreenshotDisplayType($0)
        }
        let service = try app.requireService()
        let candidate = await app.resolveBundleIdOrAppId()
        let resolvedAppId = try await app.resolveAppId(service: service)
        let projectLabel = candidate.bundleId ?? resolvedAppId

        let baseDir: URL
        if let explicitOutput = AppleCommandHelpers.trimmedNonEmpty(output) {
            baseDir = ScreenshotFileResolver.expandPath(explicitOutput)
        } else {
            baseDir = AppitoolPaths.screenshotsDirectory(project: projectLabel, store: "apple")
        }

        Log("🔍 Resolving App Store version for App ID '\(resolvedAppId)' (\(parsedPlatform.rawValue))...".dim)
        let version = try await service.resolveAppStoreVersion(
            appId: resolvedAppId,
            platform: parsedPlatform,
            versionString: app.appVersion,
            requireEditable: false
        )

        let versionLabel = version.attributes?.versionString ?? version.id
        let stateLabel = version.attributes?.appVersionState?.rawValue
            ?? version.attributes?.appStoreState?.rawValue
            ?? "UNKNOWN"
        Log("   Using version \(versionLabel) [ID: \(version.id), State: \(stateLabel)]".dim)

        let localizations: [Components.Schemas.AppStoreVersionLocalization]
        if let targetLocale = AppleCommandHelpers.trimmedNonEmpty(locale) {
            let loc = try await service.resolveVersionLocalization(versionId: version.id, locale: targetLocale)
            localizations = [loc]
        } else {
            localizations = try await service.fetchAppStoreVersionLocalizations(versionId: version.id)
        }

        if localizations.isEmpty {
            Log("🟡 No App Store version localizations found for version '\(versionLabel)'.".yellow)
            return
        }

        struct DownloadItem {
            let locale: String
            let typeKey: String
            let index: Int
            let totalCount: Int
            let originalName: String?
            let screenshotId: String
            let downloadURL: URL?
            let preferredExtension: String
        }

        var items: [DownloadItem] = []
        for loc in localizations {
            let locName = loc.attributes?.locale ?? loc.id
            let sets = try await service.fetchScreenshotSets(localizationId: loc.id, displayType: parsedType)
            for set in sets {
                let typeKey = set.attributes?.screenshotDisplayType.map(AppleTypeMapper.cliKey(for:)) ?? "unknown"
                let screenshots = try await service.fetchScreenshots(screenshotSetId: set.id)
                let total = screenshots.count
                for (offset, ss) in screenshots.enumerated() {
                    let resolved = AppStoreService.resolveScreenshotDownloadURL(
                        templateUrl: ss.attributes?.imageAsset?.templateUrl,
                        width: ss.attributes?.imageAsset?.width,
                        height: ss.attributes?.imageAsset?.height,
                        fileName: ss.attributes?.fileName
                    )
                    items.append(DownloadItem(
                        locale: locName,
                        typeKey: typeKey,
                        index: offset + 1,
                        totalCount: total,
                        originalName: ss.attributes?.fileName,
                        screenshotId: ss.id,
                        downloadURL: resolved?.url,
                        preferredExtension: resolved?.fileExtension ?? "png"
                    ))
                }
            }
        }

        if items.isEmpty {
            Log("🟡 No screenshots found matching your filter criteria on version '\(versionLabel)'.".yellow)
            return
        }

        if dryRun {
            Log("\n🟡 [Dry Run] Would download \(items.count) screenshot(s) to \(baseDir.path):".yellow.bold)
            for item in items {
                let filename = ScreenshotFileResolver.orderPrefixedFilename(
                    index: item.index,
                    totalCount: item.totalCount,
                    originalName: item.originalName,
                    fallbackStem: item.screenshotId,
                    fileExtension: item.preferredExtension
                )
                if let url = item.downloadURL {
                    Log("  • \(item.locale)/\(item.typeKey)/\(filename)".dim + " <- \(url.absoluteString)".dim)
                } else {
                    Log("  • \(item.locale)/\(item.typeKey)/\(filename) (unavailable — imageAsset URL missing)".yellow)
                }
            }
            Log("")
            return
        }

        Log("📥 Downloading \(items.count) screenshot(s) to \(baseDir.path)...".dim)
        let fm = FileManager.default
        var downloadedCount = 0
        var skippedCount = 0

        for item in items {
            guard let downloadURL = item.downloadURL else {
                skippedCount += 1
                Log("  🟡 Skipped screenshot '\(item.screenshotId)' (\(item.locale)/\(item.typeKey)): imageAsset URL unavailable.".yellow)
                continue
            }

            let (data, contentType) = try await service.downloadScreenshotData(from: downloadURL)
            let ext = ScreenshotFileResolver.detectImageExtension(
                contentType: contentType,
                data: data,
                fallback: item.preferredExtension
            )
            let filename = ScreenshotFileResolver.orderPrefixedFilename(
                index: item.index,
                totalCount: item.totalCount,
                originalName: item.originalName,
                fallbackStem: item.screenshotId,
                fileExtension: ext
            )

            let targetDir = baseDir
                .appendingPathComponent(item.locale)
                .appendingPathComponent(item.typeKey)
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let destination = targetDir.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
            downloadedCount += 1
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            Log("  ✔ \(item.locale)/\(item.typeKey)/\(filename) ".green + "(\(sizeStr))".dim)
        }

        Log("\n🟢 Downloaded \(downloadedCount) screenshot(s) to \(baseDir.path)".green.bold + (skippedCount > 0 ? " (\(skippedCount) skipped)".yellow : "") + "\n")
    }
}
