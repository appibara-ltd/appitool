import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleAssetsUploadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Uploads screenshots, product page header, and search results images from files, directories, or ~/.appitool/assets/<project>/apple/."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "App Store localization locale (e.g. en-US, tr). Required for flat files; optional filter for directory trees.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Type: screenshot display type (e.g. iphone-67, APP_IPHONE_67), header, or search. Required for flat files; optional filter for directory trees.")
    var type: String?

    @Flag(name: .long, help: "Delete existing screenshots in each target set before uploading (writes a sync manifest for directory trees). Header/search slots are always replaced.")
    var replace: Bool = false

    @Flag(name: .long, help: "Mirror <locale>/<type>/ folders using their .appitool-manifest.json: upload new and edited files, delete screenshots of removed files, and apply file-name order.")
    var sync: Bool = false

    @Flag(name: .long, help: "Place one header or search image file on every localization of the version (requires a file and -t header|search).")
    var allLocales: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Wait for App Store Connect to finish processing each uploaded image (--wait-processing / --no-wait-processing).")
    var waitProcessing: Bool = true

    @Flag(name: .long, help: "Validate files and preview upload without contacting App Store Connect.")
    var dryRun: Bool = false

    @Argument(help: "Optional image file(s), directory, or <locale>/<type>/ tree (defaults to $STORE_ASSETS_PATH/apple/, or ~/.appitool/assets/<project>/apple/ when unset).")
    var paths: [String] = []

    typealias DisplayType = AppleScreenshotSlot
    typealias Localization = Components.Schemas.AppStoreVersionLocalization

    /// A header / search results slot: one file for one localization (`nil` locale = every localization).
    struct CreativeSlot {
        let locale: String?
        let type: CreativeAssetType
        let file: URL
    }

    func validate() throws {
        if sync && replace {
            throw ValidationError("Cannot combine --sync with --replace.")
        }
        if allLocales {
            if sync {
                throw ValidationError("Cannot combine --all-locales with --sync.")
            }
            if CLIValues.trimmedNonEmpty(locale) != nil {
                throw ValidationError("Cannot combine --all-locales with --locale.")
            }
            guard let rawType = CLIValues.trimmedNonEmpty(type), CreativeAssetType.parseIfCreative(rawType) != nil, !paths.isEmpty else {
                throw ValidationError("--all-locales requires an image file and -t header or -t search.")
            }
        }
    }

    func execute() async throws {
        let parsedPlatform = try app.parsedPlatform()
        let candidate = await app.resolveBundleIdOrAppId()

        // 1. Resolve local files.
        var sourceRoot: URL?
        var screenshotBatches: [ScreenshotUploadBatch<DisplayType>] = []
        var creativeSlots: [CreativeSlot] = []

        if allLocales {
            let files = try ScreenshotFileResolver.resolveImageFiles(from: paths)
            guard files.count == 1, let creativeType = CreativeAssetType.parseIfCreative(type ?? "") else {
                throw CommandError("--all-locales takes exactly one image file (got \(files.count)).")
            }
            creativeSlots = [CreativeSlot(locale: nil, type: creativeType, file: files[0])]
        } else {
            let (root, batches) = try ScreenshotFileResolver.resolveUploadBatches(
                paths: paths,
                defaultDirectory: {
                    if let customRoot = AppitoolPaths.customStoreAssetsRoot() {
                        return AppitoolPaths.assetsDirectory(project: "", store: "apple", customRoot: customRoot)
                    }
                    guard let projectLabel = candidate.bundleId ?? candidate.appId else {
                        throw ValidationError(
                            "Missing App Store Connect App ID or bundle identifier to locate ~/.appitool/assets/<project>/apple/. Provide -b, --bundle-id, --app-id, set APPLE_BUNDLE_ID or STORE_ASSETS_PATH in .env, run inside an Xcode project, or pass explicit path(s)."
                        )
                    }
                    return AppitoolPaths.assetsDirectory(project: projectLabel, store: "apple")
                },
                localeFilter: locale,
                typeFilter: type,
                defaultFlatType: nil,
                storeDisplayName: "App Store Connect",
                downloadHintCommand: "appitool apple assets download",
                parseType: AppleAssetSlot.parse
            )
            sourceRoot = root
            for batch in batches {
                switch batch.type {
                case .screenshot(let slot):
                    guard batch.files.count <= AppleScreenshotSyncTask.maxScreenshotsPerSet else {
                        throw CommandError(
                            "[\(batch.locale) | \(slot.key)] has \(batch.files.count) images; App Store Connect allows at most \(AppleScreenshotSyncTask.maxScreenshotsPerSet) per slot."
                        )
                    }
                    screenshotBatches.append(.init(locale: batch.locale, type: slot, files: batch.files))
                case .creative(let creativeType):
                    guard batch.files.count == 1 else {
                        throw CommandError(
                            "[\(batch.locale) | \(creativeType.rawValue)] has \(batch.files.count) images; header and search slots take exactly one: \(batch.files.map(\.lastPathComponent).joined(separator: ", "))."
                        )
                    }
                    creativeSlots.append(.init(locale: batch.locale, type: creativeType, file: batch.files[0]))
                }
            }
        }

        if sync && sourceRoot == nil {
            throw CommandError(
                "--sync requires a <locale>/<type>/ directory tree (the default ~/.appitool/assets/<project>/apple/ or a tree path), not explicit files or a flat folder."
            )
        }

        if dryRun && !sync {
            logDryRun(candidate: candidate, platform: parsedPlatform, sourceRoot: sourceRoot, screenshots: screenshotBatches, creative: creativeSlots)
            return
        }

        // 2. Resolve version and localizations (screenshots need an editable version).
        let service = try app.requireService()
        let resolvedAppId = try await app.resolveAppId(service: service)
        Log("🔍 Resolving App Store version for App ID '\(resolvedAppId)' (\(parsedPlatform.rawValue))...".dim)
        let version = try await service.resolveAppStoreVersion(
            appId: resolvedAppId,
            platform: parsedPlatform,
            versionString: app.appVersion,
            requireEditable: !screenshotBatches.isEmpty
        )
        let versionLabel = version.attributes?.versionString ?? version.id

        // Pre-validate every localization before mutating anything.
        let allLocalizations = try await service.fetchAppStoreVersionLocalizations(versionId: version.id)
        func localization(for locale: String) throws -> Localization {
            guard let match = allLocalizations.first(where: { $0.attributes?.locale?.caseInsensitiveCompare(locale) == .orderedSame }) else {
                let available = allLocalizations.compactMap { $0.attributes?.locale }.sorted().joined(separator: ", ")
                throw AppStoreServiceError.notFound(
                    "Localization '\(locale)' was not found on version '\(versionLabel)' (available locales: \(available.isEmpty ? "none" : available))."
                )
            }
            return match
        }
        let resolvedBatches = try screenshotBatches.map { (localization: try localization(for: $0.locale), batch: $0) }
        let resolvedCreative = try creativeSlots.map { slot in
            (slot: slot, localizations: try slot.locale.map { [try localization(for: $0)] } ?? allLocalizations)
        }

        let assetLibraryId = try await service.fetchAssetLibraryId(appId: resolvedAppId)

        if sync {
            try await runSync(
                service: service,
                version: version,
                assetLibraryId: assetLibraryId,
                screenshots: resolvedBatches,
                creative: resolvedCreative.map { ($0.slot, $0.localizations[0]) }
            )
            return
        }

        // 3. Screenshots: check slot limits for every batch before changing anything.
        var existingBySlot: [Int: [AssetLibraryPlacementInfo]] = [:]
        for (index, item) in resolvedBatches.enumerated() {
            let existing = try await service.fetchPlacements(
                localizationId: item.localization.id,
                placementTypes: [item.batch.type.placementType],
                placementGroup: item.batch.type.placementGroup
            )
            existingBySlot[index] = existing
            let total = (replace ? 0 : existing.count) + item.batch.files.count
            if total > AppleScreenshotSyncTask.maxScreenshotsPerSet {
                throw CommandError(
                    "[\(item.batch.locale) | \(item.batch.type.key)] would contain \(total) screenshots (limit \(AppleScreenshotSyncTask.maxScreenshotsPerSet)).",
                    hint: "Use --replace to replace the existing \(existing.count), or --sync to mirror the folder."
                )
            }
        }

        var totalDeletedCount = 0
        var uploadedScreenshots: [(locale: String, slot: AppleScreenshotSlot, file: URL, id: String)] = []
        for (index, item) in resolvedBatches.enumerated() {
            let (localization, batch) = item
            let resolvedLocale = localization.attributes?.locale ?? batch.locale
            let label = "[\(resolvedLocale) | \(batch.type.key)]"

            if replace, let existing = existingBySlot[index], !existing.isEmpty {
                Log("🗑️  Removing \(existing.count) existing screenshot(s) in \(label)...".dim)
                for placement in existing {
                    try await service.deletePlacement(id: placement.id)
                    totalDeletedCount += 1
                }
            }

            Log("📤 Uploading \(batch.files.count) screenshot(s) to \(versionLabel) \(label)...".dim)
            var manifestEntries: [ScreenshotManifest.Entry] = []
            for file in batch.files {
                let placement = try await ScreenshotPlacementOperations.uploadAndPlace(
                    file: file,
                    slot: batch.type,
                    localizationId: localization.id,
                    assetLibraryId: assetLibraryId,
                    waitProcessing: waitProcessing,
                    service: service
                )
                uploadedScreenshots.append((resolvedLocale, batch.type, file, placement.id))
                Log("  ✔ \(label) \(file.lastPathComponent): Placement \(placement.id) [State: \(placement.state ?? "-")]".green)
                if replace && sourceRoot != nil {
                    manifestEntries.append(.init(file: file.lastPathComponent, remoteId: placement.id, sha256: try ScreenshotManifest.sha256(of: file)))
                }
            }

            // After --replace the slot mirrors the folder exactly, so record a manifest for later `--sync` runs.
            if replace, sourceRoot != nil, let directory = batch.files.first?.deletingLastPathComponent() {
                try ScreenshotManifest(
                    store: "apple",
                    locale: resolvedLocale,
                    type: batch.type.key,
                    versionId: version.id,
                    versionString: version.attributes?.versionString,
                    remoteSetId: batch.type.slotKey(versionId: version.id, locale: resolvedLocale),
                    entries: manifestEntries
                ).write(to: directory)
            }
        }

        // 4. Header and search results (always replace the slot's current image).
        var placedCount = 0
        var uploadedImages: [String: AssetLibraryImageInfo] = [:]
        if !resolvedCreative.isEmpty {
            for (slot, localizations) in resolvedCreative {
                let image = try await uploadOnce(slot.file, assetLibraryId: assetLibraryId, service: service, cache: &uploadedImages)
                for localization in localizations {
                    try await CreativeAssetOperations.place(image: image, type: slot.type, localization: localization, service: service)
                    placedCount += 1
                }
                // A tree folder now mirrors its slot; record it for `--sync`.
                if sourceRoot != nil, let code = slot.locale {
                    try CreativeAssetOperations.writeManifest(
                        directory: slot.file.deletingLastPathComponent(),
                        locale: code,
                        type: slot.type,
                        file: slot.file,
                        imageId: image.id,
                        version: version
                    )
                }
            }
        }

        Log("\n🟢 Asset upload completed!".green.bold)
        Log("  • Version:      ".cyan + "\(versionLabel) [ID: \(version.id)]")
        if let sourceRoot {
            Log("  • Source Root:  ".cyan + sourceRoot.path)
        }
        if !resolvedBatches.isEmpty {
            Log("  • Sets Updated: ".cyan + "\(resolvedBatches.count)")
            if replace {
                Log("  • Replaced:     ".cyan + "\(totalDeletedCount) existing screenshot(s)")
            }
            Log("  • Uploaded:     ".cyan + "\(uploadedScreenshots.count) screenshot(s)")
            for item in uploadedScreenshots {
                Log("    - [\(item.locale) | \(item.slot.key)] \(item.file.lastPathComponent) [Placement: \(item.id)]".dim)
            }
        }
        if !resolvedCreative.isEmpty {
            Log("  • Header/Search: ".cyan + "\(uploadedImages.count) image(s) uploaded, \(placedCount) placement(s)")
        }
        Log("")
    }

    // MARK: - Sync

    private func runSync(
        service: AppStoreService,
        version: Components.Schemas.AppStoreVersion,
        assetLibraryId: String,
        screenshots: [(localization: Localization, batch: ScreenshotUploadBatch<DisplayType>)],
        creative: [(CreativeSlot, Localization)]
    ) async throws {
        // Plan header/search first (read-only) so a planning error aborts before any screenshot change.
        var creativePlan: [(slot: CreativeSlot, localization: Localization, upload: Bool, note: String)] = []
        var errors: [String] = []
        for (slot, localization) in creative {
            let code = localization.attributes?.locale ?? slot.locale ?? localization.id
            let label = "[\(code) | \(slot.type.rawValue)]"
            let directory = slot.file.deletingLastPathComponent()
            let placements = try await service.fetchPlacements(localizationId: localization.id, placementTypes: [slot.type.placementType])
            let manifest = try ScreenshotManifest.load(from: directory)
            let sha = try ScreenshotManifest.sha256(of: slot.file)
            guard let manifest else {
                if placements.isEmpty {
                    creativePlan.append((slot, localization, true, "new slot (no manifest yet)"))
                } else {
                    errors.append("\(label) has a placed image but the folder has no \(ScreenshotManifest.fileName). Run 'apple assets download' first, or upload without --sync to replace it.")
                }
                continue
            }
            guard manifest.remoteSetId == CreativeAssetOperations.slotKey(locale: code, type: slot.type) else {
                errors.append("\(label) \(ScreenshotManifest.fileName) belongs to slot '\(manifest.remoteSetId)'. Run 'apple assets download' again.")
                continue
            }
            let entry = manifest.entries.first
            let stillPlaced = entry.map { e in placements.contains { $0.imageId == e.remoteId } } ?? false
            if entry?.sha256 == sha && stillPlaced {
                creativePlan.append((slot, localization, false, "no changes"))
            } else {
                creativePlan.append((slot, localization, true, stillPlaced ? "replace (file changed)" : "place (current image differs)"))
            }
        }
        guard errors.isEmpty else {
            throw CommandError("Asset sync aborted before making changes:\n" + errors.map { "  • \($0)" }.joined(separator: "\n"))
        }

        if !creativePlan.isEmpty {
            Log("\n🔄 Header/search sync plan:".bold)
            for item in creativePlan {
                let code = item.localization.attributes?.locale ?? item.slot.locale ?? "-"
                Log("  [\(code) | \(item.slot.type.rawValue)] ".cyan + "\(item.slot.file.lastPathComponent): \(item.note)".dim)
            }
        }

        var summary = AppleScreenshotSyncTask.Summary()
        if !screenshots.isEmpty {
            summary = try await AppleScreenshotSyncTask(
                service: service,
                version: version,
                assetLibraryId: assetLibraryId,
                targets: screenshots.map { .init(localization: $0.localization, batch: $0.batch) },
                waitProcessing: waitProcessing,
                dryRun: dryRun
            ).run()
        } else if dryRun {
            Log("\n🟡 [Dry Run] No changes were made.".yellow.bold + "\n")
        }
        if dryRun { return }

        var placed = 0
        let pending = creativePlan.filter(\.upload)
        if !pending.isEmpty {
            var cache: [String: AssetLibraryImageInfo] = [:]
            for item in pending {
                let image = try await uploadOnce(item.slot.file, assetLibraryId: assetLibraryId, service: service, cache: &cache)
                try await CreativeAssetOperations.place(image: image, type: item.slot.type, localization: item.localization, service: service)
                placed += 1
                try CreativeAssetOperations.writeManifest(
                    directory: item.slot.file.deletingLastPathComponent(),
                    locale: item.localization.attributes?.locale ?? item.slot.locale ?? "",
                    type: item.slot.type,
                    file: item.slot.file,
                    imageId: image.id,
                    version: version
                )
            }
        }

        Log("\n🟢 Asset sync completed!".green.bold)
        Log("  • Version:        ".cyan + "\(version.attributes?.versionString ?? version.id) [ID: \(version.id)]")
        if !screenshots.isEmpty {
            Log("  • Sets Changed:   ".cyan + "\(summary.setsChanged) of \(screenshots.count)")
            Log("  • Uploaded:       ".cyan + "\(summary.uploaded)")
            Log("  • Deleted:        ".cyan + "\(summary.deleted)")
            Log("  • Reordered:      ".cyan + "\(summary.reordered) set(s)")
        }
        if !creativePlan.isEmpty {
            Log("  • Header/Search:  ".cyan + "\(placed) of \(creativePlan.count) slot(s) updated")
        }
        Log("")
    }

    // MARK: - Helpers

    private func uploadOnce(
        _ file: URL,
        assetLibraryId: String,
        service: AppStoreService,
        cache: inout [String: AssetLibraryImageInfo]
    ) async throws -> AssetLibraryImageInfo {
        if let cached = cache[file.path] { return cached }
        Log("📤 Uploading \(file.lastPathComponent) to the Asset Library...".dim)
        let image = try await service.uploadAssetLibraryImage(assetLibraryId: assetLibraryId, fileUrl: file, waitForProcessing: waitProcessing)
        cache[file.path] = image
        Log("  ✔ Image \(image.id) [State: \(image.state)]".green)
        return image
    }

    private func logDryRun(
        candidate: (appId: String?, bundleId: String?),
        platform: Components.Schemas.Platform,
        sourceRoot: URL?,
        screenshots: [ScreenshotUploadBatch<DisplayType>],
        creative: [CreativeSlot]
    ) {
        let totalFiles = screenshots.reduce(0) { $0 + $1.files.count }
        Log("\n🟡 [Dry Run] App Store Connect Asset Upload Preview".yellow.bold)
        Log("  • Target App:   ".cyan + (candidate.appId ?? candidate.bundleId ?? "(auto-detect)"))
        Log("  • Platform:     ".cyan + platform.rawValue)
        if let v = CLIValues.trimmedNonEmpty(app.appVersion) {
            Log("  • Version:      ".cyan + v)
        }
        if let sourceRoot {
            Log("  • Source Root:  ".cyan + sourceRoot.path)
        }
        Log("  • Replace:      ".cyan + "\(replace)")
        Log("  • Wait Process: ".cyan + "\(waitProcessing)")
        Log("  • Plan:         ".cyan + "\(totalFiles) screenshot(s) across \(screenshots.count) set(s), \(creative.count) header/search slot(s)")
        for batch in screenshots {
            Log("  • [\(batch.locale) | \(batch.type.key)] (\(batch.files.count) file(s))".bold)
            for file in batch.files {
                Log("    - \(file.lastPathComponent) (\(file.path))".dim)
            }
        }
        for slot in creative {
            Log("  • [\(slot.locale ?? "all locales") | \(slot.type.rawValue)] \(slot.file.lastPathComponent)".bold)
        }
        Log("")
    }
}
