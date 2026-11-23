import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleScreenshotsTypesCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "types",
        abstract: "Lists supported App Store Connect screenshot display types and CLI aliases."
    )

    func execute() async throws {
        Log("\nSupported display types for " + "apple screenshots <list|upload|delete> --type <type>".cyan.bold + ":\n")

        var currentCategory = ""
        for item in AppleTypeMapper.supportedScreenshotDisplayTypes {
            if item.category != currentCategory {
                currentCategory = item.category
                Log("[\(currentCategory)]".bold)
            }
            let aliasesPart = item.aliases.isEmpty ? "" : " (aliases: \(item.aliases.joined(separator: ", ")))"
            Log("  • ".cyan + "\(item.key)".bold + " [\(item.enumName)]".dim)
            Log("    \(item.description)\(aliasesPart)".dim)
        }
        Log("")
    }
}
