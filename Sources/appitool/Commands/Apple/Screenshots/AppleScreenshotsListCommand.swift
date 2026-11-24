import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleScreenshotsListCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists screenshot sets and screenshots registered in App Store Connect."
    )

    @OptionGroup
    var app: AppleScreenshotAppOptions

    @Option(name: .long, help: "Filter by App Store locale (e.g. en-US, tr). Omit to list all locales.")
    var locale: String?

    @Option(name: .shortAndLong, help: "Filter by screenshot display type (e.g. iphone-67, ipad-pro-129). Omit to list all sets.")
    var type: String?

    func execute() async throws {
        let parsedPlatform = try app.parsedPlatform()
        let parsedType = try CLIValues.trimmedNonEmpty(type).map {
            try AppleTypeMapper.parseScreenshotDisplayType($0)
        }
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

        var totalSets = 0
        var totalScreenshots = 0

        for loc in localizations {
            let locName = loc.attributes?.locale ?? loc.id
            let sets = try await service.fetchScreenshotSets(localizationId: loc.id, displayType: parsedType)
            guard !sets.isEmpty else { continue }

            for set in sets {
                totalSets += 1
                let displayTypeStr = set.attributes?.screenshotDisplayType?.rawValue ?? "UNKNOWN"
                let screenshots = try await service.fetchScreenshots(screenshotSetId: set.id)
                totalScreenshots += screenshots.count

                Log("\n  [\(locName)] ".cyan.bold + "\(displayTypeStr)".bold + " [Set ID: \(set.id), Count: \(screenshots.count)]".dim)
                if screenshots.isEmpty {
                    Log("    (empty)".dim)
                    continue
                }
                for item in screenshots {
                    let name = item.attributes?.fileName ?? "unnamed"
                    let dims: String = {
                        if let w = item.attributes?.imageAsset?.width, let h = item.attributes?.imageAsset?.height {
                            return "\(w)x\(h)"
                        }
                        return "-"
                    }()
                    let state = item.attributes?.assetDeliveryState?.state?.rawValue ?? "-"
                    Log("    • ".cyan + "\(name)".bold + " [ID: \(item.id), Dims: \(dims), State: \(state)]".dim)
                }
            }
        }

        if totalSets == 0 {
            Log("🟡 No screenshot sets found matching your filter criteria on version '\(versionLabel)'.".yellow)
        } else {
            Log("\nTotal: \(totalScreenshots) screenshot(s) across \(totalSets) set(s).".bold)
            Log("")
        }
    }
}
