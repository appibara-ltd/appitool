import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct GoogleScreenshotsTypesCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "types",
        abstract: "Lists supported Google Play Console store image and screenshot types."
    )

    func execute() async throws {
        Log("\nSupported image types for " + "google screenshots <list|upload|delete> --type <type>".cyan.bold + ":\n")
        for imageType in GooglePlayImageType.allCases {
            let aliasStr = imageType.aliases.joined(separator: ", ")
            Log("  • ".cyan + "\(imageType.cliKey)".bold + " [API: \(imageType.rawValue)]".dim)
            Log("    Aliases: \(aliasStr) — \(imageType.description)".dim)
        }
        Log("")
    }
}
