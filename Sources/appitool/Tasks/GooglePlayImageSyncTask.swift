import Foundation
import GoogleServices
import Rainbow

/// Mirrors local `<locale>/<type>/` image folders onto Google Play store listing slots using each folder's
/// `.appitool-manifest.json` (see `GooglePlayImageSyncPlanner`).
///
/// All slots are planned first; any planning error aborts before changes. Changes for every slot are applied in a single
/// Google Play edit and committed once, so a failure leaves Google Play unchanged.
struct GooglePlayImageSyncTask {
    let service: GooglePlayService
    let packageName: String
    let batches: [ScreenshotUploadBatch<GooglePlayImageType>]
    let dryRun: Bool
    let validateOnly: Bool
    let changesNotSentForReview: Bool

    struct Summary {
        var slotsChanged = 0
        var uploaded = 0
        var deleted = 0
    }

    /// `<language>/<imageType>` identity stored in the manifest's `remoteSetId`.
    static func slotKey(language: String, imageType: GooglePlayImageType) -> String {
        "\(language)/\(imageType.rawValue)"
    }

    private struct PlannedSlot {
        let batch: ScreenshotUploadBatch<GooglePlayImageType>
        let directory: URL
        let shaByName: [String: String]
        let plan: GooglePlayImageSyncPlan

        var label: String { "[\(batch.locale) | \(batch.type.cliKey)]" }
    }

    @discardableResult
    func run() async throws -> Summary {
        // 1. Plan in a read-only edit.
        let planned = try await service.withEditSession(packageName: packageName, commit: false) { editId in
            try await planAll(editId: editId)
        }
        logPlan(planned)

        if dryRun {
            Log("\n🟡 [Dry Run] No changes were made.".yellow.bold + "\n")
            return Summary()
        }

        guard planned.contains(where: { $0.plan.hasMutations }) else {
            // Nothing to send; refresh manifests so renamed files are recorded under their new names.
            for slot in planned {
                try writeManifest(slot, uploaded: [:])
            }
            Log("\n🟢 Google Play listing images are already in sync.".green.bold + "\n")
            return Summary()
        }

        // 2. Re-plan and apply in one committed edit (re-planning guards against changes made in between).
        var summary = Summary()
        let results: [(PlannedSlot, [String: GooglePlayImage])] = try await service.withEditSession(
            packageName: packageName,
            commit: true,
            validateOnly: validateOnly,
            changesNotSentForReview: changesNotSentForReview ? true : nil
        ) { editId in
            var applied: [(PlannedSlot, [String: GooglePlayImage])] = []
            for slot in try await planAll(editId: editId) {
                applied.append((slot, try await apply(slot, editId: editId, summary: &summary)))
            }
            return applied
        }

        // 3. Record the new state (only when the edit was committed).
        if !validateOnly {
            for (slot, uploaded) in results {
                try writeManifest(slot, uploaded: uploaded)
            }
        }
        return summary
    }

    // MARK: - Planning

    private func planAll(editId: String) async throws -> [PlannedSlot] {
        var result: [PlannedSlot] = []
        var errors: [String] = []

        for batch in batches {
            guard let directory = batch.files.first?.deletingLastPathComponent() else { continue }
            let label = "[\(batch.locale) | \(batch.type.cliKey)]"

            let remote = try await service.listImages(
                packageName: packageName,
                editId: editId,
                language: batch.locale,
                imageType: batch.type
            )

            var shaByName: [String: String] = [:]
            var localFiles: [ScreenshotLocalFile] = []
            for file in batch.files {
                let sha = try ScreenshotManifest.sha256(of: file)
                shaByName[file.lastPathComponent] = sha
                localFiles.append(.init(name: file.lastPathComponent, sha256: sha))
            }

            let limits = GooglePlayImageSyncPlanner.limits(for: batch.type.cliKey)
            do {
                let plan = try GooglePlayImageSyncPlanner.plan(
                    localFiles: localFiles,
                    manifest: try ScreenshotManifest.load(from: directory),
                    slotKey: Self.slotKey(language: batch.locale, imageType: batch.type),
                    remoteImages: remote.map { .init(id: $0.id, sha256: $0.sha256) },
                    minCount: limits.min,
                    maxCount: limits.max
                )
                result.append(PlannedSlot(batch: batch, directory: directory, shaByName: shaByName, plan: plan))
            } catch let error as CommandError {
                errors.append("\(label) \(error.message)" + (error.hint.map { " \($0)" } ?? ""))
            }
        }

        guard errors.isEmpty else {
            throw CommandError(
                "Google Play image sync aborted before making changes:\n" + errors.map { "  • \($0)" }.joined(separator: "\n")
            )
        }
        return result
    }

    private func logPlan(_ planned: [PlannedSlot]) {
        Log("\n🔄 Google Play image sync plan for \(packageName):".bold)
        for slot in planned {
            guard slot.plan.hasMutations else {
                Log("  \(slot.label) ".cyan + "no changes".dim)
                continue
            }
            Log("  \(slot.label)".cyan + (slot.plan.isBootstrap ? " new slot (no manifest yet)".dim : ""))
            for item in slot.plan.items {
                switch item.action {
                case .keep:
                    Log("    = keep      \(item.file)".dim)
                case .reupload:
                    Log("    ↻ re-upload \(item.file) (unchanged, after first change)".dim)
                case .replace:
                    Log("    ~ replace   \(item.file)".yellow)
                case .add:
                    Log("    + add       \(item.file)".green)
                }
            }
            for file in slot.plan.removedFiles {
                Log("    - delete    \(file)".red)
            }
            if !slot.plan.deleteRemoteIds.isEmpty {
                Log("    (deletes \(slot.plan.deleteRemoteIds.count) remote image(s) after position \(slot.plan.keptCount) before uploading)".dim)
            }
        }
    }

    // MARK: - Applying

    /// Deletes the remote tail, then uploads the remaining local files in order. Returns uploaded images by file name.
    private func apply(_ slot: PlannedSlot, editId: String, summary: inout Summary) async throws -> [String: GooglePlayImage] {
        guard slot.plan.hasMutations else { return [:] }

        for imageId in slot.plan.deleteRemoteIds {
            try await service.deleteImage(
                packageName: packageName,
                editId: editId,
                language: slot.batch.locale,
                imageType: slot.batch.type,
                imageId: imageId
            )
            summary.deleted += 1
        }

        var uploaded: [String: GooglePlayImage] = [:]
        for (item, file) in zip(slot.plan.items, slot.batch.files) {
            if case .keep = item.action { continue }
            let image = try await service.uploadImage(
                packageName: packageName,
                editId: editId,
                language: slot.batch.locale,
                imageType: slot.batch.type,
                fileUrl: file
            )
            uploaded[item.file] = image
            summary.uploaded += 1
            Log("  ✔ \(slot.label) uploaded \(item.file) [ID: \(image.id)]".green)
        }
        summary.slotsChanged += 1
        return uploaded
    }

    private func writeManifest(_ slot: PlannedSlot, uploaded: [String: GooglePlayImage]) throws {
        var entries: [ScreenshotManifest.Entry] = []
        for item in slot.plan.items {
            let sha = slot.shaByName[item.file] ?? ""
            if case .keep(let remoteId, let remoteSha) = item.action {
                entries.append(.init(file: item.file, remoteId: remoteId, sha256: sha, remoteSha256: remoteSha))
            } else if let image = uploaded[item.file] {
                entries.append(.init(file: item.file, remoteId: image.id, sha256: sha, remoteSha256: image.sha256))
            }
        }
        try ScreenshotManifest(
            store: "google",
            locale: slot.batch.locale,
            type: slot.batch.type.cliKey,
            remoteSetId: Self.slotKey(language: slot.batch.locale, imageType: slot.batch.type),
            entries: entries
        ).write(to: slot.directory)
    }
}
