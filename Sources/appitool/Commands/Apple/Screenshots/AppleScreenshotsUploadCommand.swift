import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleScreenshotsUploadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Uploads app screenshots to App Store Connect from files, directories, or ~/.appitool/screenshots/<project>/apple/."
    )

    @OptionGroup
    var app: AppleScreenshotAppOptions

    @Option(name: .long, help: "App Store localization locale (e.g. en-US, tr). Required for flat files; optional filter for directory trees.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Screenshot display type (e.g. iphone-67, ipad-pro-129, APP_IPHONE_67). Required for flat files; optional filter for directory trees.")
    var type: String?

    @Flag(name: .long, help: "Delete existing screenshots in each target set before uploading.")
    var replace: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Wait for App Store Connect to finish processing each uploaded screenshot (--wait-processing / --no-wait-processing).")
    var waitProcessing: Bool = true

    @Flag(name: .long, help: "Validate files and preview upload without contacting App Store Connect.")
    var dryRun: Bool = false

    @Argument(help: "Optional image file(s), directory, or <locale>/<type>/ tree (defaults to ~/.appitool/screenshots/<project>/apple/).")
    var paths: [String] = []

    func execute() async throws {
        let parsedPlatform = try app.parsedPlatform()
        let candidate = await app.resolveBundleIdOrAppId()

        let (sourceRoot, batches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: paths,
            defaultDirectory: {
                guard let projectLabel = candidate.bundleId ?? candidate.appId else {
                    throw ValidationError(
                        "Missing App Store Connect App ID or bundle identifier to locate ~/.appitool/screenshots/<project>/apple/. Provide -b, --bundle-id, --app-id, set APPLE_BUNDLE_ID in .env, run inside an Xcode project, or pass explicit path(s)."
                    )
                }
                return AppitoolPaths.screenshotsDirectory(project: projectLabel, store: "apple")
            },
            localeFilter: locale,
            typeFilter: type,
            defaultFlatType: nil,
            storeDisplayName: "App Store Connect",
            downloadHintCommand: "appitool apple screenshots download",
            parseType: AppleTypeMapper.parseScreenshotDisplayType
        )

        let totalFiles = batches.reduce(0) { $0 + $1.files.count }

        if dryRun {
            let targetLabel = candidate.appId ?? candidate.bundleId ?? "(auto-detect)"
            Log("\n🟡 [Dry Run] App Store Connect Screenshot Upload Preview".yellow.bold)
            Log("  • Target App:   ".cyan + targetLabel)
            Log("  • Platform:     ".cyan + parsedPlatform.rawValue)
            if let v = AppleCommandHelpers.trimmedNonEmpty(app.appVersion) {
                Log("  • Version:      ".cyan + v)
            }
            if let sourceRoot {
                Log("  • Source Root:  ".cyan + sourceRoot.path)
            }
            Log("  • Replace:      ".cyan + "\(replace)")
            Log("  • Wait Process: ".cyan + "\(waitProcessing)")
            Log("  • Plan:         ".cyan + "\(totalFiles) screenshot(s) across \(batches.count) set(s)")
            for batch in batches {
                Log("  • [\(batch.locale) | \(batch.type.rawValue)] (\(batch.files.count) file(s))".bold)
                for file in batch.files {
                    Log("    - \(file.lastPathComponent) (\(file.path))".dim)
                }
            }
            Log("")
            return
        }

        let service = try app.requireService()
        let resolvedAppId = try await app.resolveAppId(service: service)

        Log("🔍 Resolving editable App Store version for App ID '\(resolvedAppId)' (\(parsedPlatform.rawValue))...".dim)
        let version = try await service.resolveAppStoreVersion(
            appId: resolvedAppId,
            platform: parsedPlatform,
            versionString: app.appVersion,
            requireEditable: true
        )
        let versionLabel = version.attributes?.versionString ?? version.id

        // Pre-validate every batch's localization before mutating any remote screenshot set.
        let allLocalizations = try await service.fetchAppStoreVersionLocalizations(versionId: version.id)
        var resolvedBatches: [(localization: Components.Schemas.AppStoreVersionLocalization, batch: ScreenshotUploadBatch<Components.Schemas.ScreenshotDisplayType>)] = []
        for batch in batches {
            guard let matchedLoc = allLocalizations.first(where: {
                $0.attributes?.locale?.caseInsensitiveCompare(batch.locale) == .orderedSame
            }) else {
                let available = allLocalizations.compactMap { $0.attributes?.locale }.sorted().joined(separator: ", ")
                throw AppStoreServiceError.notFound(
                    "Localization '\(batch.locale)' was not found on version '\(versionLabel)' (available locales: \(available.isEmpty ? "none" : available))."
                )
            }
            resolvedBatches.append((matchedLoc, batch))
        }

        var totalDeletedCount = 0
        struct UploadedItem {
            let locale: String
            let displayType: Components.Schemas.ScreenshotDisplayType
            let file: URL
            let id: String
            let state: String
            let dims: String
        }
        var uploadedResults: [UploadedItem] = []

        for (localization, batch) in resolvedBatches {
            let resolvedLocale = localization.attributes?.locale ?? batch.locale
            let set = try await service.findOrCreateScreenshotSet(
                localizationId: localization.id,
                displayType: batch.type
            )

            if replace {
                let existing = try await service.fetchScreenshots(screenshotSetId: set.id)
                if !existing.isEmpty {
                    Log("🗑️  Deleting \(existing.count) existing screenshot(s) in [\(resolvedLocale) | \(batch.type.rawValue)] (set '\(set.id)')...".dim)
                    for item in existing {
                        if try await service.deleteScreenshot(id: item.id) {
                            totalDeletedCount += 1
                        }
                    }
                }
            }

            Log("📤 Uploading \(batch.files.count) screenshot(s) to \(versionLabel) [\(resolvedLocale) | \(batch.type.rawValue)]...".dim)
            for file in batch.files {
                let screenshot = try await service.uploadScreenshot(
                    screenshotSetId: set.id,
                    fileUrl: file,
                    waitForProcessing: waitProcessing
                )
                let state = screenshot.attributes?.assetDeliveryState?.state?.rawValue ?? "UNKNOWN"
                let dims: String = {
                    if let w = screenshot.attributes?.imageAsset?.width, let h = screenshot.attributes?.imageAsset?.height {
                        return "\(w)x\(h)"
                    }
                    return "-"
                }()
                uploadedResults.append(UploadedItem(
                    locale: resolvedLocale,
                    displayType: batch.type,
                    file: file,
                    id: screenshot.id,
                    state: state,
                    dims: dims
                ))
                Log("  ✔ [\(resolvedLocale) | \(AppleTypeMapper.cliKey(for: batch.type))] \(file.lastPathComponent): ID \(screenshot.id) [State: \(state)]".green)
            }
        }

        Log("\n🟢 Screenshot upload completed!".green.bold)
        Log("  • Version:      ".cyan + "\(versionLabel) [ID: \(version.id)]")
        if let sourceRoot {
            Log("  • Source Root:  ".cyan + sourceRoot.path)
        }
        Log("  • Sets Updated: ".cyan + "\(resolvedBatches.count)")
        if replace {
            Log("  • Replaced:     ".cyan + "\(totalDeletedCount) existing screenshot(s)")
        }
        Log("  • Uploaded:     ".cyan + "\(uploadedResults.count) screenshot(s)")
        for item in uploadedResults {
            Log("    - [\(item.locale) | \(item.displayType.rawValue)] \(item.file.lastPathComponent) [ID: \(item.id), Dims: \(item.dims), State: \(item.state)]".dim)
        }
        Log("")
    }
}
