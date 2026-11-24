import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

/// Header and search results ("creative assets" in App Store Connect) placement types handled by `apple assets`.
enum CreativeAssetType: String, CaseIterable, Sendable, Equatable {
    case header
    case search

    var placementType: Components.Schemas.AppAssetLibraryPlacementType {
        switch self {
        case .header: return .PRODUCT_PAGE_HEADER_ASSET
        case .search: return .APP_STORE_SEARCH_RESULTS_ASSET
        }
    }

    var displayName: String {
        switch self {
        case .header: return "Product page header"
        case .search: return "Search results"
        }
    }

    init?(placementType: Components.Schemas.AppAssetLibraryPlacementType?) {
        guard let match = Self.allCases.first(where: { $0.placementType == placementType }) else { return nil }
        self = match
    }

    /// Parses `header` / `search` (plus long forms and API names); `nil` when `raw` is not a creative asset type.
    static func parseIfCreative(_ raw: String) -> CreativeAssetType? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "header", "product-page-header", "product_page_header_asset":
            return .header
        case "search", "search-results", "app_store_search_results_asset":
            return .search
        default:
            return nil
        }
    }
}

/// A screenshot device slot: an Asset Library placement type plus placement group (e.g. `APP_SCREENSHOT` +
/// `IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` for `iphone-67`).
///
/// The display-type → placement-group mapping was verified against `appAssetLibraryRefData` screen dimensions
/// (`apple assets specs -t screenshot`). `iphone-duo` slots exist only in the Asset Library (no screenshot display type).
struct AppleScreenshotSlot: Equatable, Hashable, Sendable {
    let key: String
    let aliases: [String]
    let displayName: String
    let category: String
    let placementType: Components.Schemas.AppAssetLibraryPlacementType
    let placementGroup: String

    /// Placement groups per screenshot display type (iMessage types use the same group with an `IMESSAGE_` prefix).
    private static let groupByDisplayType: [String: String] = [
        "APP_IPHONE_67": "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE",
        "APP_IPHONE_65": "IPHONE_FACE_ID_LARGE_PROFILE",
        "APP_IPHONE_61": "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE",
        "APP_IPHONE_58": "IPHONE_FACE_ID_MEDIUM_PROFILE",
        "APP_IPHONE_55": "IPHONE_HOME_BUTTON_LARGE_PROFILE",
        "APP_IPHONE_47": "IPHONE_HOME_BUTTON_MEDIUM_PROFILE",
        "APP_IPHONE_40": "IPHONE_HOME_BUTTON_40_PROFILE",
        "APP_IPHONE_35": "IPHONE_HOME_BUTTON_35_PROFILE",
        "APP_IPAD_PRO_3GEN_129": "IPAD_13_PROFILE",
        "APP_IPAD_PRO_3GEN_11": "IPAD_11_PROFILE",
        "APP_IPAD_PRO_129": "IPAD_129_PROFILE",
        "APP_IPAD_105": "IPAD_105_PROFILE",
        "APP_IPAD_97": "IPAD_97_PROFILE",
        "APP_DESKTOP": "MAC_PROFILE",
        "APP_WATCH_ULTRA": "WATCH_ULTRA_PROFILE",
        "APP_WATCH_SERIES_10": "WATCH_SERIES_10_PROFILE",
        "APP_WATCH_SERIES_7": "WATCH_SERIES_7_PROFILE",
        "APP_WATCH_SERIES_4": "WATCH_SERIES_4_PROFILE",
        "APP_WATCH_SERIES_3": "WATCH_SERIES_3_PROFILE",
        "APP_APPLE_TV": "TV_PROFILE",
        "APP_APPLE_VISION_PRO": "VISION_PRO_PROFILE",
    ]

    /// Every supported screenshot slot, in `assets types` order.
    static let all: [AppleScreenshotSlot] = {
        var slots: [AppleScreenshotSlot] = []
        for descriptor in AppleTypeMapper.supportedScreenshotDisplayTypes {
            let isIMessage = descriptor.enumName.hasPrefix("IMESSAGE_")
            let baseName = isIMessage ? String(descriptor.enumName.dropFirst("IMESSAGE_".count)) : descriptor.enumName
            guard let group = groupByDisplayType[baseName] else { continue }
            slots.append(AppleScreenshotSlot(
                key: descriptor.key,
                aliases: descriptor.aliases + [descriptor.enumName.lowercased().replacingOccurrences(of: "_", with: "-")],
                displayName: descriptor.description,
                category: descriptor.category,
                placementType: isIMessage ? .IMESSAGE_APP_SCREENSHOT : .APP_SCREENSHOT,
                placementGroup: isIMessage ? "IMESSAGE_\(group)" : group
            ))
        }
        slots.append(AppleScreenshotSlot(
            key: "iphone-duo", aliases: ["duo"], displayName: "iPhone Duo (folding) Display",
            category: "iPhone", placementType: .APP_SCREENSHOT, placementGroup: "IPHONE_DUO_PROFILE"
        ))
        slots.append(AppleScreenshotSlot(
            key: "imessage-iphone-duo", aliases: ["imessage-duo"], displayName: "iMessage iPhone Duo (folding) Display",
            category: "iMessage", placementType: .IMESSAGE_APP_SCREENSHOT, placementGroup: "IMESSAGE_IPHONE_DUO_PROFILE"
        ))
        return slots
    }()

    /// Parses a slot key, alias, or screenshot display type name (`iphone-67`, `APP_IPHONE_67`, `iphone-duo`, …).
    static func parse(_ raw: String) throws -> AppleScreenshotSlot {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if let match = all.first(where: { $0.key == lowered || $0.aliases.contains(lowered) }) {
            return match
        }
        let displayType = try AppleTypeMapper.parseScreenshotDisplayType(raw)
        guard let match = all.first(where: { $0.key == AppleTypeMapper.cliKey(for: displayType) }) else {
            throw ValidationError("Screenshot type '\(raw)' has no Asset Library placement group.")
        }
        return match
    }

    /// The slot for a placement's type and group (`nil` for groups appitool does not know yet).
    static func forPlacement(type: Components.Schemas.AppAssetLibraryPlacementType?, group: String?) -> AppleScreenshotSlot? {
        all.first { $0.placementType == type && $0.placementGroup == group }
    }

    /// Manifest identity (`remoteSetId`) of this slot on one localization of one version.
    func slotKey(versionId: String, locale: String) -> String {
        "\(versionId)/\(locale)/\(placementGroup)"
    }
}

/// One `apple assets` slot type: a screenshot device slot, or a header / search results creative asset.
enum AppleAssetSlot: Equatable, Sendable {
    case screenshot(AppleScreenshotSlot)
    case creative(CreativeAssetType)

    /// Parses `-t, --type` and `<type>/` folder names (`iphone-67`, `APP_IPHONE_67`, `iphone-duo`, `header`, `search`, …).
    static func parse(_ raw: String) throws -> AppleAssetSlot {
        if let creative = CreativeAssetType.parseIfCreative(raw) {
            return .creative(creative)
        }
        return .screenshot(try AppleScreenshotSlot.parse(raw))
    }

    /// Folder / CLI key.
    var key: String {
        switch self {
        case .screenshot(let slot): return slot.key
        case .creative(let type): return type.rawValue
        }
    }

    var screenshotSlot: AppleScreenshotSlot? {
        if case .screenshot(let slot) = self { return slot }
        return nil
    }

    var creativeType: CreativeAssetType? {
        if case .creative(let type) = self { return type }
        return nil
    }
}

/// Screenshot placement helpers shared by the `apple assets` commands.
enum ScreenshotPlacementOperations {
    static let placementTypes: [Components.Schemas.AppAssetLibraryPlacementType] = [.APP_SCREENSHOT, .IMESSAGE_APP_SCREENSHOT]

    /// Screenshot placements of one localization grouped by slot, each group in display order. Placements in groups
    /// appitool does not know are returned under `unknownGroups` (by group name).
    static func grouped(
        service: AppStoreService,
        localizationId: String,
        slot: AppleScreenshotSlot? = nil
    ) async throws -> (slots: [(slot: AppleScreenshotSlot, placements: [AssetLibraryPlacementInfo])], unknownGroups: [String: Int]) {
        let placements = try await service.fetchPlacements(
            localizationId: localizationId,
            placementTypes: slot.map { [$0.placementType] } ?? placementTypes,
            placementGroup: slot?.placementGroup
        )
        var order: [AppleScreenshotSlot] = []
        var bySlot: [AppleScreenshotSlot: [AssetLibraryPlacementInfo]] = [:]
        var unknown: [String: Int] = [:]
        for placement in placements {
            guard let match = AppleScreenshotSlot.forPlacement(type: placement.placementType, group: placement.placementGroup) else {
                unknown[placement.placementGroup ?? "-", default: 0] += 1
                continue
            }
            if bySlot[match] == nil { order.append(match) }
            bySlot[match, default: []].append(placement)
        }
        return (order.map { ($0, bySlot[$0] ?? []) }, unknown)
    }

    /// Uploads `file` into the Asset Library as a screenshot and places it at the end of `slot` on `localizationId`.
    static func uploadAndPlace(
        file: URL,
        slot: AppleScreenshotSlot,
        localizationId: String,
        assetLibraryId: String,
        waitProcessing: Bool,
        service: AppStoreService
    ) async throws -> AssetLibraryPlacementInfo {
        let image = try await service.uploadAssetLibraryImage(
            assetLibraryId: assetLibraryId,
            fileUrl: file,
            category: .APP_SCREENSHOTS_AND_PREVIEWS,
            waitForProcessing: waitProcessing
        )
        return try await service.createPlacement(
            imageId: image.id,
            localizationId: localizationId,
            placementType: slot.placementType,
            placementGroup: slot.placementGroup
        )
    }
}

/// Header / search results operations shared by the `apple assets` commands (App Store Connect Asset Library).
enum CreativeAssetOperations {
    /// Placements of `types` on each localization, in localization order.
    static func placements(
        service: AppStoreService,
        localizations: [Components.Schemas.AppStoreVersionLocalization],
        types: [CreativeAssetType]
    ) async throws -> [(locale: String, localization: Components.Schemas.AppStoreVersionLocalization, type: CreativeAssetType, placement: AssetLibraryPlacementInfo)] {
        guard !types.isEmpty else { return [] }
        var result: [(String, Components.Schemas.AppStoreVersionLocalization, CreativeAssetType, AssetLibraryPlacementInfo)] = []
        for localization in localizations {
            let locale = localization.attributes?.locale ?? localization.id
            let placements = try await service.fetchPlacements(
                localizationId: localization.id,
                placementTypes: types.map(\.placementType)
            )
            for placement in placements {
                guard let type = CreativeAssetType(placementType: placement.placementType), types.contains(type) else { continue }
                result.append((locale, localization, type, placement))
            }
        }
        return result
    }

    /// Replaces the slot's current placement with `image`: create first, delete the old one after. If App Store
    /// Connect rejects a second placement, the old one is deleted first and the create is retried.
    @discardableResult
    static func place(
        image: AssetLibraryImageInfo,
        type: CreativeAssetType,
        localization: Components.Schemas.AppStoreVersionLocalization,
        service: AppStoreService
    ) async throws -> AssetLibraryPlacementInfo {
        let locale = localization.attributes?.locale ?? localization.id
        let label = "[\(locale) | \(type.rawValue)]"
        let existing = try await service.fetchPlacements(localizationId: localization.id, placementTypes: [type.placementType])
            .filter { $0.imageId != image.id }

        let placement: AssetLibraryPlacementInfo
        do {
            placement = try await service.createPlacement(imageId: image.id, localizationId: localization.id, placementType: type.placementType)
        } catch {
            guard !existing.isEmpty else { throw error }
            Log("  🟡 \(label) could not add a second placement (\(error.localizedDescription)); replacing the existing one first.".yellow)
            for old in existing {
                try await service.deletePlacement(id: old.id)
            }
            let retried = try await service.createPlacement(imageId: image.id, localizationId: localization.id, placementType: type.placementType)
            Log("  ✔ \(label) placed \(image.fileName ?? image.id) [Placement: \(retried.id), State: \(retried.state ?? "-")]".green)
            return retried
        }
        for old in existing {
            try await service.deletePlacement(id: old.id)
        }
        Log("  ✔ \(label) placed \(image.fileName ?? image.id) [Placement: \(placement.id), State: \(placement.state ?? "-")]".green)
        return placement
    }

    /// Manifest identity of a header / search slot (`remoteSetId`).
    static func slotKey(locale: String, type: CreativeAssetType) -> String {
        "\(locale)/\(type.placementType.rawValue)"
    }

    /// Writes the one-entry manifest of a header / search folder (`remoteId` = Asset Library image ID).
    static func writeManifest(
        directory: URL,
        locale: String,
        type: CreativeAssetType,
        file: URL,
        imageId: String,
        version: Components.Schemas.AppStoreVersion
    ) throws {
        try ScreenshotManifest(
            store: "apple",
            locale: locale,
            type: type.rawValue,
            versionId: version.id,
            versionString: version.attributes?.versionString,
            remoteSetId: slotKey(locale: locale, type: type),
            entries: [.init(file: file.lastPathComponent, remoteId: imageId, sha256: try ScreenshotManifest.sha256(of: file))]
        ).write(to: directory)
    }
}
