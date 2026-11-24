import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleAssetsDeleteCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Removes screenshots, product page header, and search results images (Asset Library placements) from App Store Connect."
    )

    var destructiveCommandDescription: String { "apple assets delete" }

    @OptionGroup
    var app: AppleAssetAppOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .long, help: "Specific placement ID to remove (as shown by `apple assets list`).")
    var id: String?

    @Option(name: .long, help: "App Store localization locale (e.g. en-US, tr) when deleting with --all.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Type to delete with --all: a screenshot type (e.g. iphone-67, iphone-duo), header, or search. Omit for all types.")
    var type: String?

    @Flag(name: .long, help: "Remove all assets matching --locale (and optional --type). Images stay in the Asset Library.")
    var all: Bool = false

    @Flag(name: .long, help: "Preview assets to be removed without removing them.")
    var dryRun: Bool = false

    func execute() async throws {
        let trimmedId = CLIValues.trimmedNonEmpty(id)
        let trimmedLocale = CLIValues.trimmedNonEmpty(locale)
        let slot = try CLIValues.trimmedNonEmpty(type).map(AppleAssetSlot.parse)

        if all && trimmedId != nil {
            throw CommandError("Cannot combine --all with --id.")
        }
        if trimmedId == nil && (!all || trimmedLocale == nil) {
            throw CommandError("Missing deletion target. Provide --id <placement-id> or --all with --locale <locale>.")
        }

        let service = try app.requireService()

        if let targetId = trimmedId {
            if dryRun {
                Log("🟡 [Dry Run] Would remove placement '\(targetId)'.".yellow)
                return
            }
            Log("🗑️  Removing placement '\(targetId)'...".dim)
            if try await service.deletePlacement(id: targetId) {
                Log("🟢 Removed placement '\(targetId)' from App Store Connect.".green.bold)
            } else {
                Log("🟡 Placement '\(targetId)' was not removed (it may not exist).".yellow)
            }
            return
        }

        guard let targetLocale = trimmedLocale else { return }
        let includeScreenshots = slot == nil || slot?.screenshotSlot != nil
        let creativeTypes: [CreativeAssetType] = slot.map { $0.creativeType.map { [$0] } ?? [] } ?? CreativeAssetType.allCases
        let parsedPlatform = try app.parsedPlatform()
        let resolvedAppId = try await app.resolveAppId(service: service)

        // Screenshots require an editable version; header/search placements can also change on a live version.
        Log("🔍 Resolving App Store version for App ID '\(resolvedAppId)' (\(parsedPlatform.rawValue))...".dim)
        let version = try await service.resolveAppStoreVersion(
            appId: resolvedAppId,
            platform: parsedPlatform,
            versionString: app.appVersion,
            requireEditable: includeScreenshots
        )
        let localization = try await service.resolveVersionLocalization(versionId: version.id, locale: targetLocale)

        var targets: [(label: String, placement: AssetLibraryPlacementInfo)] = []
        if includeScreenshots {
            let grouped = try await ScreenshotPlacementOperations.grouped(
                service: service,
                localizationId: localization.id,
                slot: slot?.screenshotSlot
            )
            for (screenshotSlot, placements) in grouped.slots {
                targets += placements.map { (screenshotSlot.key, $0) }
            }
        }
        let creative = try await CreativeAssetOperations.placements(service: service, localizations: [localization], types: creativeTypes)
        targets += creative.map { ($0.type.rawValue, $0.placement) }

        if targets.isEmpty {
            Log("🟡 No assets found matching locale '\(targetLocale)'\(slot.map { " and type '\($0.key)'" } ?? "").".yellow)
            return
        }

        if dryRun {
            Log("\n🟡 [Dry Run] Would remove \(targets.count) placement(s):".yellow.bold)
            for item in targets {
                Log("  • [\(item.label)] \(item.placement.image?.fileName ?? item.placement.imageId ?? "-") [Placement: \(item.placement.id)]".dim)
            }
            Log("")
            return
        }

        var removed = 0
        for item in targets {
            try await service.deletePlacement(id: item.placement.id)
            removed += 1
            Log("  ✔ Removed [\(item.label)] \(item.placement.image?.fileName ?? "-") [Placement: \(item.placement.id)]".green)
        }
        Log("🟢 Removed \(removed) placement(s).".green.bold)
    }
}
