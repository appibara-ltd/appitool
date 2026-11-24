import ArgumentParser
import Foundation
import Testing
@testable import appitool

@Suite("Screenshot Sync Tests")
struct ScreenshotSyncTests {
    private func manifest(setId: String = "set-1", _ entries: [(String, String, String)]) -> ScreenshotManifest {
        ScreenshotManifest(
            store: "apple",
            locale: "en-US",
            type: "iphone-67",
            versionId: "ver-1",
            versionString: "1.0.0",
            remoteSetId: setId,
            entries: entries.map { .init(file: $0.0, remoteId: $0.1, sha256: $0.2) }
        )
    }

    private func local(_ files: [(String, String)]) -> [ScreenshotSyncPlanner.LocalFile] {
        files.map { .init(name: $0.0, sha256: $0.1) }
    }

    @Test("Unchanged folder produces keep-only plan with no mutations")
    func unchangedFolderIsNoop() throws {
        let plan = try ScreenshotSyncPlanner.plan(
            localFiles: local([("01_a.png", "h1"), ("02_b.png", "h2")]),
            manifest: manifest([("01_a.png", "r1", "h1"), ("02_b.png", "r2", "h2")]),
            remoteSetId: "set-1",
            remoteIds: ["r1", "r2"],
            maxPerSet: 10
        )
        #expect(plan.items.map(\.action) == [.keep(remoteId: "r1"), .keep(remoteId: "r2")])
        #expect(plan.deletions.isEmpty)
        #expect(plan.hasMutations == false)
        #expect(plan.isBootstrap == false)
    }

    @Test("Edited, added, and removed files map to replace, add, and delete")
    func editAddRemove() throws {
        let plan = try ScreenshotSyncPlanner.plan(
            localFiles: local([("01_a.png", "h1-edited"), ("03_c.png", "h3")]),
            manifest: manifest([("01_a.png", "r1", "h1"), ("02_b.png", "r2", "h2")]),
            remoteSetId: "set-1",
            remoteIds: ["r1", "r2"],
            maxPerSet: 10
        )
        #expect(plan.items == [
            .init(file: "01_a.png", action: .replace(oldRemoteId: "r1")),
            .init(file: "03_c.png", action: .add),
        ])
        #expect(plan.deletions == [.init(remoteId: "r2", file: "02_b.png")])
        #expect(plan.uploadCount == 2)
    }

    @Test("Renamed unchanged file is kept by checksum, not re-uploaded")
    func renameIsKeptByChecksum() throws {
        let plan = try ScreenshotSyncPlanner.plan(
            localFiles: local([("01_b.png", "h2"), ("02_a.png", "h1")]),
            manifest: manifest([("01_a.png", "r1", "h1"), ("02_b.png", "r2", "h2")]),
            remoteSetId: "set-1",
            remoteIds: ["r1", "r2"],
            maxPerSet: 10
        )
        #expect(plan.items.map(\.action) == [.keep(remoteId: "r2"), .keep(remoteId: "r1")])
        #expect(plan.deletions.isEmpty)
        #expect(plan.hasMutations == false)
    }

    @Test("Untracked remote screenshots are kept and screenshots deleted remotely are re-added")
    func untrackedAndMissingRemote() throws {
        let plan = try ScreenshotSyncPlanner.plan(
            localFiles: local([("01_a.png", "h1"), ("02_b.png", "h2")]),
            manifest: manifest([("01_a.png", "r1", "h1"), ("02_b.png", "r2", "h2")]),
            remoteSetId: "set-1",
            remoteIds: ["r1", "web-added"],
            maxPerSet: 10
        )
        #expect(plan.items.map(\.action) == [.keep(remoteId: "r1"), .add])
        #expect(plan.unmanagedRemoteIds == ["web-added"])
        #expect(plan.deletions.isEmpty)
    }

    @Test("Missing manifest bootstraps an empty or missing remote set and rejects a non-empty one")
    func bootstrapRules() throws {
        let fresh = try ScreenshotSyncPlanner.plan(
            localFiles: local([("01_a.png", "h1"), ("02_b.png", "h2")]),
            manifest: nil,
            remoteSetId: nil,
            remoteIds: [],
            maxPerSet: 10
        )
        #expect(fresh.isBootstrap == true)
        #expect(fresh.items.map(\.action) == [.add, .add])

        let emptyRemote = try ScreenshotSyncPlanner.plan(
            localFiles: local([("01_a.png", "h1")]),
            manifest: nil,
            remoteSetId: "set-1",
            remoteIds: [],
            maxPerSet: 10
        )
        #expect(emptyRemote.isBootstrap == true)

        #expect(throws: CommandError.self) {
            _ = try ScreenshotSyncPlanner.plan(
                localFiles: local([("01_a.png", "h1")]),
                manifest: nil,
                remoteSetId: "set-1",
                remoteIds: ["r1"],
                maxPerSet: 10
            )
        }
    }

    @Test("Manifest for another set and plans over the per-set limit are rejected")
    func staleManifestAndLimit() {
        #expect(throws: CommandError.self) {
            _ = try ScreenshotSyncPlanner.plan(
                localFiles: local([("01_a.png", "h1")]),
                manifest: manifest(setId: "old-set", [("01_a.png", "r1", "h1")]),
                remoteSetId: "new-set",
                remoteIds: ["x1"],
                maxPerSet: 10
            )
        }
        #expect(throws: CommandError.self) {
            _ = try ScreenshotSyncPlanner.plan(
                localFiles: local((1...3).map { ("0\($0).png", "h\($0)") }),
                manifest: nil,
                remoteSetId: nil,
                remoteIds: [],
                maxPerSet: 2
            )
        }
    }

    @Test("Manifest round-trips through disk and computes SHA-256")
    func manifestRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appitool-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try ScreenshotManifest.load(from: dir) == nil)

        let original = manifest([("01_a.png", "r1", "h1")])
        try original.write(to: dir)
        #expect(try ScreenshotManifest.load(from: dir) == original)

        let file = dir.appendingPathComponent("01_a.png")
        try Data("abc".utf8).write(to: file)
        #expect(try ScreenshotManifest.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        try Data("not json".utf8).write(to: dir.appendingPathComponent(ScreenshotManifest.fileName))
        #expect(throws: CommandError.self) {
            _ = try ScreenshotManifest.load(from: dir)
        }
    }

    // MARK: - Google Play

    private func googleManifest(slot: String = "en-US/phoneScreenshots", _ entries: [(String, String, String)]) -> ScreenshotManifest {
        ScreenshotManifest(
            store: "google",
            locale: "en-US",
            type: "phone",
            remoteSetId: slot,
            entries: entries.map { .init(file: $0.0, remoteId: "id-\($0.2)", sha256: $0.1, remoteSha256: $0.2) }
        )
    }

    private func remote(_ shas: [String]) -> [GooglePlayImageSyncPlanner.RemoteImage] {
        shas.map { .init(id: "id-\($0)", sha256: $0) }
    }

    private func googlePlan(
        _ files: [(String, String)],
        manifest: ScreenshotManifest?,
        remote shas: [String],
        min: Int = 1,
        max: Int = 8
    ) throws -> GooglePlayImageSyncPlan {
        try GooglePlayImageSyncPlanner.plan(
            localFiles: local(files),
            manifest: manifest,
            slotKey: "en-US/phoneScreenshots",
            remoteImages: remote(shas),
            minCount: min,
            maxCount: max
        )
    }

    private let threeFileManifest: [(String, String, String)] = [
        ("01.png", "l1", "g1"), ("02.png", "l2", "g2"), ("03.png", "l3", "g3"),
    ]

    @Test("Google: unchanged slot keeps everything and sends nothing")
    func googleNoop() throws {
        let plan = try googlePlan(
            [("01.png", "l1"), ("02.png", "l2"), ("03.png", "l3")],
            manifest: googleManifest(threeFileManifest),
            remote: ["g1", "g2", "g3"]
        )
        #expect(plan.keptCount == 3)
        #expect(plan.deleteRemoteIds.isEmpty)
        #expect(plan.hasMutations == false)
    }

    @Test("Google: editing a middle file rebuilds from that position")
    func googleEditMiddle() throws {
        let plan = try googlePlan(
            [("01.png", "l1"), ("02.png", "l2-edited"), ("03.png", "l3")],
            manifest: googleManifest(threeFileManifest),
            remote: ["g1", "g2", "g3"]
        )
        #expect(plan.items.map(\.action) == [.keep(remoteId: "id-g1", remoteSha256: "g1"), .replace, .reupload])
        #expect(plan.deleteRemoteIds == ["id-g2", "id-g3"])
    }

    @Test("Google: appending a file uploads only the new file")
    func googleAppend() throws {
        let plan = try googlePlan(
            [("01.png", "l1"), ("02.png", "l2"), ("03.png", "l3"), ("04.png", "l4")],
            manifest: googleManifest(threeFileManifest),
            remote: ["g1", "g2", "g3"]
        )
        #expect(plan.keptCount == 3)
        #expect(plan.items.last?.action == .add)
        #expect(plan.deleteRemoteIds.isEmpty)
    }

    @Test("Google: removing a file deletes it and re-uploads the files after it")
    func googleRemove() throws {
        let plan = try googlePlan(
            [("01.png", "l1"), ("03.png", "l3")],
            manifest: googleManifest(threeFileManifest),
            remote: ["g1", "g2", "g3"]
        )
        #expect(plan.items.map(\.action) == [.keep(remoteId: "id-g1", remoteSha256: "g1"), .reupload])
        #expect(plan.deleteRemoteIds == ["id-g2", "id-g3"])
        #expect(plan.removedFiles == ["02.png"])
    }

    @Test("Google: reordering by renaming re-uploads from the first moved file")
    func googleReorder() throws {
        let plan = try googlePlan(
            [("01.png", "l1"), ("02.png", "l3"), ("03.png", "l2")],
            manifest: googleManifest([("01.png", "l1", "g1"), ("02.png", "l2", "g2"), ("03.png", "l3", "g3")]),
            remote: ["g1", "g2", "g3"]
        )
        // 02/03 swapped contents: by-name match sees both as changed.
        #expect(plan.keptCount == 1)
        #expect(plan.deleteRemoteIds == ["id-g2", "id-g3"])
    }

    @Test("Google: bootstrap, untracked tail, stale slot, and limits")
    func googleRules() throws {
        let bootstrap = try googlePlan([("01.png", "l1"), ("02.png", "l2")], manifest: nil, remote: [])
        #expect(bootstrap.isBootstrap == true)
        #expect(bootstrap.items.map(\.action) == [.add, .add])

        #expect(throws: CommandError.self) {
            _ = try googlePlan([("01.png", "l1")], manifest: nil, remote: ["g1"])
        }
        // An untracked remote image after the first change cannot be restored, so the plan is rejected.
        #expect(throws: CommandError.self) {
            _ = try googlePlan(
                [("01.png", "l1-edited"), ("02.png", "l2")],
                manifest: googleManifest([("01.png", "l1", "g1"), ("02.png", "l2", "g2")]),
                remote: ["g1", "web-added", "g2"]
            )
        }
        #expect(throws: CommandError.self) {
            _ = try googlePlan([("01.png", "l1")], manifest: googleManifest(slot: "tr-TR/phoneScreenshots", []), remote: [])
        }
        #expect(throws: CommandError.self) {
            _ = try googlePlan([("01.png", "l1")], manifest: nil, remote: [], min: 2)
        }
        #expect(throws: CommandError.self) {
            _ = try googlePlan([("01.png", "l1"), ("02.png", "l2")], manifest: nil, remote: [], max: 1)
        }
        #expect(GooglePlayImageSyncPlanner.limits(for: "phone") == (2, 8))
        #expect(GooglePlayImageSyncPlanner.limits(for: "icon") == (1, 1))
    }

    @Test("google upload --sync rejects --replace")
    func googleSyncFlagValidation() throws {
        let parsed = try #require(
            try appitool.parseAsRoot(["google", "assets", "upload", "--sync", "--dry-run"]) as? GoogleAssetsUploadCommand
        )
        #expect(parsed.sync == true)
        #expect(throws: (any Error).self) {
            _ = try appitool.parseAsRoot(["google", "assets", "upload", "--sync", "--replace"])
        }
    }

    @Test("upload --sync rejects --replace")
    func syncFlagValidation() throws {
        let parsed = try #require(
            try appitool.parseAsRoot(["apple", "assets", "upload", "--sync", "--dry-run"]) as? AppleAssetsUploadCommand
        )
        #expect(parsed.sync == true)
        #expect(throws: (any Error).self) {
            _ = try appitool.parseAsRoot(["apple", "assets", "upload", "--sync", "--replace"])
        }
    }
}
