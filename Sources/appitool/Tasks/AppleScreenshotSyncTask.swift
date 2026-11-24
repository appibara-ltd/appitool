import AppStoreConnectAPI
import AppleServices
import Foundation
import Rainbow

/// Mirrors local `<locale>/<screenshot-type>/` folders onto App Store Connect screenshot slots (Asset Library
/// placements) using each folder's `.appitool-manifest.json` (see `ScreenshotSyncPlanner`).
///
/// Every slot is planned before any remote change is made; a planning error in one slot aborts the whole run.
struct AppleScreenshotSyncTask {
    /// App Store Connect allows at most 10 screenshots per device slot (`appAssetLibraryRefData` group limits).
    static let maxScreenshotsPerSet = 10

    typealias Localization = Components.Schemas.AppStoreVersionLocalization

    struct SetTarget {
        let localization: Localization
        let batch: ScreenshotUploadBatch<AppleScreenshotSlot>
    }

    let service: AppStoreService
    let version: Components.Schemas.AppStoreVersion
    let assetLibraryId: String?
    let targets: [SetTarget]
    let waitProcessing: Bool
    let dryRun: Bool

    private struct PlannedSet {
        let target: SetTarget
        let locale: String
        let directory: URL
        let slotKey: String
        let remoteIds: [String]
        let shaByName: [String: String]
        let plan: ScreenshotSyncPlan

        var slot: AppleScreenshotSlot { target.batch.type }
        var label: String { "[\(locale) | \(slot.key)]" }
        var finalOrderIsSame: Bool {
            let order = plan.items.compactMap { item -> String? in
                if case .keep(let id) = item.action { return id }
                return nil
            } + plan.unmanagedRemoteIds
            return order == remoteIds
        }
        var isNoop: Bool { !plan.hasMutations && finalOrderIsSame }
    }

    struct Summary {
        var setsChanged = 0
        var uploaded = 0
        var deleted = 0
        var reordered = 0
    }

    @discardableResult
    func run() async throws -> Summary {
        let planned = try await planAll()

        logPlan(planned)
        if dryRun {
            Log("\n🟡 [Dry Run] No changes were made.".yellow.bold + "\n")
            return Summary()
        }

        var summary = Summary()
        for set in planned {
            if !set.isNoop {
                try await apply(set, summary: &summary)
            } else {
                // Refresh the manifest so files renamed without reordering are recorded under their new names.
                try writeManifest(for: set, ids: keptIds(set))
            }
        }
        return summary
    }

    // MARK: - Planning

    private func planAll() async throws -> [PlannedSet] {
        var result: [PlannedSet] = []
        var errors: [String] = []

        for target in targets {
            let locale = target.localization.attributes?.locale ?? target.batch.locale
            let slot = target.batch.type
            let label = "[\(locale) | \(slot.key)]"
            guard let directory = target.batch.files.first?.deletingLastPathComponent() else { continue }

            let remoteIds = try await service.fetchPlacements(
                localizationId: target.localization.id,
                placementTypes: [slot.placementType],
                placementGroup: slot.placementGroup
            ).map(\.id)

            var shaByName: [String: String] = [:]
            var localFiles: [ScreenshotSyncPlanner.LocalFile] = []
            for file in target.batch.files {
                let sha = try ScreenshotManifest.sha256(of: file)
                shaByName[file.lastPathComponent] = sha
                localFiles.append(.init(name: file.lastPathComponent, sha256: sha))
            }

            let slotKey = slot.slotKey(versionId: version.id, locale: locale)
            do {
                let plan = try ScreenshotSyncPlanner.plan(
                    localFiles: localFiles,
                    manifest: try ScreenshotManifest.load(from: directory),
                    remoteSetId: slotKey,
                    remoteIds: remoteIds,
                    maxPerSet: Self.maxScreenshotsPerSet
                )
                result.append(PlannedSet(
                    target: target,
                    locale: locale,
                    directory: directory,
                    slotKey: slotKey,
                    remoteIds: remoteIds,
                    shaByName: shaByName,
                    plan: plan
                ))
            } catch let error as CommandError {
                errors.append("\(label) \(error.message)" + (error.hint.map { " \($0)" } ?? ""))
            }
        }

        guard errors.isEmpty else {
            throw CommandError(
                "Screenshot sync aborted before making changes:\n" + errors.map { "  • \($0)" }.joined(separator: "\n")
            )
        }
        return result
    }

    private func logPlan(_ planned: [PlannedSet]) {
        let versionLabel = version.attributes?.versionString ?? version.id
        Log("\n🔄 Screenshot sync plan for version \(versionLabel):".bold)
        for set in planned {
            if set.isNoop {
                Log("  \(set.label) ".cyan + "no changes".dim)
                continue
            }
            Log("  \(set.label)".cyan + (set.plan.isBootstrap ? " new slot (no manifest yet)".dim : ""))
            for item in set.plan.items {
                switch item.action {
                case .keep:
                    Log("    = keep     \(item.file)".dim)
                case .replace:
                    Log("    ~ replace  \(item.file)".yellow)
                case .add:
                    Log("    + add      \(item.file)".green)
                }
            }
            for deletion in set.plan.deletions {
                Log("    - delete   \(deletion.file) [Placement: \(deletion.remoteId)]".red)
            }
            for id in set.plan.unmanagedRemoteIds {
                Log("    ? keep untracked remote screenshot [Placement: \(id)] (not in manifest)".yellow)
            }
            if !set.finalOrderIsSame || set.plan.hasMutations {
                Log("    ↕ apply file-name order".dim)
            }
        }
    }

    // MARK: - Applying

    private func apply(_ set: PlannedSet, summary: inout Summary) async throws {
        let localizationId = set.target.localization.id
        let slot = set.slot
        var count = set.remoteIds.count

        func upload(_ file: URL) async throws -> String {
            guard let assetLibraryId else {
                throw CommandError("Asset Library ID is required to upload screenshots.")
            }
            return try await ScreenshotPlacementOperations.uploadAndPlace(
                file: file,
                slot: slot,
                localizationId: localizationId,
                assetLibraryId: assetLibraryId,
                waitProcessing: waitProcessing,
                service: service
            ).id
        }

        // 1. Remove screenshots whose files were removed (frees slots first).
        for deletion in set.plan.deletions {
            try await service.deletePlacement(id: deletion.remoteId)
            count -= 1
            summary.deleted += 1
            Log("  🗑️  \(set.label) removed \(deletion.file) [Placement: \(deletion.remoteId)]".dim)
        }

        // 2. Upload new and changed files in display order.
        var finalIds: [String] = []
        for (item, file) in zip(set.plan.items, set.target.batch.files) {
            switch item.action {
            case .keep(let id):
                finalIds.append(id)
            case .add:
                let id = try await upload(file)
                count += 1
                summary.uploaded += 1
                finalIds.append(id)
                Log("  ✔ \(set.label) added \(item.file) [Placement: \(id)]".green)
            case .replace(let oldId):
                let id: String
                if count < Self.maxScreenshotsPerSet {
                    // Upload first so a failed upload never leaves the slot without this screenshot.
                    id = try await upload(file)
                    try await service.deletePlacement(id: oldId)
                } else {
                    Log("  🟡 \(set.label) slot is full; removing the old screenshot before uploading \(item.file).".yellow)
                    try await service.deletePlacement(id: oldId)
                    id = try await upload(file)
                }
                summary.uploaded += 1
                summary.deleted += 1
                finalIds.append(id)
                Log("  ✔ \(set.label) replaced \(item.file) [Placement: \(id)]".green)
            }
        }

        // 3. Apply file-name order (untracked remote screenshots stay at the end).
        let desiredOrder = finalIds + set.plan.unmanagedRemoteIds
        let currentOrder = try await service.fetchPlacements(
            localizationId: localizationId,
            placementTypes: [slot.placementType],
            placementGroup: slot.placementGroup
        ).map(\.id)
        if currentOrder != desiredOrder {
            try await service.orderPlacements(
                localizationId: localizationId,
                placementGroup: slot.placementGroup,
                placementIds: desiredOrder
            )
            summary.reordered += 1
            Log("  ↕ \(set.label) applied file-name order".dim)
        }

        // 4. Record the new state.
        try writeManifest(for: set, ids: finalIds)
        summary.setsChanged += 1
    }

    private func keptIds(_ set: PlannedSet) -> [String] {
        set.plan.items.compactMap { item in
            if case .keep(let id) = item.action { return id }
            return nil
        }
    }

    private func writeManifest(for set: PlannedSet, ids: [String]) throws {
        let entries = zip(set.target.batch.files, ids).map { file, id in
            ScreenshotManifest.Entry(
                file: file.lastPathComponent,
                remoteId: id,
                sha256: set.shaByName[file.lastPathComponent] ?? ""
            )
        }
        try ScreenshotManifest(
            store: "apple",
            locale: set.locale,
            type: set.slot.key,
            versionId: version.id,
            versionString: version.attributes?.versionString,
            remoteSetId: set.slotKey,
            entries: entries
        ).write(to: set.directory)
    }
}
