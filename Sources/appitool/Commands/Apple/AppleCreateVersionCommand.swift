import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

/// Creates a new App Store version. Without `--app-version`, the version comes from the Xcode project's
/// `MARKETING_VERSION`; when that is not higher than the App Store's latest version, the latest version's patch number
/// is bumped and the Xcode project is updated to match.
struct AppleCreateVersionCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-version",
        abstract: "Creates a new App Store version (defaults to the Xcode project version, or the latest App Store version with the patch number bumped)."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "Release type after approval: manual, after-approval, or scheduled (App Store Connect default when omitted).")
    var releaseType: String?

    @Option(name: .long, help: "Earliest release date for --release-type scheduled (ISO 8601, e.g. 2026-12-01T09:00:00Z).")
    var releaseDate: String?

    @Option(name: .long, help: "Copyright text (e.g. \"2026 Example Inc.\").")
    var copyright: String?

    @Option(name: .long, help: "Path to .xcodeproj used for the default version (defaults to XCODE_PROJECT in .env or auto-discovered).")
    var project: String?

    @Option(name: .long, help: "Path to .xcworkspace used for the default version (defaults to XCODE_WORKSPACE in .env or auto-discovered).")
    var workspacePath: String?

    @Flag(name: .long, help: "Show the version that would be created without creating it or changing the Xcode project.")
    var dryRun: Bool = false

    /// API values for `--release-type`.
    static func releaseTypeValue(_ raw: String?) throws -> String? {
        guard let clean = CLIValues.trimmedNonEmpty(raw) else { return nil }
        switch clean.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "manual": return "MANUAL"
        case "after-approval", "automatic": return "AFTER_APPROVAL"
        case "scheduled": return "SCHEDULED"
        default: throw ValidationError("Unsupported --release-type '\(clean)'. Valid values: manual, after-approval, scheduled.")
        }
    }

    func validate() throws {
        let type = try Self.releaseTypeValue(releaseType)
        let hasDate = CLIValues.trimmedNonEmpty(releaseDate) != nil
        if type == "SCHEDULED" && !hasDate {
            throw ValidationError("--release-type scheduled requires --release-date.")
        }
        if hasDate && type != "SCHEDULED" {
            throw ValidationError("--release-date can only be used with --release-type scheduled.")
        }
        if let raw = CLIValues.trimmedNonEmpty(releaseDate), ISO8601DateFormatter().date(from: raw) == nil {
            throw ValidationError("--release-date must be ISO 8601 (e.g. 2026-12-01T09:00:00Z).")
        }
    }

    func execute() async throws {
        let platform = try app.parsedPlatform()
        let service = try app.requireService()
        let appId = try await app.resolveAppId(service: service)
        let releaseTypeValue = try Self.releaseTypeValue(releaseType)
        let earliestDate = CLIValues.trimmedNonEmpty(releaseDate).flatMap { ISO8601DateFormatter().date(from: $0) }

        // 1. Explicit version: follow it as-is and let App Store Connect validate it.
        if let explicit = CLIValues.trimmedNonEmpty(app.appVersion) {
            Log("🆕 Creating App Store version \(explicit) (\(platform.rawValue)) as requested...".dim)
            if dryRun {
                Log("🟡 [Dry Run] Would create version \(explicit) for app \(appId) (\(platform.rawValue)). Xcode project is not changed for explicit versions.".yellow)
                return
            }
            let created = try await create(service: service, appId: appId, platform: platform, version: explicit, releaseType: releaseTypeValue, earliestDate: earliestDate)
            logCreated(created, platform: platform)
            return
        }

        // 2. Default version: Xcode project version, or latest App Store version with the patch number bumped.
        Log("🔍 Reading App Store versions for App ID '\(appId)' (\(platform.rawValue))...".dim)
        let existing = try await service.fetchAppStoreVersions(appId: appId, platform: platform)
        if let editable = existing.first(where: { version in
            let state = version.attributes?.appVersionState?.rawValue ?? version.attributes?.appStoreState?.rawValue
            return state.map(AppStoreService.editableVersionStates.contains) ?? false
        }) {
            let state = editable.attributes?.appVersionState?.rawValue ?? editable.attributes?.appStoreState?.rawValue ?? "UNKNOWN"
            throw CommandError(
                "Version \(editable.attributes?.versionString ?? editable.id) [\(state)] is already in progress for \(platform.rawValue); App Store Connect allows one editable version per platform.",
                hint: "Edit that version (apple metadata / apple assets), or release or remove it before creating a new one."
            )
        }

        let detected = XCodeTasks.autoDetect()
        let resolvedWorkspace = workspacePath ?? EnvLoader.value(for: "XCODE_WORKSPACE") ?? detected.workspace
        let resolvedProject = project ?? EnvLoader.value(for: "XCODE_PROJECT") ?? detected.project
        var projectVersion: String?
        if resolvedWorkspace != nil || resolvedProject != nil {
            projectVersion = await XCodeTasks.resolveProjectVersion(projectPath: resolvedProject, workspacePath: resolvedWorkspace).version
        }

        let existingStrings = existing.compactMap { $0.attributes?.versionString }
        let decision = try AppVersionPolicy.resolveDefault(projectVersion: projectVersion, existingVersions: existingStrings)
        Log("   Xcode project version: \(projectVersion ?? "not found") · Latest App Store version: \(AppVersionPolicy.highest(existingStrings) ?? "none")".dim)
        Log("   → \(decision.version) (\(decision.reason))".dim)

        if dryRun {
            Log("🟡 [Dry Run] Would create version \(decision.version)\(decision.updatesProject ? " and set the Xcode project MARKETING_VERSION to \(decision.version)" : "").".yellow)
            return
        }

        let created = try await create(service: service, appId: appId, platform: platform, version: decision.version, releaseType: releaseTypeValue, earliestDate: earliestDate)
        logCreated(created, platform: platform)

        // 3. Keep the Xcode project in sync with the bumped version (only after App Store Connect accepted it).
        guard decision.updatesProject else { return }
        do {
            let targets = try XCodeTasks.updateMarketingVersion(decision.version, projectPath: resolvedProject, workspacePath: resolvedWorkspace)
            Log("📝 Updated Xcode project MARKETING_VERSION to \(decision.version) (\(targets.joined(separator: ", "))).".green)
        } catch {
            Log("🟡 Version \(decision.version) was created, but updating the Xcode project failed: \(error.localizedDescription). Set MARKETING_VERSION to \(decision.version) manually.".yellow)
        }
    }

    /// Creates the version and turns App Store Connect errors into explanatory command errors.
    private func create(
        service: AppStoreService,
        appId: String,
        platform: Components.Schemas.Platform,
        version: String,
        releaseType: String?,
        earliestDate: Date?
    ) async throws -> Components.Schemas.AppStoreVersion {
        do {
            return try await service.createAppStoreVersion(
                appId: appId,
                platform: platform,
                versionString: version,
                releaseType: releaseType,
                earliestReleaseDate: earliestDate,
                copyright: CLIValues.trimmedNonEmpty(copyright)
            )
        } catch let error as AppStoreServiceError {
            throw CommandError(
                "App Store Connect rejected version \(version) (\(platform.rawValue)): \(error.localizedDescription)",
                hint: Self.hint(for: error)
            )
        }
    }

    /// Likely causes for common App Store Connect errors when creating a version.
    static func hint(for error: AppStoreServiceError) -> String? {
        guard case .apiError(let status, _) = error else { return nil }
        switch status {
        case 409:
            return "Another version is probably still editable for this platform, or this version string already exists. Check 'appitool apple metadata list' / App Store Connect."
        case 400, 422:
            return "The version string may be invalid or not higher than the latest App Store version (use up to three numbers, e.g. 1.2.3)."
        case 401, 403:
            return "The API key may lack permission to create versions (App Manager or Admin role required)."
        default:
            return nil
        }
    }

    private func logCreated(_ version: Components.Schemas.AppStoreVersion, platform: Components.Schemas.Platform) {
        let state = version.attributes?.appVersionState?.rawValue ?? version.attributes?.appStoreState?.rawValue ?? "UNKNOWN"
        Log("🟢 Created App Store version \(version.attributes?.versionString ?? "-") (\(platform.rawValue)) [ID: \(version.id), State: \(state)].".green.bold)
        Log("   App Store Connect copied the previous version's texts and screenshots; edit them with 'apple metadata' and 'apple assets'.".dim)
    }
}
