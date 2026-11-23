import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleScreenshotsDeleteCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Deletes app screenshots from App Store Connect."
    )

    var destructiveCommandDescription: String { "apple screenshots delete" }

    @OptionGroup
    var app: AppleScreenshotAppOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .long, help: "Specific App Store screenshot resource ID to delete.")
    var id: String?

    @Option(name: .long, help: "App Store localization locale (e.g. en-US, tr) when deleting with --all.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Screenshot display type (e.g. iphone-67) when deleting with --all.")
    var type: String?

    @Flag(name: .long, help: "Delete all screenshots matching --locale (and optional --type).")
    var all: Bool = false

    @Flag(name: .long, help: "Preview screenshots to be deleted without deleting them.")
    var dryRun: Bool = false

    func execute() async throws {
        let trimmedId = CLIValues.trimmedNonEmpty(id)
        let trimmedLocale = CLIValues.trimmedNonEmpty(locale)
        let trimmedType = CLIValues.trimmedNonEmpty(type)

        if all && trimmedId != nil {
            throw CommandError("Cannot combine --all with --id.")
        }
        if trimmedId == nil && (!all || trimmedLocale == nil) {
            throw CommandError("Missing deletion target. Provide --id <screenshot-id> or --all with --locale <locale>.")
        }

        let service = try app.requireService()

        if let targetId = trimmedId {
            if dryRun {
                Log("🔍 [Dry Run] Checking App Store screenshot '\(targetId)'...".dim)
                do {
                    let screenshot = try await service.fetchScreenshot(id: targetId)
                    let name = screenshot.attributes?.fileName ?? "unnamed"
                    Log("🟡 [Dry Run] Would delete screenshot '\(name)' [ID: \(screenshot.id)].".yellow)
                } catch AppStoreServiceError.apiError(status: 404, _) {
                    Log("🟡 [Dry Run] Screenshot '\(targetId)' does not exist in App Store Connect.".yellow)
                }
                return
            }

            Log("🗑️  Deleting App Store screenshot '\(targetId)'...".dim)
            let deleted = try await service.deleteScreenshot(id: targetId)
            if deleted {
                Log("🟢 Successfully deleted screenshot '\(targetId)' from App Store Connect.".green.bold)
            } else {
                Log("🟡 Screenshot '\(targetId)' does not exist in App Store Connect (already absent).".yellow)
            }
            return
        }

        guard let targetLocale = trimmedLocale else { return }
        let parsedPlatform = try app.parsedPlatform()
        let parsedType = try trimmedType.map { try AppleTypeMapper.parseScreenshotDisplayType($0) }
        let resolvedAppId = try await app.resolveAppId(service: service)

        Log("🔍 Resolving editable App Store version for App ID '\(resolvedAppId)' (\(parsedPlatform.rawValue))...".dim)
        let version = try await service.resolveAppStoreVersion(
            appId: resolvedAppId,
            platform: parsedPlatform,
            versionString: app.appVersion,
            requireEditable: true
        )
        let localization = try await service.resolveVersionLocalization(
            versionId: version.id,
            locale: targetLocale
        )
        let sets = try await service.fetchScreenshotSets(
            localizationId: localization.id,
            displayType: parsedType
        )

        var candidates: [(displayType: String, setId: String, screenshotId: String, fileName: String)] = []
        for set in sets {
            let dt = set.attributes?.screenshotDisplayType?.rawValue ?? "UNKNOWN"
            let screenshots = try await service.fetchScreenshots(screenshotSetId: set.id)
            for item in screenshots {
                candidates.append((dt, set.id, item.id, item.attributes?.fileName ?? "unnamed"))
            }
        }

        if candidates.isEmpty {
            Log("🟡 No screenshots found matching locale '\(targetLocale)'\(parsedType.map { " and type '\($0.rawValue)'" } ?? "").".yellow)
            return
        }

        if dryRun {
            Log("\n🟡 [Dry Run] Would delete \(candidates.count) screenshot(s):".yellow.bold)
            for item in candidates {
                Log("  • [\(item.displayType)] \(item.fileName) [ID: \(item.screenshotId)]".dim)
            }
            Log("")
            return
        }

        Log("🗑️  Deleting \(candidates.count) screenshot(s) from App Store Connect...".dim)
        var deletedCount = 0
        for item in candidates {
            if try await service.deleteScreenshot(id: item.screenshotId) {
                deletedCount += 1
                Log("  ✔ Deleted \(item.fileName) [ID: \(item.screenshotId)]".green)
            }
        }

        Log("🟢 Successfully deleted \(deletedCount) screenshot(s) from App Store Connect.".green.bold)
    }
}
