import Crypto
import Foundation

/// Per-slot manifest stored as `.appitool-manifest.json` inside a `<locale>/<type>/` screenshot folder.
///
/// It records which remote image each local file corresponds to and the SHA-256 of the local file at the time it was
/// downloaded or uploaded, so `upload --sync` can detect edited, added, renamed, and removed files.
struct ScreenshotManifest: Codable, Equatable, Sendable {
    static let fileName = ".appitool-manifest.json"
    static let currentSchemaVersion = 1

    struct Entry: Codable, Equatable, Sendable {
        let file: String
        let remoteId: String
        /// SHA-256 of the local file.
        let sha256: String
        /// Store-side image hash (Google Play `Image.sha256`); `nil` for App Store Connect.
        var remoteSha256: String? = nil
    }

    var schemaVersion: Int = ScreenshotManifest.currentSchemaVersion
    let store: String
    let locale: String
    let type: String
    /// App Store version ID (App Store Connect only).
    var versionId: String? = nil
    /// App Store version string (App Store Connect only).
    var versionString: String? = nil
    /// Remote slot identity: the App Store screenshot set ID, or `<language>/<imageType>` for Google Play.
    let remoteSetId: String
    let entries: [Entry]

    /// Loads the manifest in `directory`, returning `nil` when none exists.
    static func load(from directory: URL) throws -> ScreenshotManifest? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(ScreenshotManifest.self, from: Data(contentsOf: url))
            guard manifest.schemaVersion == currentSchemaVersion else {
                throw CommandError("Unsupported screenshot manifest version \(manifest.schemaVersion) at \(url.path). Run the download command again.")
            }
            return manifest
        } catch let error as CommandError {
            throw error
        } catch {
            throw CommandError("Invalid screenshot manifest at \(url.path): \(error.localizedDescription). Delete it or run the download command again.")
        }
    }

    /// Writes the manifest into `directory` as pretty-printed JSON.
    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Hex-encoded SHA-256 of the file at `url`.
    static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Prepares a slot folder after a download, before its new manifest is written.
    ///
    /// Removes images that a previous download recorded but that no longer exist remotely (`isStillRemote` is
    /// `false`), and warns about other local images that `upload --sync` would upload as new.
    static func cleanUpAfterDownload(
        directory: URL,
        newEntries: [Entry],
        label: String,
        storeName: String,
        isStillRemote: (Entry) -> Bool
    ) throws {
        let fm = FileManager.default
        let newFiles = Set(newEntries.map(\.file))

        if let previous = try? load(from: directory) {
            for entry in previous.entries where !newFiles.contains(entry.file) && !isStillRemote(entry) {
                let staleURL = directory.appendingPathComponent(entry.file)
                if fm.fileExists(atPath: staleURL.path) {
                    try fm.removeItem(at: staleURL)
                    Log("  🗑️  Removed \(label)/\(entry.file) (no longer on \(storeName))".dim)
                }
            }
        }

        let untracked = (try? fm.contentsOfDirectory(atPath: directory.path))?
            .filter { name in
                !name.hasPrefix(".") && !newFiles.contains(name)
                    && ScreenshotFileResolver.supportedExtensions.contains((name as NSString).pathExtension.lowercased())
            }
            .sorted() ?? []
        if !untracked.isEmpty {
            Log("  🟡 \(label): \(untracked.count) local file(s) not on \(storeName) (`upload --sync` will add them): \(untracked.joined(separator: ", "))".yellow)
        }
    }
}

// MARK: - Local Matching (shared by all stores)

/// A local image file with its SHA-256.
struct ScreenshotLocalFile: Equatable, Sendable {
    let name: String
    let sha256: String
}

/// Matches local files against a manifest, independent of how a store applies changes.
enum ScreenshotLocalMatcher {
    enum Match: Equatable, Sendable {
        /// Content unchanged since the manifest was written (possibly renamed) and still present remotely.
        case unchanged(ScreenshotManifest.Entry)
        /// Same file name, different content; the old remote image is still present.
        case changed(ScreenshotManifest.Entry)
        /// No usable manifest counterpart (new file, or its remote image is gone).
        case new
    }

    struct Result: Equatable, Sendable {
        /// One match per local file, in local order.
        let matches: [Match]
        /// Manifest entries whose files were removed locally and whose remote images still exist.
        let removed: [ScreenshotManifest.Entry]
    }

    static func match(
        localFiles: [ScreenshotLocalFile],
        manifest: ScreenshotManifest,
        isRemotePresent: (ScreenshotManifest.Entry) -> Bool
    ) -> Result {
        let localNames = Set(localFiles.map(\.name))
        var usedEntries = Set<String>()
        var matches: [String: Match] = [:]

        // 1. Match by file name.
        for local in localFiles {
            guard let entry = manifest.entries.first(where: { $0.file == local.name }) else { continue }
            usedEntries.insert(entry.file)
            if !isRemotePresent(entry) {
                matches[local.name] = .new
            } else if entry.sha256 == local.sha256 {
                matches[local.name] = .unchanged(entry)
            } else {
                matches[local.name] = .changed(entry)
            }
        }

        // 2. Match renamed files by checksum against entries whose file no longer exists locally.
        for local in localFiles where matches[local.name] == nil {
            if let entry = manifest.entries.first(where: {
                !usedEntries.contains($0.file) && !localNames.contains($0.file)
                    && $0.sha256 == local.sha256 && isRemotePresent($0)
            }) {
                usedEntries.insert(entry.file)
                matches[local.name] = .unchanged(entry)
            }
        }

        let removed = manifest.entries.filter { !usedEntries.contains($0.file) && isRemotePresent($0) }
        return Result(matches: localFiles.map { matches[$0.name] ?? .new }, removed: removed)
    }
}

// MARK: - App Store Connect

/// Plan describing how to bring one App Store Connect screenshot set in line with a local folder.
struct ScreenshotSyncPlan: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Local file is unchanged; the existing remote screenshot is kept.
        case keep(remoteId: String)
        /// Local file changed; upload it and delete the old remote screenshot.
        case replace(oldRemoteId: String)
        /// Local file has no remote counterpart; upload it.
        case add
    }

    struct Item: Equatable, Sendable {
        let file: String
        let action: Action
    }

    struct Deletion: Equatable, Sendable {
        let remoteId: String
        let file: String
    }

    /// Local files in display order with the action for each.
    let items: [Item]
    /// Remote screenshots whose local files were removed.
    let deletions: [Deletion]
    /// Remote screenshots not tracked by the manifest (e.g. added in App Store Connect after the download); kept as-is
    /// and placed after the managed screenshots.
    let unmanagedRemoteIds: [String]
    /// `true` when the remote set has no manifest yet and every local file is uploaded as new.
    let isBootstrap: Bool

    var uploadCount: Int {
        items.filter { if case .keep = $0.action { return false } else { return true } }.count
    }

    var hasMutations: Bool {
        uploadCount > 0 || !deletions.isEmpty
    }
}

/// Builds `ScreenshotSyncPlan`s from local files, the folder manifest, and the remote set state.
enum ScreenshotSyncPlanner {
    typealias LocalFile = ScreenshotLocalFile

    /// Computes the sync plan for one App Store Connect set.
    ///
    /// - Parameters:
    ///   - localFiles: Local image files in display (file-name) order.
    ///   - manifest: The folder's manifest, or `nil` when none exists.
    ///   - remoteSetId: The remote set ID, or `nil` when the set does not exist yet.
    ///   - remoteIds: Remote screenshot IDs in their current display order.
    ///   - maxPerSet: Maximum screenshots allowed in one set.
    static func plan(
        localFiles: [LocalFile],
        manifest: ScreenshotManifest?,
        remoteSetId: String?,
        remoteIds: [String],
        maxPerSet: Int
    ) throws -> ScreenshotSyncPlan {
        guard let manifest else {
            try ScreenshotSyncRules.requireBootstrapAllowed(remoteCount: remoteIds.count)
            try ScreenshotSyncRules.checkLimit(localFiles.count, max: maxPerSet)
            return ScreenshotSyncPlan(
                items: localFiles.map { .init(file: $0.name, action: .add) },
                deletions: [],
                unmanagedRemoteIds: [],
                isBootstrap: true
            )
        }

        guard let remoteSetId, remoteSetId == manifest.remoteSetId else {
            throw CommandError(
                "\(ScreenshotManifest.fileName) belongs to a different screenshot set (version \(manifest.versionString ?? manifest.versionId ?? "unknown")).",
                hint: "Run the download command again for the current version, or delete the manifest and upload with --replace."
            )
        }

        let remoteSet = Set(remoteIds)
        let result = ScreenshotLocalMatcher.match(localFiles: localFiles, manifest: manifest) {
            remoteSet.contains($0.remoteId)
        }

        let items = zip(localFiles, result.matches).map { local, match -> ScreenshotSyncPlan.Item in
            switch match {
            case .unchanged(let entry): return .init(file: local.name, action: .keep(remoteId: entry.remoteId))
            case .changed(let entry): return .init(file: local.name, action: .replace(oldRemoteId: entry.remoteId))
            case .new: return .init(file: local.name, action: .add)
            }
        }
        let deletions = result.removed.map { ScreenshotSyncPlan.Deletion(remoteId: $0.remoteId, file: $0.file) }

        let managedIds = Set(manifest.entries.map(\.remoteId))
        let unmanaged = remoteIds.filter { !managedIds.contains($0) }

        try ScreenshotSyncRules.checkLimit(items.count + unmanaged.count, max: maxPerSet)
        return ScreenshotSyncPlan(items: items, deletions: deletions, unmanagedRemoteIds: unmanaged, isBootstrap: false)
    }
}

// MARK: - Google Play

/// Plan describing how to bring one Google Play listing image slot in line with a local folder.
///
/// Google Play has no reorder call and appends uploads, so the plan keeps the longest unchanged leading run of
/// remote images, deletes every remote image after it, and uploads the remaining local files in order.
struct GooglePlayImageSyncPlan: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Unchanged and already in place; nothing is sent.
        case keep(remoteId: String, remoteSha256: String)
        /// Unchanged, but sits after the first change, so it is deleted and uploaded again from the local file.
        case reupload
        /// Content changed; the new file is uploaded.
        case replace
        /// New file; uploaded.
        case add
    }

    struct Item: Equatable, Sendable {
        let file: String
        let action: Action
    }

    /// Local files in display order with the action for each.
    let items: [Item]
    /// Remote image IDs to delete (everything after the kept leading run), in remote order.
    let deleteRemoteIds: [String]
    /// Manifest entries whose local files were removed (for reporting; covered by `deleteRemoteIds`).
    let removedFiles: [String]
    /// `true` when the slot has no manifest yet and every local file is uploaded as new.
    let isBootstrap: Bool

    var keptCount: Int {
        items.prefix { if case .keep = $0.action { return true } else { return false } }.count
    }

    var hasMutations: Bool {
        !deleteRemoteIds.isEmpty || keptCount < items.count
    }
}

/// Builds `GooglePlayImageSyncPlan`s.
enum GooglePlayImageSyncPlanner {
    struct RemoteImage: Equatable, Sendable {
        let id: String
        let sha256: String?
    }

    /// Computes the sync plan for one Google Play slot.
    ///
    /// - Parameters:
    ///   - localFiles: Local image files in display (file-name) order.
    ///   - manifest: The folder's manifest, or `nil` when none exists.
    ///   - slotKey: `<language>/<imageType>` identity of the slot.
    ///   - remoteImages: Remote images in their current display order.
    ///   - minCount: Minimum images the slot must keep (when non-empty).
    ///   - maxCount: Maximum images allowed in the slot.
    static func plan(
        localFiles: [ScreenshotLocalFile],
        manifest: ScreenshotManifest?,
        slotKey: String,
        remoteImages: [RemoteImage],
        minCount: Int,
        maxCount: Int
    ) throws -> GooglePlayImageSyncPlan {
        try ScreenshotSyncRules.checkLimit(localFiles.count, max: maxCount)
        if localFiles.count < minCount {
            throw CommandError("Slot would contain \(localFiles.count) image(s); Google Play requires at least \(minCount).")
        }

        guard let manifest else {
            try ScreenshotSyncRules.requireBootstrapAllowed(remoteCount: remoteImages.count)
            return GooglePlayImageSyncPlan(
                items: localFiles.map { .init(file: $0.name, action: .add) },
                deleteRemoteIds: [],
                removedFiles: [],
                isBootstrap: true
            )
        }

        guard manifest.remoteSetId == slotKey else {
            throw CommandError(
                "\(ScreenshotManifest.fileName) belongs to slot '\(manifest.remoteSetId)', not '\(slotKey)'.",
                hint: "Run the download command again, or delete the manifest and upload with --replace."
            )
        }

        let remoteShas = Set(remoteImages.compactMap(\.sha256))
        let result = ScreenshotLocalMatcher.match(localFiles: localFiles, manifest: manifest) { entry in
            entry.remoteSha256.map(remoteShas.contains) ?? false
        }

        // Desired remote hash per position (nil = must be uploaded).
        let desired: [String?] = result.matches.map { match in
            if case .unchanged(let entry) = match { return entry.remoteSha256 }
            return nil
        }

        // Longest leading run already in place.
        var kept = 0
        while kept < desired.count, kept < remoteImages.count,
              let sha = desired[kept], sha == remoteImages[kept].sha256 {
            kept += 1
        }

        // Remote images after the kept run must be removed; untracked ones cannot be restored from local files.
        let tail = remoteImages.dropFirst(kept)
        let managedShas = Set(manifest.entries.compactMap(\.remoteSha256))
        let untracked = tail.filter { !($0.sha256.map(managedShas.contains) ?? false) }
        guard untracked.isEmpty else {
            throw CommandError(
                "Slot has \(untracked.count) image(s) not in \(ScreenshotManifest.fileName) that would have to be deleted to apply the new order.",
                hint: "Run the download command again so they are tracked, or upload with --replace."
            )
        }

        let items = zip(localFiles, result.matches).enumerated().map { index, pair -> GooglePlayImageSyncPlan.Item in
            let (local, match) = pair
            if index < kept, case .unchanged(let entry) = match {
                return .init(file: local.name, action: .keep(remoteId: remoteImages[index].id, remoteSha256: entry.remoteSha256 ?? ""))
            }
            switch match {
            case .unchanged: return .init(file: local.name, action: .reupload)
            case .changed: return .init(file: local.name, action: .replace)
            case .new: return .init(file: local.name, action: .add)
            }
        }

        return GooglePlayImageSyncPlan(
            items: items,
            deleteRemoteIds: tail.map(\.id),
            removedFiles: result.removed.map(\.file),
            isBootstrap: false
        )
    }

    /// Maximum and minimum image counts for a Google Play slot.
    static func limits(for cliKey: String) -> (min: Int, max: Int) {
        switch cliKey {
        case "icon", "feature-graphic", "tv-banner":
            return (1, 1)
        case "phone":
            return (2, 8)
        default:
            return (1, 8)
        }
    }
}

// MARK: - Shared Rules

enum ScreenshotSyncRules {
    static func requireBootstrapAllowed(remoteCount: Int) throws {
        guard remoteCount == 0 else {
            throw CommandError(
                "Remote slot has \(remoteCount) image(s) but the folder has no \(ScreenshotManifest.fileName).",
                hint: "Run the download command first, or upload with --replace to overwrite the slot."
            )
        }
    }

    static func checkLimit(_ count: Int, max: Int) throws {
        guard count <= max else {
            throw CommandError("Slot would contain \(count) image(s); the store allows at most \(max).")
        }
    }
}
