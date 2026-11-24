import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleAssetsSpecsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "specs",
        abstract: "Shows Apple's current image specs for screenshots, product page header, and search results (live from App Store Connect)."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Show only one kind (screenshot, header, search) or one screenshot slot (e.g. iphone-67, iphone-duo). Omit to show all.")
    var type: String?

    private enum Kind: String, CaseIterable {
        case screenshot, header, search

        var placementTypes: [Components.Schemas.AppAssetLibraryPlacementType] {
            switch self {
            case .screenshot: return [.APP_SCREENSHOT, .IMESSAGE_APP_SCREENSHOT]
            case .header: return [.PRODUCT_PAGE_HEADER_ASSET]
            case .search: return [.APP_STORE_SEARCH_RESULTS_ASSET]
            }
        }
    }

    func execute() async throws {
        let kinds: [Kind]
        var slotFilter: AppleScreenshotSlot?
        if let raw = CLIValues.trimmedNonEmpty(type) {
            if let kind = Kind(rawValue: raw.lowercased()) ?? (raw.lowercased() == "screenshots" ? .screenshot : nil) {
                kinds = [kind]
            } else if let slot = try? AppleScreenshotSlot.parse(raw) {
                slotFilter = slot
                kinds = [.screenshot]
            } else {
                throw ValidationError("Unsupported specs type '\(raw)'. Valid values: screenshot, header, search, or a screenshot type (see `apple assets types`).")
            }
        } else {
            kinds = Kind.allCases
        }

        let service = try appleCredentials.requireService()
        let reference = try await service.fetchAssetLibraryReference(placementTypes: kinds.flatMap(\.placementTypes))
        let specsById = Dictionary(reference.specs.compactMap { spec in spec.specId.map { ($0, spec) } }, uniquingKeysWith: { first, _ in first })

        for kind in kinds {
            switch kind {
            case .header, .search:
                let specs = reference.specs.filter { !Set($0.placementTypes).isDisjoint(with: kind.placementTypes) }
                Log("\n📐 \(kind == .header ? "Product page header" : "Search results") (-t \(kind.rawValue))".bold)
                if specs.isEmpty {
                    Log("  (no specs returned)".dim)
                }
                for spec in specs {
                    logSpec(spec, indent: "  ")
                }
            case .screenshot:
                Log("\n📐 Screenshots by display class (placement group IDs are what the Asset Library uses per device slot)".bold)
                let groupsById = Dictionary(reference.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let mappings = reference.groupSpecs.filter { mapping in
                    kind.placementTypes.contains(mapping.placementType)
                        && (slotFilter.map { mapping.groupId == $0.placementGroup } ?? true)
                }
                if mappings.isEmpty {
                    Log("  (no screenshot placement groups returned)".dim)
                }
                for mapping in mappings {
                    let group = groupsById[mapping.groupId]
                    let maxCount = reference.limits
                        .first { $0.placementType == mapping.placementType && $0.groupIds.contains(mapping.groupId) && $0.feature == "APP_STORE_VERSIONS" }?
                        .maxCount
                    let slotKey = AppleScreenshotSlot.forPlacement(type: mapping.placementType, group: mapping.groupId)?.key
                    Log("\n  • \(slotKey.map { "-t \($0)" } ?? "(not supported by appitool)") ".cyan.bold
                        + "\(group?.displayClass ?? "-") [\(group?.platform ?? "-")]".dim
                        + (mapping.placementType == .IMESSAGE_APP_SCREENSHOT ? " iMessage".dim : ""))
                    Log("    Placement group: ".dim + mapping.groupId)
                    if let dims = group?.screenDimensions, !dims.isEmpty {
                        Log("    Screen:          ".dim + dims.joined(separator: ", "))
                    }
                    if let maxCount {
                        Log("    Max per version: ".dim + "\(maxCount)")
                    }
                    for specId in mapping.specIds {
                        if let spec = specsById[specId] {
                            Log("    Accepts:         ".dim + summary(spec))
                        } else {
                            Log("    Accepts:         ".dim + specId)
                        }
                    }
                }
            }
        }
        Log("")
    }

    private func size(_ spec: AssetLibraryImageSpec) -> String {
        func value(_ v: Int?) -> String { v.map(String.init) ?? "?" }
        if spec.minWidth == spec.maxWidth && spec.minHeight == spec.maxHeight {
            return "\(value(spec.minWidth)) x \(value(spec.minHeight))"
        }
        return "\(value(spec.minWidth)) x \(value(spec.minHeight)) to \(value(spec.maxWidth)) x \(value(spec.maxHeight))"
    }

    private func summary(_ spec: AssetLibraryImageSpec) -> String {
        var parts = [size(spec)]
        if let ratio = spec.aspectRatio { parts.append(ratio) }
        if !spec.fileExtensions.isEmpty { parts.append(spec.fileExtensions.joined(separator: "/")) }
        return parts.joined(separator: ", ")
    }

    private func logSpec(_ spec: AssetLibraryImageSpec, indent: String) {
        Log("\(indent)• \(spec.shortName ?? spec.specId ?? "spec")".cyan + (spec.universalAsset == true ? " (universal)".dim : ""))
        Log("\(indent)  Size:     ".dim + size(spec) + (spec.aspectRatio.map { " (\($0))" } ?? ""))
        Log("\(indent)  Formats:  ".dim + (spec.fileExtensions.isEmpty ? "-" : spec.fileExtensions.joined(separator: ", ")))
        if let maxFileSize = spec.maxFileSize {
            Log("\(indent)  Max size: ".dim + ByteCountFormatter.string(fromByteCount: Int64(maxFileSize), countStyle: .file))
        }
        if let alpha = spec.alphaAllowed {
            Log("\(indent)  Alpha:    ".dim + (alpha ? "allowed" : "not allowed"))
        }
    }
}
