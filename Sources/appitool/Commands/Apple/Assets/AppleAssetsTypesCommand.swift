import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleAssetsTypesCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "types",
        abstract: "Lists supported asset types (screenshot device slots, header, search) and CLI aliases."
    )

    func execute() async throws {
        Log("\nSupported types for " + "apple assets <list|upload|download|delete> --type <type>".cyan.bold + ":\n")

        var categories: [String] = []
        for slot in AppleScreenshotSlot.all where !categories.contains(slot.category) {
            categories.append(slot.category)
        }
        for category in categories {
            Log("[\(category)]".bold)
            for slot in AppleScreenshotSlot.all where slot.category == category {
                let aliasesPart = slot.aliases.isEmpty ? "" : " (aliases: \(slot.aliases.joined(separator: ", ")))"
                Log("  • ".cyan + "\(slot.key)".bold + " [\(slot.placementGroup)]".dim)
                Log("    \(slot.displayName)\(aliasesPart)".dim)
            }
        }

        Log("[Product page header & search results (iOS 27+, one image per localization)]".bold)
        for type in CreativeAssetType.allCases {
            Log("  • ".cyan + "\(type.rawValue)".bold + " [\(type.placementType.rawValue)]".dim)
            Log("    \(type.displayName)".dim)
        }
        Log("")
    }
}
