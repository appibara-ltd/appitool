import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleAssetsDownloadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Downloads screenshots, product page header, and search results images into <locale>/<type>/ folders."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "Filter by App Store locale (e.g. en-US, tr). Omit to download all locales.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Filter by type (screenshot display type such as iphone-67, or header, search). Omit to download all.")
    var type: String?

    @Option(name: .shortAndLong, help: "Output directory (defaults to $STORE_ASSETS_PATH/apple/, or ~/.appitool/assets/<project>/apple/ when unset).")
    var output: String?

    @Flag(name: .long, help: "Preview screenshots that would be downloaded without writing files.")
    var dryRun: Bool = false

    func execute() async throws {
        let parsedPlatform = try app.parsedPlatform()
        let slot = try CLIValues.trimmedNonEmpty(type).map(AppleAssetSlot.parse)
        let screenshotSlot = slot?.screenshotSlot
        let includeScreenshots = slot == nil || screenshotSlot != nil
        let creativeTypes: [CreativeAssetType] = slot.map { $0.creativeType.map { [$0] } ?? [] } ?? CreativeAssetType.allCases
        let service = try app.requireService()
        let candidate = await app.resolveBundleIdOrAppId()
        let resolvedAppId = try await app.resolveAppId(service: service)
        let projectLabel = candidate.bundleId ?? resolvedAppId

        let baseDir: URL
        if let explicitOutput = CLIValues.trimmedNonEmpty(output) {
            baseDir = ScreenshotFileResolver.expandPath(explicitOutput)
        } else {
            baseDir = AppitoolPaths.assetsDirectory(project: projectLabel, store: "apple")
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
        if let targetLocale = CLIValues.trimmedNonEmpty(locale) {
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
            let setId: String
        }

        var items: [DownloadItem] = []
        for loc in localizations where includeScreenshots {
            let locName = loc.attributes?.locale ?? loc.id
            let grouped = try await ScreenshotPlacementOperations.grouped(service: service, localizationId: loc.id, slot: screenshotSlot)
            for (group, count) in grouped.unknownGroups {
                Log("  🟡 Skipped \(count) screenshot(s) in \(locName)/\(group): device slot not supported by appitool yet.".yellow)
            }
            for (slotItem, placements) in grouped.slots {
                for (offset, placement) in placements.enumerated() {
                    let image = placement.image
                    let resolved = AppStoreService.resolveScreenshotDownloadURL(
                        templateUrl: image?.templateUrl,
                        width: image?.width,
                        height: image?.height,
                        fileName: image?.fileName
                    )
                    items.append(DownloadItem(
                        locale: locName,
                        typeKey: slotItem.key,
                        index: offset + 1,
                        totalCount: placements.count,
                        originalName: image?.fileName,
                        screenshotId: placement.id,
                        downloadURL: resolved?.url,
                        preferredExtension: resolved?.fileExtension ?? "png",
                        setId: slotItem.slotKey(versionId: version.id, locale: locName)
                    ))
                }
            }
        }

        let creative = try await CreativeAssetOperations.placements(service: service, localizations: localizations, types: creativeTypes)

        if items.isEmpty && creative.isEmpty {
            Log("🟡 No assets found matching your filter criteria on version '\(versionLabel)'.".yellow)
            return
        }

        if dryRun {
            Log("\n🟡 [Dry Run] Would download \(items.count) screenshot(s) and \(creative.count) header/search image(s) to \(baseDir.path):".yellow.bold)
            for item in creative {
                let image = item.placement.image
                let url = AppStoreService.resolveScreenshotDownloadURL(
                    templateUrl: image?.templateUrl, width: image?.width, height: image?.height, fileName: image?.fileName
                )
                Log("  • \(item.locale)/\(item.type.rawValue)/\(image?.fileName ?? item.type.rawValue)".dim
                    + (url.map { " <- \($0.url.absoluteString)" } ?? " (unavailable — image URL missing)").dim)
            }
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

        Log("📥 Downloading \(items.count) screenshot(s) and \(creative.count) header/search image(s) to \(baseDir.path)...".dim)
        let fm = FileManager.default
        var downloadedCount = 0
        var skippedCount = 0

        // Manifest entries per set folder, in display order (used by `upload --sync`).
        struct SetManifestDraft {
            let locale: String
            let typeKey: String
            let setId: String
            let directory: URL
            var entries: [ScreenshotManifest.Entry] = []
        }
        var drafts: [String: SetManifestDraft] = [:]
        var draftOrder: [String] = []
        for item in items where drafts[item.setId] == nil {
            drafts[item.setId] = SetManifestDraft(
                locale: item.locale,
                typeKey: item.typeKey,
                setId: item.setId,
                directory: baseDir.appendingPathComponent(item.locale).appendingPathComponent(item.typeKey)
            )
            draftOrder.append(item.setId)
        }

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
            drafts[item.setId]?.entries.append(.init(
                file: filename,
                remoteId: item.screenshotId,
                sha256: try ScreenshotManifest.sha256(of: destination)
            ))
        }

        let allRemoteIds = Set(items.map(\.screenshotId))
        for setId in draftOrder {
            guard let draft = drafts[setId] else { continue }
            try fm.createDirectory(at: draft.directory, withIntermediateDirectories: true)
            try writeManifest(
                draft: (draft.locale, draft.typeKey, draft.setId, draft.directory, draft.entries),
                version: version,
                remoteIds: allRemoteIds
            )
        }

        // Header and search results images: one image per <locale>/<header|search>/ folder.
        var creativeCount = 0
        for item in creative {
            let label = "\(item.locale)/\(item.type.rawValue)"
            guard let image = item.placement.image,
                  let resolved = AppStoreService.resolveScreenshotDownloadURL(
                      templateUrl: image.templateUrl, width: image.width, height: image.height, fileName: image.fileName
                  ) else {
                skippedCount += 1
                Log("  🟡 Skipped \(label) (placement \(item.placement.id)): image URL unavailable (still processing?).".yellow)
                continue
            }
            let (data, contentType) = try await service.downloadScreenshotData(from: resolved.url)
            let ext = ScreenshotFileResolver.detectImageExtension(contentType: contentType, data: data, fallback: resolved.fileExtension)
            let stem = ((image.fileName ?? "") as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "_")
            let filename = "\(stem.isEmpty ? item.type.rawValue : stem).\(ext)"
            let targetDir = baseDir.appendingPathComponent(item.locale).appendingPathComponent(item.type.rawValue)
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let destination = targetDir.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
            creativeCount += 1
            Log("  ✔ \(label)/\(filename) ".green + "(\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))".dim)

            let manifestEntry = ScreenshotManifest.Entry(file: filename, remoteId: image.id, sha256: try ScreenshotManifest.sha256(of: destination))
            try ScreenshotManifest.cleanUpAfterDownload(
                directory: targetDir,
                newEntries: [manifestEntry],
                label: label,
                storeName: "App Store Connect",
                isStillRemote: { $0.remoteId == image.id }
            )
            try CreativeAssetOperations.writeManifest(
                directory: targetDir, locale: item.locale, type: item.type, file: destination, imageId: image.id, version: version
            )
        }

        Log("\n🟢 Downloaded \(downloadedCount) screenshot(s) and \(creativeCount) header/search image(s) to \(baseDir.path)".green.bold + (skippedCount > 0 ? " (\(skippedCount) skipped)".yellow : "") + "\n")
    }

    /// Writes the set folder's `.appitool-manifest.json`, removes images a previous download wrote that are no longer
    /// on App Store Connect, and warns about other local images (`upload --sync` would upload them as new).
    private func writeManifest(
        draft: (locale: String, typeKey: String, setId: String, directory: URL, entries: [ScreenshotManifest.Entry]),
        version: Components.Schemas.AppStoreVersion,
        remoteIds: Set<String>
    ) throws {
        try ScreenshotManifest.cleanUpAfterDownload(
            directory: draft.directory,
            newEntries: draft.entries,
            label: "\(draft.locale)/\(draft.typeKey)",
            storeName: "App Store Connect",
            isStillRemote: { remoteIds.contains($0.remoteId) }
        )

        try ScreenshotManifest(
            store: "apple",
            locale: draft.locale,
            type: draft.typeKey,
            versionId: version.id,
            versionString: version.attributes?.versionString,
            remoteSetId: draft.setId,
            entries: draft.entries
        ).write(to: draft.directory)
    }
}
