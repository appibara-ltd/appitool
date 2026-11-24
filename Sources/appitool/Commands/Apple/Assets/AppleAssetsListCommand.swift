import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleAssetsListCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists screenshots, product page header, and search results images on an App Store version."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "Filter by App Store locale (e.g. en-US, tr). Omit to list all locales.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Filter by type (screenshot display type such as iphone-67, or header, search). Omit to list all.")
    var type: String?

    @Flag(name: .long, help: "List every Asset Library placement (all placement types, with placement groups) instead of the regular view.")
    var assetLibrary: Bool = false

    func execute() async throws {
        let slot = try CLIValues.trimmedNonEmpty(type).map(AppleAssetSlot.parse)
        let parsedPlatform = try app.parsedPlatform()
        let service = try app.requireService()
        let resolvedAppId = try await app.resolveAppId(service: service)

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

        if assetLibrary {
            try await listAssetLibrary(service: service, localizations: localizations, slot: slot)
            return
        }

        var totalSets = 0
        var totalScreenshots = 0

        // Screenshots (Asset Library placements, grouped by device slot, in display order)
        if slot == nil || slot?.screenshotSlot != nil {
            for loc in localizations {
                let locName = loc.attributes?.locale ?? loc.id
                let grouped = try await ScreenshotPlacementOperations.grouped(
                    service: service,
                    localizationId: loc.id,
                    slot: slot?.screenshotSlot
                )
                for (screenshotSlot, placements) in grouped.slots {
                    totalSets += 1
                    totalScreenshots += placements.count
                    Log("\n  [\(locName)] ".cyan.bold + "\(screenshotSlot.key)".bold + " [\(screenshotSlot.placementGroup), Count: \(placements.count)]".dim)
                    for placement in placements {
                        let image = placement.image
                        let dims = image.flatMap { img in img.width.flatMap { w in img.height.map { "\(w)x\($0)" } } } ?? "-"
                        Log("    • ".cyan + "\(image?.fileName ?? "unnamed")".bold
                            + " [Placement: \(placement.id), Dims: \(dims), State: \(placement.state ?? "-"), Image State: \(image?.state ?? "-")]".dim)
                    }
                }
                for (group, count) in grouped.unknownGroups.sorted(by: { $0.key < $1.key }) {
                    Log("\n  [\(locName)] ".cyan.bold + "\(group)".bold + " [\(count) screenshot(s) in a device slot appitool does not support yet]".yellow)
                }
            }
        }

        // Header and search results (Asset Library placements)
        let creativeTypes: [CreativeAssetType] = slot.map { $0.creativeType.map { [$0] } ?? [] } ?? CreativeAssetType.allCases
        let creative = try await CreativeAssetOperations.placements(service: service, localizations: localizations, types: creativeTypes)
        for item in creative {
            let image = item.placement.image
            let dims = image.flatMap { img in img.width.flatMap { w in img.height.map { "\(w)x\($0)" } } } ?? "-"
            Log("\n  [\(item.locale)] ".cyan.bold + "\(item.type.rawValue)".bold + " (\(item.type.displayName))".dim)
            Log("    • ".cyan + "\(image?.fileName ?? "unnamed")".bold
                + " [Placement: \(item.placement.id), State: \(item.placement.state ?? "-"), Image: \(item.placement.imageId ?? "-"), Image State: \(image?.state ?? "-"), Dims: \(dims)]".dim)
        }

        if totalSets == 0 && creative.isEmpty {
            Log("🟡 No assets found matching your filter criteria on version '\(versionLabel)'.".yellow)
        } else {
            Log("\nTotal: \(totalScreenshots) screenshot(s) across \(totalSets) slot(s), \(creative.count) header/search image(s).".bold)
            Log("")
        }
    }

    /// Raw Asset Library view: every placement on each localization, including placement groups.
    private func listAssetLibrary(
        service: AppStoreService,
        localizations: [Components.Schemas.AppStoreVersionLocalization],
        slot: AppleAssetSlot?
    ) async throws {
        let typeFilter: [Components.Schemas.AppAssetLibraryPlacementType]
        switch slot {
        case .creative(let type): typeFilter = [type.placementType]
        case .screenshot(let screenshotSlot): typeFilter = [screenshotSlot.placementType]
        case .none: typeFilter = []
        }

        var total = 0
        for loc in localizations {
            let locName = loc.attributes?.locale ?? loc.id
            let placements = try await service.fetchPlacements(localizationId: loc.id, placementTypes: typeFilter)
            Log("\n  [\(locName)] ".cyan.bold + "\(placements.count) placement(s)".dim)
            for placement in placements {
                total += 1
                let image = placement.image
                let dims = image.flatMap { img in img.width.flatMap { w in img.height.map { "\(w)x\($0)" } } } ?? "-"
                Log("    • ".cyan + "\(placement.placementType?.rawValue ?? "-")".bold
                    + " [Group: \(placement.placementGroup ?? "-"), Placement: \(placement.id), State: \(placement.state ?? "-"), Image: \(image?.fileName ?? placement.imageId ?? "-"), Dims: \(dims)]".dim)
            }
        }
        Log("\nTotal: \(total) Asset Library placement(s).\n".bold)
    }
}
