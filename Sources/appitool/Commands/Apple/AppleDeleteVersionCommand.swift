import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

/// Deletes an editable (not yet released) App Store version. Destructive: skipped in CI mode unless `--no-ci`.
struct AppleDeleteVersionCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-version",
        abstract: "Deletes an editable App Store version (defaults to the platform's current editable version)."
    )

    var destructiveCommandDescription: String { "apple delete-version" }

    @OptionGroup
    var app: AppleAssetAppOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Flag(name: .long, help: "Show which version would be deleted without deleting it.")
    var dryRun: Bool = false

    func execute() async throws {
        let platform = try app.parsedPlatform()
        let service = try app.requireService()
        let appId = try await app.resolveAppId(service: service)

        Log("🔍 Reading App Store versions for App ID '\(appId)' (\(platform.rawValue))...".dim)
        let versions = try await service.fetchAppStoreVersions(appId: appId, platform: platform)
        let target = try Self.selectTarget(versions: versions.map(Candidate.init), explicit: CLIValues.trimmedNonEmpty(app.appVersion))
        guard let target else {
            Log("🟢 No editable App Store version for \(platform.rawValue); nothing to delete.".green)
            return
        }

        let label = "\(target.versionString ?? target.id) [\(target.state)]"
        if dryRun {
            Log("🟡 [Dry Run] Would delete App Store version \(label) [ID: \(target.id)] with its localized texts, screenshots, and review details.".yellow)
            return
        }

        Log("🗑️  Deleting App Store version \(label)...".dim)
        do {
            if try await service.deleteAppStoreVersion(id: target.id) {
                Log("🟢 Deleted App Store version \(label).".green.bold)
                Log("   Asset Library images stay in the library; a MARKETING_VERSION bumped by 'apple create-version' is not reverted.".dim)
            } else {
                Log("🟡 Version \(label) no longer exists (already deleted).".yellow)
            }
        } catch let error as AppStoreServiceError {
            throw CommandError(
                "App Store Connect refused to delete version \(label): \(error.localizedDescription)",
                hint: Self.hint(for: error)
            )
        }
    }

    /// Minimal view of a version used to pick the deletion target.
    struct Candidate: Equatable {
        let id: String
        let versionString: String?
        let state: String

        init(id: String, versionString: String?, state: String) {
            self.id = id
            self.versionString = versionString
            self.state = state
        }

        init(_ version: Components.Schemas.AppStoreVersion) {
            self.init(
                id: version.id,
                versionString: version.attributes?.versionString,
                state: version.attributes?.appVersionState?.rawValue ?? version.attributes?.appStoreState?.rawValue ?? "UNKNOWN"
            )
        }

        var isEditable: Bool { AppStoreService.editableVersionStates.contains(state) }
    }

    /// Picks the version to delete: the explicit one (must exist and be editable) or the editable one (`nil` if none).
    static func selectTarget(versions: [Candidate], explicit: String?) throws -> Candidate? {
        if let explicit {
            guard let match = versions.first(where: { $0.versionString == explicit }) else {
                let available = versions.compactMap { v in v.versionString.map { "\($0) (\(v.state))" } }.joined(separator: ", ")
                throw CommandError("App Store version '\(explicit)' was not found (available: \(available.isEmpty ? "none" : available)).")
            }
            guard match.isEditable else {
                throw CommandError(
                    "Version \(explicit) is \(match.state) and cannot be deleted; only versions that are still being prepared can be removed."
                )
            }
            return match
        }
        return versions.first(where: \.isEditable)
    }

    /// Likely causes for App Store Connect refusing the deletion.
    static func hint(for error: AppStoreServiceError) -> String? {
        guard case .apiError(let status, _) = error else { return nil }
        switch status {
        case 409, 422:
            return "App Store Connect only removes versions that were never submitted for review; a version that was submitted (or rejected) may have to be kept and edited instead."
        case 401, 403:
            return "The API key may lack permission to delete versions (App Manager or Admin role required)."
        default:
            return nil
        }
    }
}
