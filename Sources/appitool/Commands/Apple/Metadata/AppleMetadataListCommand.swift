import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleMetadataListCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Shows the App Store listing text per localization of the resolved version and app info."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "Filter by App Store locale (e.g. en-US, tr). Omit to list all localizations.")
    var locale: String?

    func execute() async throws {
        Log("🔍 Resolving App Store version and app info...".dim)
        let context = try await AppleMetadataContext.resolve(app: app)
        let locales = context.remoteLocales.filter {
            guard let filter = CLIValues.trimmedNonEmpty(locale) else { return true }
            return $0.caseInsensitiveCompare(filter) == .orderedSame
        }
        if locales.isEmpty {
            Log("🟡 No localizations found\(locale.map { " for '\($0)'" } ?? "").".yellow)
            return
        }

        if CLIValues.trimmedNonEmpty(locale) == nil {
            let remote = try await context.fetchStoreRemote().values
            Log("\n  [app]".cyan.bold + " (app-level)".dim)
            for field in AppleStoreField.allCases.map(\.field) {
                MetadataListFormatter.log(field: field, value: remote[field.key] ?? nil)
            }
        }
        for code in locales {
            let remote = context.remoteValues(code)
            Log("\n  [\(code)]".cyan.bold)
            for field in AppleMetadataField.allCases.map(\.field) {
                MetadataListFormatter.log(field: field, value: remote[field.key] ?? nil)
            }
        }
        Log("")
    }
}

/// Prints one metadata field line for `metadata list` (secrets masked, long texts shortened).
enum MetadataListFormatter {
    static func log(field: StoreMetadataField, value raw: String?) {
        let value = StoreMetadataFiles.normalize(raw)
        let limit = field.maxLength.map { "/\($0)" } ?? ""
        let shown: String
        if value.isEmpty {
            shown = "(empty)".dim
        } else if field.isSecret {
            shown = "(set, hidden)".dim
        } else if field.isShort {
            shown = value
        } else {
            let firstLine = value.split(separator: "\n").first.map(String.init) ?? value
            shown = (firstLine.count > 70 ? String(firstLine.prefix(70)) + "…" : firstLine) + (value.contains("\n") || firstLine.count > 70 ? " …".dim : "")
        }
        Log("    • \(field.displayName) ".cyan + (field.isSecret ? "" : "(\(value.count)\(limit))".dim) + ": \(shown)")
    }
}
