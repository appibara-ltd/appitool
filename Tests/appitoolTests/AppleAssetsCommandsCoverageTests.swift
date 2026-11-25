import ArgumentParser
import Foundation
import Testing
@testable import appitool
import AppStoreConnectAPI
import AppleServices

// MARK: - Asset Library JSON + router helpers

enum AssetStub {
    static let group67 = "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"

    static func image(_ id: String, fileName: String = "s.png", template: String? = "https://cdn.example/{w}x{h}bb.{f}", state: String = "COMPLETE") -> String {
        var attrs = #""state":"\#(state)","fileName":"\#(fileName)","fileSize":4"#
        if let template { attrs += #","imageAsset":{"templateUrl":"\#(template)","width":10,"height":20}"# }
        return ASCStub.res("appAssetLibraryImages", id, "{\(attrs)}")
    }

    static func placement(_ id: String, type: String = "APP_SCREENSHOT", group: String? = group67, imageId: String? = nil) -> String {
        var attrs = #""placementType":"\#(type)","state":"ACTIVE""#
        if let group { attrs += #","placementGroup":"\#(group)""# }
        let rel = imageId.map { #"{"image":{"data":{"type":"appAssetLibraryImages","id":"\#($0)"}}}"# }
        return ASCStub.res("appAssetLibraryPlacements", id, "{\(attrs)}", rel: rel)
    }

    static func isCreativeQuery(_ request: StubRequest) -> Bool {
        request.url.absoluteString.contains("/placements") && (request.query.contains("HEADER") || request.query.contains("SEARCH_RESULTS"))
    }

    static func isScreenshotQuery(_ request: StubRequest) -> Bool {
        request.url.absoluteString.contains("/placements") && !isCreativeQuery(request)
    }

    /// Version + localization + asset library routes for app `123`.
    static func base(_ router: StubRouter = StubRouter(), versions: [String] = [AppleJSON.version()], locales: [String] = ["en-US"]) -> StubRouter {
        let locs = locales.enumerated().map { AppleJSON.localization("loc\($0.offset + 1)", locale: $0.element) }
        return router
            .on("GET", "/apps/123/appStoreVersions", .ok(ASCStub.list(versions)))
            .on("GET", "/appStoreVersionLocalizations?", .ok(ASCStub.list(locs)))
            .on("GET", "/assetLibrary", .ok(ASCStub.single(ASCStub.res("appAssetLibraries", "lib1"))))
    }

    /// Upload pipeline routes: reserve → PUT → commit → place.
    static func uploads(_ router: StubRouter) -> StubRouter {
        let ops = #"[{"method":"PUT","url":"https://upload.example/1"}]"#
        let reserved = ASCStub.res("appAssetLibraryImages", "new-img", #"{"state":"AWAITING_UPLOAD","fileName":"a.png","fileSize":4,"uploadOperations":\#(ops)}"#)
        return router
            .on("POST", "/v1/appAssetLibraryImages", ASCStub.created(ASCStub.single(reserved)))
            .on("PUT", "upload.example/1", .ok(""))
            .on("PATCH", "/v1/appAssetLibraryImages/", .ok(ASCStub.single(image("new-img", state: "UPLOAD_COMPLETE"))))
            .on("POST", "/v1/appAssetLibraryPlacementOrderingRequests", ASCStub.created(ASCStub.single(ASCStub.res("appAssetLibraryPlacementOrderingRequests", "o1"))))
            .on("POST", "/v1/appAssetLibraryPlacements", ASCStub.created(ASCStub.single(placement("new-pl"))))
            .on("DELETE", "/v1/appAssetLibraryPlacements/", ASCStub.noContent)
    }

    static func screenshots(_ router: StubRouter, _ responses: [StubResponse]) -> StubRouter {
        router.on("GET", where: isScreenshotQuery, responses)
    }

    static func creative(_ router: StubRouter, _ responses: [StubResponse]) -> StubRouter {
        router.on("GET", where: isCreativeQuery, responses)
    }

    static func tree(_ root: URL, locale: String = "en-US", type: String, files: [String: String]) throws -> URL {
        let dir = root.appendingPathComponent(locale).appendingPathComponent(type)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }
}

@Suite("Apple Assets Commands Coverage", .serialized)
struct AppleAssetsCommandsCoverageTests {
    private let app = ["--app-id", "123"]

    @Test("assets types prints every slot")
    func types() async throws {
        let cmd: AppleAssetsTypesCommand = try CmdStub.parse(["apple", "assets", "types"])
        try await cmd.execute()
    }

    @Test("assets specs: all kinds, single kinds, slot filter, and invalid type")
    func specs() async throws {
        let refData = """
        {"type":"appAssetLibraryRefData","id":"ref1","attributes":{
          "displayClasses":[{"displayClassId":"IPHONE_DUO","deviceFamily":"IPHONE","screenDimensions":["1290x2796"]}],
          "placementTypes":[
            {"placementTypeId":"APP_SCREENSHOT","specMappings":[{"placementGroupId":"IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE","specs":["spec-1","spec-missing"]}]},
            {"placementTypeId":"IMESSAGE_APP_SCREENSHOT","specMappings":[{"placementGroupId":"IMESSAGE_X","specs":[]}]}
          ],
          "features":[{"featureId":"APP_STORE_VERSIONS","placementPolicies":[{"placementType":"APP_SCREENSHOT","groupLimits":[{"groupIds":["IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"],"maxCount":10}]}]}],
          "placementProfileGroups":[{"placementProfileGroupId":"IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE","platform":"IPHONE_APP_STORE","displayClassId":"IPHONE_DUO"}],
          "imageSpecs":[
            {"specId":"spec-1","aspectRatio":"9:19.5","dimensions":{"minWidth":1290,"maxWidth":1290,"minHeight":2796,"maxHeight":2796},"fileExtensions":["png"],"maxFileSize":1000,"alphaAllowed":false,"compatiblePlacementTypes":["APP_SCREENSHOT"]},
            {"specId":"spec-2","dimensions":{"minWidth":1,"maxWidth":2,"minHeight":3,"maxHeight":4},"fileExtensions":[],"alphaAllowed":true,"compatiblePlacementTypes":["PRODUCT_PAGE_HEADER_ASSET"]}
          ]
        }}
        """
        let router = StubRouter().on("GET", "/v1/appAssetLibraryRefData", .ok(ASCStub.list([refData])))
        try await CmdStub.apple(router, ["apple", "assets", "specs"], as: AppleAssetsSpecsCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "specs", "-t", "header"], as: AppleAssetsSpecsCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "specs", "-t", "search"], as: AppleAssetsSpecsCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "specs", "-t", "screenshots"], as: AppleAssetsSpecsCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "specs", "-t", "iphone-67"], as: AppleAssetsSpecsCommand.self)
        let empty = StubRouter().on("GET", "/v1/appAssetLibraryRefData", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "assets", "specs"], as: AppleAssetsSpecsCommand.self)
        await #expect(throws: ValidationError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "assets", "specs", "-t", "bogus-slot"], as: AppleAssetsSpecsCommand.self)
        }
    }

    @Test("assets list: grouped view, asset library view, locale filter, empty results")
    func list() async throws {
        let shots = ASCStub.list([
            AssetStub.placement("pl1", imageId: "img1"),
            AssetStub.placement("pl2", group: "UNKNOWN_GROUP"),
        ], included: [AssetStub.image("img1")])
        let creative = ASCStub.list([
            AssetStub.placement("ph", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil, imageId: "img2"),
            AssetStub.placement("ps", type: "APP_STORE_SEARCH_RESULTS_ASSET", group: nil),
        ], included: [AssetStub.image("img2")])
        let router = AssetStub.base()
        _ = AssetStub.creative(router, [.ok(creative)])
        _ = AssetStub.screenshots(router, [.ok(shots)])
        try await CmdStub.apple(router, ["apple", "assets", "list"] + app, as: AppleAssetsListCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "list", "--locale", "en-US", "-t", "iphone-67"] + app, as: AppleAssetsListCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "list", "-t", "header"] + app, as: AppleAssetsListCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "list", "--asset-library"] + app, as: AppleAssetsListCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "list", "--asset-library", "-t", "search"] + app, as: AppleAssetsListCommand.self)
        try await CmdStub.apple(router, ["apple", "assets", "list", "--asset-library", "-t", "iphone-67"] + app, as: AppleAssetsListCommand.self)

        let none = AssetStub.base()
        _ = AssetStub.creative(none, [.ok(ASCStub.list([]))])
        _ = AssetStub.screenshots(none, [.ok(ASCStub.list([]))])
        try await CmdStub.apple(none, ["apple", "assets", "list"] + app, as: AppleAssetsListCommand.self)

        let noLocs = AssetStub.base(locales: [])
        try await CmdStub.apple(noLocs, ["apple", "assets", "list"] + app, as: AppleAssetsListCommand.self)
        await #expect(throws: AppStoreServiceError.self) {
            try await CmdStub.apple(noLocs, ["apple", "assets", "list", "--app-version", "9.9"] + app, as: AppleAssetsListCommand.self)
        }
    }

    @Test("assets delete: validation, by id, dry run, and --all")
    func delete() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "assets", "delete", "--all", "--id", "x", "--locale", "en-US"] + app, as: AppleAssetsDeleteCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "assets", "delete", "--all"] + app, as: AppleAssetsDeleteCommand.self)
        }
        try await CmdStub.apple(StubRouter(), ["apple", "assets", "delete", "--id", "pl1", "--dry-run"] + app, as: AppleAssetsDeleteCommand.self)
        let byId = StubRouter().on("DELETE", "/v1/appAssetLibraryPlacements/pl1", ASCStub.noContent, ASCStub.notFound)
        try await CmdStub.apple(byId, ["apple", "assets", "delete", "--id", "pl1"] + app, as: AppleAssetsDeleteCommand.self)
        try await CmdStub.apple(byId, ["apple", "assets", "delete", "--id", "pl1"] + app, as: AppleAssetsDeleteCommand.self)
        #expect(CmdStub.count(byId, "DELETE", "/v1/appAssetLibraryPlacements/pl1") == 2)

        let shots = ASCStub.list([AssetStub.placement("pl1", imageId: "img1")], included: [AssetStub.image("img1")])
        let creative = ASCStub.list([AssetStub.placement("ph", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil)])
        let router = AssetStub.base()
            .on("DELETE", "/v1/appAssetLibraryPlacements/", ASCStub.noContent)
        _ = AssetStub.creative(router, [.ok(creative)])
        _ = AssetStub.screenshots(router, [.ok(shots)])
        try await CmdStub.apple(router, ["apple", "assets", "delete", "--all", "--locale", "en-US", "--dry-run"] + app, as: AppleAssetsDeleteCommand.self)
        #expect(CmdStub.count(router, "DELETE", "/v1/appAssetLibraryPlacements/") == 0)
        try await CmdStub.apple(router, ["apple", "assets", "delete", "--all", "--locale", "en-US"] + app, as: AppleAssetsDeleteCommand.self)
        #expect(CmdStub.count(router, "DELETE", "/v1/appAssetLibraryPlacements/") == 2)
        try await CmdStub.apple(router, ["apple", "assets", "delete", "--all", "--locale", "en-US", "-t", "search"] + app, as: AppleAssetsDeleteCommand.self)
        #expect(CmdStub.count(router, "DELETE", "/v1/appAssetLibraryPlacements/") == 2)
    }

    @Test("assets download: dry run, real download with manifests, and empty results")
    func download() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shots = ASCStub.list([
            AssetStub.placement("pl1", imageId: "img1"),
            AssetStub.placement("pl2", imageId: "img3"),
            AssetStub.placement("pl3", group: "UNKNOWN_GROUP"),
        ], included: [AssetStub.image("img1"), AssetStub.image("img3", fileName: "b.jpg", template: nil)])
        let creative = ASCStub.list([
            AssetStub.placement("ph", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil, imageId: "img2"),
            AssetStub.placement("ps", type: "APP_STORE_SEARCH_RESULTS_ASSET", group: nil),
        ], included: [AssetStub.image("img2", fileName: "header.png")])
        let router = AssetStub.base()
            .on("GET", "cdn.example", StubResponse(200, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), headers: ["Content-Type": "image/png"]))
        _ = AssetStub.creative(router, [.ok(creative)])
        _ = AssetStub.screenshots(router, [.ok(shots)])
        try await CmdStub.apple(router, ["apple", "assets", "download", "-o", dir.path, "--dry-run"] + app, as: AppleAssetsDownloadCommand.self)
        #expect(CmdStub.count(router, "GET", "cdn.example") == 0)
        try await CmdStub.apple(router, ["apple", "assets", "download", "-o", dir.path] + app, as: AppleAssetsDownloadCommand.self)
        #expect(CmdStub.count(router, "GET", "cdn.example") == 2)
        let shotDir = dir.appendingPathComponent("en-US/iphone-67")
        #expect(FileManager.default.fileExists(atPath: shotDir.appendingPathComponent(ScreenshotManifest.fileName).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("en-US/header/header.png").path))
        // Second run re-uses the folders (cleanup paths).
        try await CmdStub.apple(router, ["apple", "assets", "download", "-o", dir.path, "--locale", "en-US"] + app, as: AppleAssetsDownloadCommand.self)

        let none = AssetStub.base()
        _ = AssetStub.creative(none, [.ok(ASCStub.list([]))])
        _ = AssetStub.screenshots(none, [.ok(ASCStub.list([]))])
        try await CmdStub.apple(none, ["apple", "assets", "download", "-o", dir.path, "-t", "iphone-67"] + app, as: AppleAssetsDownloadCommand.self)
        let noLocs = AssetStub.base(locales: [])
        try await CmdStub.apple(noLocs, ["apple", "assets", "download", "-o", dir.path] + app, as: AppleAssetsDownloadCommand.self)

        let failing = AssetStub.base().on("GET", "cdn.example", .status(403, ""))
        _ = AssetStub.creative(failing, [.ok(ASCStub.list([]))])
        _ = AssetStub.screenshots(failing, [.ok(shots)])
        await #expect(throws: AppStoreServiceError.self) {
            try await CmdStub.apple(failing, ["apple", "assets", "download", "-o", dir.path, "-t", "iphone-67"] + app, as: AppleAssetsDownloadCommand.self)
        }
    }

    @Test("assets upload: validation errors")
    func uploadValidation() throws {
        let base = ["apple", "assets", "upload"] + app + CmdStub.appleCreds()
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(base + ["--sync", "--replace"], as: AppleAssetsUploadCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(base + ["--all-locales", "--sync"], as: AppleAssetsUploadCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(base + ["--all-locales", "--locale", "en-US", "-t", "header", "x.png"], as: AppleAssetsUploadCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(base + ["--all-locales", "-t", "iphone-67", "x.png"], as: AppleAssetsUploadCommand.self) }
        _ = try CmdStub.parse(base + ["--all-locales", "-t", "header", "x.png"], as: AppleAssetsUploadCommand.self)
    }

    @Test("assets upload: dry run, explicit files, replace, slot limits, and creative slots")
    func upload() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shotDir = try AssetStub.tree(dir, type: "iphone-67", files: ["1.png": "aaaa", "2.png": "bbbb"])
        _ = try AssetStub.tree(dir, type: "header", files: ["h.png": "hhhh"])

        // Dry run of the tree.
        try await CmdStub.apple(StubRouter(), ["apple", "assets", "upload", "--dry-run", "--app-version", "1.0", dir.path] + app, as: AppleAssetsUploadCommand.self)

        // Tree upload with --replace (writes manifests) and a header slot.
        let router = AssetStub.uploads(AssetStub.base())
        _ = AssetStub.creative(router, [.ok(ASCStub.list([AssetStub.placement("old-h", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil, imageId: "old")]))])
        _ = AssetStub.screenshots(router, [.ok(ASCStub.list([AssetStub.placement("old1")]))])
        try await CmdStub.apple(router, ["apple", "assets", "upload", "--replace", "--no-wait-processing", dir.path] + app, as: AppleAssetsUploadCommand.self)
        #expect(CmdStub.count(router, "PUT", "upload.example") == 3)
        #expect(CmdStub.has(router, "DELETE", "/v1/appAssetLibraryPlacements/old1"))
        #expect(CmdStub.has(router, "DELETE", "/v1/appAssetLibraryPlacements/old-h"))
        #expect(FileManager.default.fileExists(atPath: shotDir.appendingPathComponent(ScreenshotManifest.fileName).path))

        // Explicit file without --replace.
        let file = shotDir.appendingPathComponent("1.png").path
        let plain = AssetStub.uploads(AssetStub.base())
        _ = AssetStub.screenshots(plain, [.ok(ASCStub.list([]))])
        try await CmdStub.apple(plain, ["apple", "assets", "upload", "--locale", "en-US", "-t", "iphone-67", "--no-wait-processing", file] + app, as: AppleAssetsUploadCommand.self)
        #expect(CmdStub.count(plain, "POST", "/v1/appAssetLibraryPlacements") == 1)

        // Slot limit exceeded.
        let full = AssetStub.uploads(AssetStub.base())
        _ = AssetStub.screenshots(full, [.ok(ASCStub.list((1...10).map { AssetStub.placement("p\($0)") }))])
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(full, ["apple", "assets", "upload", "--locale", "en-US", "-t", "iphone-67", file] + app, as: AppleAssetsUploadCommand.self)
        }

        // Unknown locale.
        await #expect(throws: AppStoreServiceError.self) {
            try await CmdStub.apple(AssetStub.base(), ["apple", "assets", "upload", "--locale", "fr-FR", "-t", "iphone-67", file] + app, as: AppleAssetsUploadCommand.self)
        }

        // --all-locales header placement on every localization (create rejected once → replace path).
        let header = dir.appendingPathComponent("en-US/header/h.png").path
        let all = AssetStub.base(locales: ["en-US", "tr"])
        let ops = #"[{"method":"PUT","url":"https://upload.example/1"}]"#
        all.on("POST", "/v1/appAssetLibraryImages", ASCStub.created(ASCStub.single(ASCStub.res("appAssetLibraryImages", "new-img", #"{"state":"AWAITING_UPLOAD","uploadOperations":\#(ops)}"#))))
            .on("PUT", "upload.example/1", .ok(""))
            .on("PATCH", "/v1/appAssetLibraryImages/", .ok(ASCStub.single(AssetStub.image("new-img", state: "UPLOAD_COMPLETE"))))
            .on("POST", "/v1/appAssetLibraryPlacements", .status(409, ASCStub.errors(409)), ASCStub.created(ASCStub.single(AssetStub.placement("new-pl"))))
            .on("DELETE", "/v1/appAssetLibraryPlacements/", ASCStub.noContent)
        _ = AssetStub.creative(all, [.ok(ASCStub.list([AssetStub.placement("old-h", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil, imageId: "old")]))])
        try await CmdStub.apple(all, ["apple", "assets", "upload", "--all-locales", "-t", "header", "--no-wait-processing", header] + app, as: AppleAssetsUploadCommand.self)
        #expect(CmdStub.count(all, "PUT", "upload.example") == 1)

        // --sync requires a tree.
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "assets", "upload", "--sync", "--locale", "en-US", "-t", "iphone-67", file] + app, as: AppleAssetsUploadCommand.self)
        }
        // Too many header files.
        _ = try AssetStub.tree(dir, type: "search", files: ["a.png": "1", "b.png": "2"])
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "assets", "upload", "--dry-run", "-t", "search", dir.path] + app, as: AppleAssetsUploadCommand.self)
        }
    }

    @Test("assets upload --sync: dry run, bootstrap, unchanged, and manifest errors")
    func uploadSync() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try AssetStub.tree(dir, type: "iphone-67", files: ["1.png": "aaaa"])
        let headerDir = try AssetStub.tree(dir, type: "header", files: ["h.png": "hhhh"])

        // Dry run: header slot with a placed image but no manifest → abort.
        let blocked = AssetStub.base()
        _ = AssetStub.creative(blocked, [.ok(ASCStub.list([AssetStub.placement("old-h", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil, imageId: "old")]))])
        _ = AssetStub.screenshots(blocked, [.ok(ASCStub.list([]))])
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(blocked, ["apple", "assets", "upload", "--sync", "--dry-run", dir.path] + app, as: AppleAssetsUploadCommand.self)
        }

        // Bootstrap: both slots empty remotely.
        let router = AssetStub.uploads(AssetStub.base())
        _ = AssetStub.creative(router, [.ok(ASCStub.list([]))])
        _ = AssetStub.screenshots(router, [.ok(ASCStub.list([])), .ok(ASCStub.list([])), .ok(ASCStub.list([AssetStub.placement("other")]))])
        try await CmdStub.apple(router, ["apple", "assets", "upload", "--sync", "--dry-run", dir.path] + app, as: AppleAssetsUploadCommand.self)
        #expect(CmdStub.count(router, "PUT", "upload.example") == 0)
        try await CmdStub.apple(router, ["apple", "assets", "upload", "--sync", "--no-wait-processing", dir.path] + app, as: AppleAssetsUploadCommand.self)
        #expect(CmdStub.count(router, "PUT", "upload.example") == 2)
        #expect(FileManager.default.fileExists(atPath: headerDir.appendingPathComponent(ScreenshotManifest.fileName).path))

        // Header manifest now present and image still placed → no changes.
        let manifest = try #require(try ScreenshotManifest.load(from: headerDir))
        let unchanged = AssetStub.base()
        _ = AssetStub.creative(unchanged, [.ok(ASCStub.list([AssetStub.placement("cur", type: "PRODUCT_PAGE_HEADER_ASSET", group: nil, imageId: manifest.entries[0].remoteId)]))])
        try await CmdStub.apple(unchanged, ["apple", "assets", "upload", "--sync", "-t", "header", dir.path] + app, as: AppleAssetsUploadCommand.self)
        #expect(CmdStub.count(unchanged, "PUT", "upload.example") == 0)

        // Manifest for a different slot → abort.
        try ScreenshotManifest(store: "apple", locale: "en-US", type: "header", remoteSetId: "other/slot", entries: manifest.entries).write(to: headerDir)
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(unchanged, ["apple", "assets", "upload", "--sync", "-t", "header", dir.path] + app, as: AppleAssetsUploadCommand.self)
        }
    }
}

// MARK: - AppleScreenshotSyncTask

@Suite("Apple Screenshot Sync Task Coverage", .serialized)
struct AppleScreenshotSyncTaskCoverageTests {
    private func makeTask(files: [URL], dir: URL, dryRun: Bool = false, libraryId: String? = "lib1") throws -> AppleScreenshotSyncTask {
        let service = try AppStoreService(keyId: "KID", issuerId: "ISS", key: TestCredentials.appleKeyPEM())
        let version = try JSONDecoder().decode(Components.Schemas.AppStoreVersion.self, from: Data(AppleJSON.version().utf8))
        let localization = try JSONDecoder().decode(Components.Schemas.AppStoreVersionLocalization.self, from: Data(AppleJSON.localization().utf8))
        let slot = try AppleScreenshotSlot.parse("iphone-67")
        return AppleScreenshotSyncTask(
            service: service,
            version: version,
            assetLibraryId: libraryId,
            targets: [.init(localization: localization, batch: .init(locale: "en-US", type: slot, files: files))],
            waitProcessing: false,
            dryRun: dryRun
        )
    }

    private func manifest(_ dir: URL, entries: [(String, String, String)]) throws {
        try ScreenshotManifest(
            store: "apple", locale: "en-US", type: "iphone-67", versionId: "v1", versionString: "1.0",
            remoteSetId: "v1/en-US/\(AssetStub.group67)",
            entries: entries.map { .init(file: $0.0, remoteId: $0.1, sha256: $0.2) }
        ).write(to: dir)
    }

    @Test("sync keeps, replaces, adds, deletes, and reorders")
    func mixed() async throws {
        let root = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try AssetStub.tree(root, type: "iphone-67", files: ["1.png": "keep", "2.png": "changed", "3.png": "new"])
        let files = ["1.png", "2.png", "3.png"].map { dir.appendingPathComponent($0) }
        try manifest(dir, entries: [
            ("1.png", "r1", try ScreenshotManifest.sha256(of: files[0])),
            ("2.png", "r2", "stale"),
            ("gone.png", "r3", "x"),
        ])
        let router = AssetStub.uploads(StubRouter())
        _ = AssetStub.screenshots(router, [
            .ok(ASCStub.list([AssetStub.placement("r1"), AssetStub.placement("r2"), AssetStub.placement("r3"), AssetStub.placement("untracked")])),
            .ok(ASCStub.list([AssetStub.placement("untracked"), AssetStub.placement("r1")])),
        ])
        let summary = try await DefaultNetworkStub.with(router) { _ in
            try await makeTask(files: files, dir: dir).run()
        }
        #expect(summary.uploaded == 2)
        #expect(summary.deleted == 2)
        #expect(summary.reordered == 1)
        #expect(summary.setsChanged == 1)
        #expect(CmdStub.has(router, "DELETE", "/v1/appAssetLibraryPlacements/r3"))
        #expect(CmdStub.has(router, "DELETE", "/v1/appAssetLibraryPlacements/r2"))
        #expect(CmdStub.has(router, "POST", "/v1/appAssetLibraryPlacementOrderingRequests"))
    }

    @Test("sync dry run, no-op refresh, full slot replacement, and planning errors")
    func edgeCases() async throws {
        let root = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try AssetStub.tree(root, type: "iphone-67", files: ["1.png": "keep"])
        let file = dir.appendingPathComponent("1.png")
        let sha = try ScreenshotManifest.sha256(of: file)

        // Dry run (bootstrap on empty remote).
        let dry = StubRouter()
        _ = AssetStub.screenshots(dry, [.ok(ASCStub.list([]))])
        let drySummary = try await DefaultNetworkStub.with(dry) { _ in try await makeTask(files: [file], dir: dir, dryRun: true).run() }
        #expect(drySummary.uploaded == 0)

        // No-op: manifest matches remote.
        try manifest(dir, entries: [("1.png", "r1", sha)])
        let noop = StubRouter()
        _ = AssetStub.screenshots(noop, [.ok(ASCStub.list([AssetStub.placement("r1")]))])
        let noopSummary = try await DefaultNetworkStub.with(noop) { _ in try await makeTask(files: [file], dir: dir).run() }
        #expect(noopSummary.setsChanged == 0)

        // Full slot: changed file replaced by deleting first.
        try manifest(dir, entries: [("1.png", "r1", "stale")])
        let others = (2...10).map { AssetStub.placement("u\($0)") }
        let full = AssetStub.uploads(StubRouter())
        _ = AssetStub.screenshots(full, [.ok(ASCStub.list([AssetStub.placement("r1")] + others)), .ok(ASCStub.list([AssetStub.placement("new-pl")] + others))])
        let fullSummary = try await DefaultNetworkStub.with(full) { _ in try await makeTask(files: [file], dir: dir).run() }
        #expect(fullSummary.uploaded == 1)
        #expect(fullSummary.reordered == 0)

        // Missing asset library ID while an upload is needed.
        try manifest(dir, entries: [("1.png", "r1", "stale")])
        let noLib = StubRouter()
        _ = AssetStub.screenshots(noLib, [.ok(ASCStub.list([AssetStub.placement("r1")]))])
        await #expect(throws: CommandError.self) {
            try await DefaultNetworkStub.with(noLib) { _ in try await makeTask(files: [file], dir: dir, libraryId: nil).run() }
        }

        // Bootstrap refused because the remote slot already has screenshots.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(ScreenshotManifest.fileName))
        let refused = StubRouter()
        _ = AssetStub.screenshots(refused, [.ok(ASCStub.list([AssetStub.placement("r1")]))])
        await #expect(throws: CommandError.self) {
            try await DefaultNetworkStub.with(refused) { _ in try await makeTask(files: [file], dir: dir).run() }
        }
    }
}

// MARK: - Metadata

@Suite("Apple Metadata Commands Coverage", .serialized)
struct AppleMetadataCommandsCoverageTests {
    private let app = ["--app-id", "123"]

    private func router(versionState: String = "PREPARE_FOR_SUBMISSION", appInfoState: String = "PREPARE_FOR_SUBMISSION", review: Bool = true) -> StubRouter {
        let versionLoc = ASCStub.res("appStoreVersionLocalizations", "loc1", #"{"locale":"en-US","description":"Old description","keywords":"a,b","supportUrl":"https://s"}"#)
        let infoLoc = ASCStub.res("appInfoLocalizations", "il1", #"{"locale":"en-US","name":"App","subtitle":"Sub"}"#)
        let infoOnly = ASCStub.res("appInfoLocalizations", "il2", #"{"locale":"tr","name":"Uygulama"}"#)
        let r = StubRouter()
            .on("GET", "/apps/123/appStoreVersions", .ok(ASCStub.list([ASCStub.res("appStoreVersions", "v1", #"{"versionString":"1.0","appVersionState":"\#(versionState)","copyright":"2025 X"}"#)])))
            .on("GET", "/appStoreVersionLocalizations?", .ok(ASCStub.list([versionLoc])))
            .on("GET", "/apps/123/appInfos", .ok(ASCStub.list([ASCStub.res("appInfos", "ai1", #"{"state":"\#(appInfoState)"}"#)])))
            .on("GET", "/appInfoLocalizations", .ok(ASCStub.list([infoLoc, infoOnly])))
            .on("GET", "/v1/appInfos/ai1", .ok(ASCStub.single(ASCStub.res("appInfos", "ai1", "{}", rel: #"{"primaryCategory":{"data":{"type":"appCategories","id":"GAMES"}}}"#))))
            .on("GET", "/v1/appCategories", .ok(ASCStub.list([ASCStub.res("appCategories", "GAMES"), ASCStub.res("appCategories", "PRODUCTIVITY")])))
            .on("GET", "/v1/apps/123", .ok(ASCStub.single(ASCStub.res("apps", "123", #"{"contentRightsDeclaration":"DOES_NOT_USE_THIRD_PARTY_CONTENT"}"#))))
            .on("PATCH", "/v1/appStoreVersions/v1", .ok(ASCStub.single(ASCStub.res("appStoreVersions", "v1"))))
            .on("PATCH", "/v1/appInfos/ai1", .ok(ASCStub.single(ASCStub.res("appInfos", "ai1"))))
            .on("PATCH", "/v1/appStoreReviewDetails/", .ok(ASCStub.single(ASCStub.res("appStoreReviewDetails", "rd1"))))
            .on("POST", "/v1/appStoreReviewDetails", ASCStub.created(ASCStub.single(ASCStub.res("appStoreReviewDetails", "rd1"))))
            .on("PATCH", "/v1/apps/123", .ok(ASCStub.single(ASCStub.res("apps", "123"))))
            .on("PATCH", "/v1/appInfoLocalizations/", .ok(ASCStub.single(ASCStub.res("appInfoLocalizations", "il1"))))
            .on("PATCH", "/v1/appStoreVersionLocalizations/", .ok(ASCStub.single(ASCStub.res("appStoreVersionLocalizations", "loc1"))))
        if review {
            r.on("GET", "/appStoreReviewDetail", .ok(ASCStub.single(ASCStub.res("appStoreReviewDetails", "rd1", #"{"contactFirstName":"A","demoAccountRequired":false,"demoAccountPassword":"pw"}"#))))
        } else {
            r.on("GET", "/appStoreReviewDetail", ASCStub.notFound)
        }
        return r
    }

    @Test("metadata list shows app-level and per-locale fields")
    func list() async throws {
        let r = router()
        try await CmdStub.apple(r, ["apple", "metadata", "list"] + app, as: AppleMetadataListCommand.self)
        try await CmdStub.apple(r, ["apple", "metadata", "list", "--locale", "en-US"] + app, as: AppleMetadataListCommand.self)
        try await CmdStub.apple(r, ["apple", "metadata", "list", "--locale", "de-DE"] + app, as: AppleMetadataListCommand.self)
        #expect(CmdStub.has(r, "GET", "/appStoreReviewDetail"))
    }

    @Test("metadata download writes files, supports dry run and locale filter")
    func download() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = router()
        try await CmdStub.apple(r, ["apple", "metadata", "download", "-o", dir.path, "--dry-run"] + app, as: AppleMetadataDownloadCommand.self)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("en-US").path))
        try await CmdStub.apple(r, ["apple", "metadata", "download", "-o", dir.path] + app, as: AppleMetadataDownloadCommand.self)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("en-US/metadata/description.txt").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata/copyright.txt").path))
        try await CmdStub.apple(r, ["apple", "metadata", "download", "-o", dir.path, "--locale", "tr"] + app, as: AppleMetadataDownloadCommand.self)
        try await CmdStub.apple(r, ["apple", "metadata", "download", "-o", dir.path, "--locale", "xx"] + app, as: AppleMetadataDownloadCommand.self)
    }

    @Test("metadata upload: missing folders, no changes, dry run, and updates")
    func upload() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(router(), ["apple", "metadata", "upload", "--locale", "en-US", dir.path] + app, as: AppleMetadataUploadCommand.self)
        }
        try await CmdStub.apple(router(), ["apple", "metadata", "download", "-o", dir.path, "--locale", "en-US"] + app, as: AppleMetadataDownloadCommand.self)
        // No changes for the locale.
        let same = router()
        try await CmdStub.apple(same, ["apple", "metadata", "upload", "--locale", "en-US", dir.path] + app, as: AppleMetadataUploadCommand.self)
        #expect(same.log.requests.allSatisfy { $0.method == "GET" })

        // Locale changes (version + app info fields) and an unknown locale folder.
        let metaDir = dir.appendingPathComponent("en-US/metadata")
        try "New description".write(to: metaDir.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)
        try "New Name".write(to: metaDir.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        let unknownDir = dir.appendingPathComponent("de-DE/metadata")
        try FileManager.default.createDirectory(at: unknownDir, withIntermediateDirectories: true)
        try "Hallo".write(to: unknownDir.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)
        let dry = router()
        try await CmdStub.apple(dry, ["apple", "metadata", "upload", "--locale", "en-US", "--dry-run", dir.path] + app, as: AppleMetadataUploadCommand.self)
        #expect(dry.log.requests.allSatisfy { $0.method == "GET" })
        let real = router()
        try await CmdStub.apple(real, ["apple", "metadata", "upload", "--locale", "en-US", dir.path] + app, as: AppleMetadataUploadCommand.self)
        #expect(CmdStub.has(real, "PATCH", "/v1/appStoreVersionLocalizations/loc1"))
        #expect(CmdStub.has(real, "PATCH", "/v1/appInfoLocalizations/il1"))

        // Live version: description changes are refused.
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(router(versionState: "READY_FOR_DISTRIBUTION", appInfoState: "READY_FOR_DISTRIBUTION"), ["apple", "metadata", "upload", "--locale", "en-US", dir.path] + app, as: AppleMetadataUploadCommand.self)
        }
    }

    @Test("metadata upload of app-level fields: copyright, categories, review details, and app values")
    func uploadAppLevel() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try "2026 Y".write(to: store.appendingPathComponent("copyright.txt"), atomically: true, encoding: .utf8)
        try "PRODUCTIVITY".write(to: store.appendingPathComponent("primary_category.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: store.appendingPathComponent("review_contact_first_name.txt"), atomically: true, encoding: .utf8)
        try "https://a11y".write(to: store.appendingPathComponent("accessibility_url.txt"), atomically: true, encoding: .utf8)
        let real = router()
        try await CmdStub.apple(real, ["apple", "metadata", "upload", dir.path] + app, as: AppleMetadataUploadCommand.self)
        #expect(CmdStub.has(real, "PATCH", "/v1/appStoreVersions/v1"))
        #expect(CmdStub.has(real, "PATCH", "/v1/appInfos/ai1"))
        #expect(CmdStub.has(real, "PATCH", "/v1/appStoreReviewDetails/rd1"))
        #expect(CmdStub.has(real, "PATCH", "/v1/apps/123"))

        let create = router(review: false)
        try await CmdStub.apple(create, ["apple", "metadata", "upload", dir.path] + app, as: AppleMetadataUploadCommand.self)
        #expect(CmdStub.has(create, "POST", "/v1/appStoreReviewDetails"))

        try "NOT_A_CATEGORY".write(to: store.appendingPathComponent("primary_category.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(router(), ["apple", "metadata", "upload", dir.path] + app, as: AppleMetadataUploadCommand.self)
        }
    }
}
