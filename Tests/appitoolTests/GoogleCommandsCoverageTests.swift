import ArgumentParser
import Foundation
import Testing
@testable import appitool
import GoogleServices

// MARK: - Google Play router helpers (default transport → route by URL)

enum PlayStub {
    static let pkg = ["--package-name", "com.example.app"]
    static let account = ["--account-id", "123"]
    static let noContent = StubResponse(204, Data(), headers: [:])

    /// Edit lifecycle routes (insert → … → commit / validate / delete).
    static func edits(_ r: StubRouter = StubRouter()) -> StubRouter {
        r.on("POST", ":commit", .ok(#"{"id":"e1"}"#))
            .on("POST", ":validate", .ok(#"{"id":"e1"}"#))
            .on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok(#"{"id":"e1"}"#)])
            .on("DELETE", where: { $0.path.hasSuffix("/edits/e1") }, [noContent])
    }

    static func phoneImages(_ r: StubRouter, _ responses: [StubResponse]) -> StubRouter {
        r.on("GET", where: { $0.path.hasSuffix("/phoneScreenshots") }, responses)
            .on("GET", where: { $0.path.contains("/listings/") }, [.ok("{}")])
    }

    static func listings(_ r: StubRouter, _ json: String = #"{"listings":[{"language":"en-US","title":"T","shortDescription":"S","fullDescription":"F"}]}"#) -> StubRouter {
        r.on("GET", where: { $0.path.hasSuffix("/listings") }, [.ok(json)])
    }

    static func image(_ id: String, sha: String) -> String {
        #"{"id":"\#(id)","url":"https://lh3.googleusercontent.com/\#(id)","sha1":"x","sha256":"\#(sha)"}"#
    }

    static func tree(_ root: URL, locale: String = "en-US", type: String = "phone", files: [String: String]) throws -> URL {
        let dir = root.appendingPathComponent(locale).appendingPathComponent(type)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files { try Data(content.utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }
}

// MARK: - Apps, signing certs, users

@Suite("Google Commands Coverage", .serialized)
struct GoogleCommandsCoverageTests {
    @Test("apps list: filter, limit, hint mapping, empty, and API errors")
    func appsList() async throws {
        let router = StubRouter().on("GET", "apps:search", .ok(#"{"apps":[{"name":"apps/b","packageName":"com.b","displayName":"Beta"},{"name":"apps/a","packageName":"com.a","displayName":"Alpha"},{"packageName":"com.c"}]}"#))
        try await CmdStub.google(router, ["google", "apps", "list", "-l", "2"], as: GoogleListAppsCommand.self)
        try await CmdStub.google(router, ["google", "apps", "list", "-n", "zzz"], as: GoogleListAppsCommand.self)
        let apps = [GooglePlayAccessibleApp(name: "1", packageName: "com.b", displayName: "Beta"), GooglePlayAccessibleApp(name: "2", packageName: "com.a", displayName: "alpha")]
        #expect(GoogleListAppsCommand.filter(apps, name: nil, limit: nil).map(\.packageName) == ["com.a", "com.b"])
        #expect(GoogleListAppsCommand.filter(apps, name: "BET", limit: nil).map(\.packageName) == ["com.b"])
        #expect(GoogleListAppsCommand.filter(apps, name: nil, limit: -1).isEmpty)
        #expect(GoogleListAppsCommand.hint(for: .apiError(status: 403, message: "")) != nil)
        #expect(GoogleListAppsCommand.hint(for: .apiError(status: 401, message: "")) != nil)
        #expect(GoogleListAppsCommand.hint(for: .apiError(status: 500, message: "")) == nil)
        #expect(GoogleListAppsCommand.hint(for: .invalidResponse("x")) == nil)
        let failing = StubRouter().on("GET", "apps:search", .status(403, #"{"error":{"message":"disabled"}}"#))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(failing, ["google", "apps", "list"], as: GoogleListAppsCommand.self)
        }
    }

    @Test("signing-certs: API mode with and without APK download, latest version code, and local file errors")
    func signingCerts() async throws {
        let list = #"{"generatedApks":[{"certificateSha256Hash":"aa","generatedUniversalApk":{"downloadId":"u"}},{"certificateSha256Hash":"bb"}]}"#
        let router = StubRouter()
            .on("GET", ":download", StubResponse(200, Data([9, 9]), headers: ["Content-Type": "application/octet-stream"]))
            .on("GET", "/generatedApks/7", .ok(list))
        try await CmdStub.google(router, ["google", "signing-certs", "list", "--version-code", "7", "--sha256-only"] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)
        try await CmdStub.google(router, ["google", "signing-certs", "list", "--version-code", "7"] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)
        #expect(CmdStub.has(router, "GET", ":download"))

        let latest = PlayStub.edits(StubRouter())
            .on("GET", "/tracks", .ok(#"{"tracks":[{"track":"internal","releases":[{"status":"completed","versionCodes":["7"]}]}]}"#))
            .on("GET", "/generatedApks/7", .ok(list))
        try await CmdStub.google(latest, ["google", "signing-certs", "list", "--sha256-only"] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)

        let empty = StubRouter().on("GET", "/generatedApks/7", .ok("{}"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(empty, ["google", "signing-certs", "list", "--version-code", "7"] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)
        }

        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["google", "signing-certs", "list", "-f", dir.appendingPathComponent("missing.der").path] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["google", "signing-certs", "list", "-f", dir.path] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)
        }
        let bogus = dir.appendingPathComponent("bad.der")
        try Data([1, 2, 3]).write(to: bogus)
        #expect(try GoogleSigningCertsCommand.certificateFiles([dir.path]).map(\.lastPathComponent) == ["bad.der"])
        await #expect(throws: (any Error).self) {
            try await CmdStub.google(StubRouter(), ["google", "signing-certs", "list", "-f", bogus.path] + PlayStub.pkg, as: GoogleSigningCertsCommand.self)
        }
        #expect(GoogleSigningCertsCommand.colonHex("") == "-")
        #expect(GoogleSigningCertsCommand.colonHex("abcde") == "ab:cd:e")
    }

    @Test("user support helpers: permissions, expiration, hints")
    func userSupport() throws {
        #expect(try GoogleUserSupport.permissions(nil, developerLevel: true) == nil)
        #expect(throws: ValidationError.self) { try GoogleUserSupport.permissions("not-a-permission", developerLevel: true) }
        #expect(try GoogleUserSupport.expiration(nil) == nil)
        #expect(throws: ValidationError.self) { try GoogleUserSupport.expiration("tomorrow") }
        #expect(throws: ValidationError.self) { try GoogleUserSupport.expiration("2001-01-01T00:00:00Z") }
        #expect(try GoogleUserSupport.expiration("2999-01-01T00:00:00Z") == "2999-01-01T00:00:00Z")
        #expect(GoogleUserSupport.displayPermission("CAN_SEE_ALL_APPS") == "can-see-all-apps")
        for status in [401, 404, 409] {
            #expect(GoogleUserSupport.hint(for: GooglePlayImageError.apiError(status: status, message: "")) != nil)
        }
        #expect(GoogleUserSupport.hint(for: GooglePlayImageError.apiError(status: 500, message: "")) == nil)
        #expect(GoogleUserSupport.hint(for: CommandError("x")) == nil)
    }

    private func usersRouter() -> StubRouter {
        StubRouter()
            .on("GET", "/developers/123/users", .ok(#"{"users":[{"email":"a@b.c","accessState":"ACCESS_GRANTED","developerAccountPermissions":["CAN_SEE_ALL_APPS"],"expirationTime":"2030-01-01T00:00:00Z","grants":[{"packageName":"com.example.app","appLevelPermissions":["CAN_ACCESS_APP"]}]},{"email":"i@n.v","accessState":"INVITED"}]}"#))
            .on("POST", "/grants", .ok(#"{"packageName":"com.example.app","appLevelPermissions":["CAN_ACCESS_APP"]}"#))
            .on("PATCH", "/grants/", .ok(#"{"appLevelPermissions":["CAN_REPLY_TO_REVIEWS"]}"#))
            .on("DELETE", "/grants/", .ok("{}"))
            .on("POST", "/developers/123/users", .ok(#"{"email":"n@e.w","accessState":"INVITED"}"#))
            .on("PATCH", "/users/", .ok(#"{"email":"a@b.c"}"#))
            .on("DELETE", "/users/", .ok("{}"))
    }

    @Test("users and invitations: list, invite, update, delete, grant, revoke, cancel")
    func users() async throws {
        let r = usersRouter()
        let acct = PlayStub.account
        try await CmdStub.google(r, ["google", "users", "list", "-l", "5"] + acct, as: GoogleListUsersCommand.self)
        try await CmdStub.google(r, ["google", "users", "list", "-e", "nobody@x.y"] + acct, as: GoogleListUsersCommand.self)
        try await CmdStub.google(r, ["google", "invitations", "list"] + acct, as: GoogleListInvitationsCommand.self)
        try await CmdStub.google(r, ["google", "invitations", "list", "-e", "nobody@x.y"] + acct, as: GoogleListInvitationsCommand.self)

        try await CmdStub.google(r, ["google", "users", "invite", "-e", "n@e.w", "--permissions", "can-see-all-apps", "--app-permissions", "can-access-app", "--expiration", "2999-01-01T00:00:00Z"] + PlayStub.pkg + acct, as: GoogleInviteUserCommand.self)
        #expect(CmdStub.has(r, "POST", "/grants"))
        try await CmdStub.google(r, ["google", "users", "update", "-e", "a@b.c", "--permissions", "can-see-all-apps"] + acct, as: GoogleUpdateUserCommand.self)
        try await CmdStub.google(r, ["google", "users", "delete", "-e", "a@b.c"] + acct, as: GoogleDeleteUserCommand.self)
        try await CmdStub.google(r, ["google", "users", "grant", "-e", "a@b.c", "--permissions", "can-reply-to-reviews"] + PlayStub.pkg + acct, as: GoogleGrantAccessCommand.self)
        #expect(CmdStub.has(r, "PATCH", "/grants/"))
        try await CmdStub.google(r, ["google", "users", "grant", "-e", "i@n.v", "--permissions", "can-access-app"] + PlayStub.pkg + acct, as: GoogleGrantAccessCommand.self)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["google", "users", "grant", "-e", "x@y.z", "--permissions", "can-access-app"] + PlayStub.pkg + acct, as: GoogleGrantAccessCommand.self)
        }
        try await CmdStub.google(r, ["google", "users", "revoke", "-e", "a@b.c"] + PlayStub.pkg + acct, as: GoogleRevokeAccessCommand.self)
        #expect(CmdStub.has(r, "DELETE", "/grants/"))

        try await CmdStub.google(r, ["google", "invitations", "cancel", "-e", "i@n.v"] + acct, as: GoogleCancelInvitationCommand.self)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["google", "invitations", "cancel", "-e", "a@b.c"] + acct, as: GoogleCancelInvitationCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["google", "invitations", "cancel", "-e", "x@y.z"] + acct, as: GoogleCancelInvitationCommand.self)
        }

        let failing = StubRouter().on("GET", "/users", .status(403, #"{"error":{"message":"no access"}}"#))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(failing, ["google", "users", "list"] + acct, as: GoogleListUsersCommand.self)
        }
    }

    @Test("user command validation")
    func userValidation() throws {
        let creds = CmdStub.googleCreds() + PlayStub.account
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["google", "users", "invite", "-e", "a@b.c"] + creds, as: GoogleInviteUserCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["google", "users", "invite", "-e", "a@b.c", "--app-permissions", "can-access-app"] + creds, as: GoogleInviteUserCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["google", "users", "invite", "-e", "a@b.c", "--permissions", "can-see-all-apps", "--package-name", "com.a"] + creds, as: GoogleInviteUserCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["google", "users", "update", "-e", "a@b.c"] + creds, as: GoogleUpdateUserCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["google", "users", "grant", "-e", "a@b.c", "--permissions", "bogus"] + creds, as: GoogleGrantAccessCommand.self) }
    }
}

// MARK: - Assets & metadata

@Suite("Google Assets Commands Coverage", .serialized)
struct GoogleAssetsCommandsCoverageTests {
    private let pkg = PlayStub.pkg

    @Test("assets types and list")
    func list() async throws {
        let types: GoogleAssetsTypesCommand = try CmdStub.parse(["google", "assets", "types"])
        try await types.execute()

        let r = PlayStub.listings(PlayStub.phoneImages(PlayStub.edits(), [.ok(#"{"images":[\#(PlayStub.image("i1", sha: "abcdef0123456789")),{"id":"i2"}]}"#)]))
        try await CmdStub.google(r, ["google", "assets", "list"] + pkg, as: GoogleAssetsListCommand.self)
        try await CmdStub.google(r, ["google", "assets", "list", "--locale", "en-US", "-t", "phone"] + pkg, as: GoogleAssetsListCommand.self)
        let empty = PlayStub.listings(PlayStub.phoneImages(PlayStub.edits(), [.ok("{}")]))
        try await CmdStub.google(empty, ["google", "assets", "list", "-t", "icon"] + pkg, as: GoogleAssetsListCommand.self)
    }

    @Test("assets download: dry run, files with manifest, skipped images, empty")
    func download() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = #"{"images":[\#(PlayStub.image("i1", sha: "s1")),{"id":"i2","sha256":"s2"}]}"#
        let r = PlayStub.listings(PlayStub.phoneImages(PlayStub.edits(), [.ok(images)]))
            .on("GET", "googleusercontent.com", StubResponse(200, Data([0x89, 0x50, 0x4E, 0x47]), headers: ["Content-Type": "image/png"]))
        try await CmdStub.google(r, ["google", "assets", "download", "-o", dir.path, "--dry-run"] + pkg, as: GoogleAssetsDownloadCommand.self)
        #expect(CmdStub.count(r, "GET", "googleusercontent.com") == 0)
        try await CmdStub.google(r, ["google", "assets", "download", "-o", dir.path] + pkg, as: GoogleAssetsDownloadCommand.self)
        #expect(CmdStub.count(r, "GET", "googleusercontent.com") == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("en-US/phone/\(ScreenshotManifest.fileName)").path))
        try await CmdStub.google(r, ["google", "assets", "download", "-o", dir.path, "--locale", "en-US", "-t", "phone"] + pkg, as: GoogleAssetsDownloadCommand.self)
        let empty = PlayStub.listings(PlayStub.phoneImages(PlayStub.edits(), [.ok("{}")]))
        try await CmdStub.google(empty, ["google", "assets", "download", "-o", dir.path] + pkg, as: GoogleAssetsDownloadCommand.self)
    }

    @Test("assets delete: validation, dry run, by id, and all")
    func delete() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["google", "assets", "delete", "--locale", " ", "-t", "phone", "--all"] + pkg, as: GoogleAssetsDeleteCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--all", "--id", "i1"] + pkg, as: GoogleAssetsDeleteCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["google", "assets", "delete", "--locale", "en-US", "-t", "phone"] + pkg, as: GoogleAssetsDeleteCommand.self)
        }
        let images = #"{"images":[\#(PlayStub.image("i1", sha: "s1"))]}"#
        let r = PlayStub.phoneImages(PlayStub.edits(), [.ok(images)])
            .on("DELETE", where: { $0.path.hasSuffix("/phoneScreenshots") }, [.ok(#"{"deleted":[{"id":"i1"}]}"#)])
            .on("DELETE", where: { $0.path.contains("/phoneScreenshots/") }, [StubResponse(200, Data())])
        try await CmdStub.google(r, ["google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--all", "--dry-run"] + pkg, as: GoogleAssetsDeleteCommand.self)
        try await CmdStub.google(r, ["google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--id", "nope", "--dry-run"] + pkg, as: GoogleAssetsDeleteCommand.self)
        try await CmdStub.google(r, ["google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--id", "i1", "--changes-not-sent-for-review"] + pkg, as: GoogleAssetsDeleteCommand.self)
        try await CmdStub.google(r, ["google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--all"] + pkg, as: GoogleAssetsDeleteCommand.self)
        #expect(CmdStub.count(r, "POST", ":commit") == 2)
    }

    @Test("assets upload: validation, dry run, replace with manifest, validate-only")
    func upload() async throws {
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["google", "assets", "upload", "--sync", "--replace"] + pkg + CmdStub.googleCreds(), as: GoogleAssetsUploadCommand.self) }
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let phoneDir = try PlayStub.tree(dir, files: ["1.png": "one", "2.png": "two"])
        try await CmdStub.google(StubRouter(), ["google", "assets", "upload", "--dry-run", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)

        let r = PlayStub.edits()
            .on("DELETE", where: { $0.path.hasSuffix("/phoneScreenshots") }, [.ok(#"{"deleted":[{"id":"old"}]}"#)])
            .on("POST", "/upload/androidpublisher", .ok(#"{"image":{"id":"n1","sha256":"a1"}}"#), .ok(#"{"image":{"id":"n2","sha256":"a2"}}"#))
        try await CmdStub.google(r, ["google", "assets", "upload", "--replace", "--changes-not-sent-for-review", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)
        #expect(CmdStub.count(r, "POST", "/upload/androidpublisher") == 2)
        #expect(FileManager.default.fileExists(atPath: phoneDir.appendingPathComponent(ScreenshotManifest.fileName).path))

        try await CmdStub.google(r, ["google", "assets", "upload", "--validate-only", "--locale", "en-US", phoneDir.appendingPathComponent("1.png").path] + pkg, as: GoogleAssetsUploadCommand.self)
        #expect(CmdStub.has(r, "POST", ":validate"))

        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["google", "assets", "upload", "--sync", "--locale", "en-US", phoneDir.appendingPathComponent("1.png").path] + pkg, as: GoogleAssetsUploadCommand.self)
        }
    }

    @Test("assets upload --sync drives GooglePlayImageSyncTask: dry run, bootstrap, no changes, validate-only, and errors")
    func uploadSync() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let phoneDir = try PlayStub.tree(dir, files: ["1.png": "one", "2.png": "two"])
        func router(_ remote: [StubResponse]) -> StubRouter {
            PlayStub.phoneImages(PlayStub.edits(), remote)
                .on("DELETE", where: { $0.path.contains("/phoneScreenshots/") }, [StubResponse(200, Data())])
                .on("POST", "/upload/androidpublisher", .ok(#"{"image":{"id":"n1","sha256":"a1"}}"#), .ok(#"{"image":{"id":"n2","sha256":"a2"}}"#))
        }
        // Dry run (bootstrap on empty slot).
        let dry = router([.ok("{}")])
        try await CmdStub.google(dry, ["google", "assets", "upload", "--sync", "--dry-run", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)
        #expect(CmdStub.count(dry, "POST", "/upload/androidpublisher") == 0)

        // Bootstrap commit.
        let boot = router([.ok("{}")])
        try await CmdStub.google(boot, ["google", "assets", "upload", "--sync", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)
        #expect(CmdStub.count(boot, "POST", "/upload/androidpublisher") == 2)
        #expect(CmdStub.has(boot, "POST", ":commit"))
        let manifest = try #require(try ScreenshotManifest.load(from: phoneDir))
        #expect(manifest.entries.map(\.remoteId) == ["n1", "n2"])

        // No changes: remote matches the manifest.
        let remote = #"{"images":[{"id":"n1","sha256":"a1"},{"id":"n2","sha256":"a2"}]}"#
        let same = router([.ok(remote)])
        try await CmdStub.google(same, ["google", "assets", "upload", "--sync", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)
        #expect(CmdStub.count(same, "POST", "/upload/androidpublisher") == 0)

        // Edited file → validate-only edit (manifest not rewritten).
        try Data("changed".utf8).write(to: phoneDir.appendingPathComponent("2.png"))
        let edited = router([.ok(remote)])
        try await CmdStub.google(edited, ["google", "assets", "upload", "--sync", "--validate-only", "--changes-not-sent-for-review", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)
        #expect(CmdStub.has(edited, "POST", ":validate"))
        #expect(CmdStub.count(edited, "POST", "/upload/androidpublisher") >= 1)

        // Too few phone screenshots → planning error.
        try FileManager.default.removeItem(at: phoneDir.appendingPathComponent("2.png"))
        try FileManager.default.removeItem(at: phoneDir.appendingPathComponent(ScreenshotManifest.fileName))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(router([.ok("{}")]), ["google", "assets", "upload", "--sync", dir.path] + pkg, as: GoogleAssetsUploadCommand.self)
        }
    }

    @Test("metadata list, download, and upload")
    func metadata() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func router() -> StubRouter {
            PlayStub.listings(PlayStub.edits())
                .on("GET", where: { $0.path.hasSuffix("/details") }, [.ok(#"{"contactEmail":"a@b.c","contactWebsite":"https://w","defaultLanguage":"en-US"}"#)])
                .on("PATCH", where: { $0.path.hasSuffix("/details") }, [.ok("{}")])
                .on("PATCH", "/listings/", .ok(#"{"language":"en-US"}"#))
        }
        let r = router()
        try await CmdStub.google(r, ["google", "metadata", "list"] + pkg, as: GoogleMetadataListCommand.self)
        try await CmdStub.google(r, ["google", "metadata", "list", "--locale", "xx"] + pkg, as: GoogleMetadataListCommand.self)
        try await CmdStub.google(r, ["google", "metadata", "download", "-o", dir.path, "--dry-run"] + pkg, as: GoogleMetadataDownloadCommand.self)
        try await CmdStub.google(r, ["google", "metadata", "download", "-o", dir.path, "--locale", "xx"] + pkg, as: GoogleMetadataDownloadCommand.self)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(router(), ["google", "metadata", "upload", dir.path] + pkg, as: GoogleMetadataUploadCommand.self)
        }
        try await CmdStub.google(r, ["google", "metadata", "download", "-o", dir.path] + pkg, as: GoogleMetadataDownloadCommand.self)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("en-US/metadata/title.txt").path))

        let unchanged = router()
        try await CmdStub.google(unchanged, ["google", "metadata", "upload", dir.path] + pkg, as: GoogleMetadataUploadCommand.self)
        #expect(!CmdStub.has(unchanged, "POST", ":commit"))

        try "New title".write(to: dir.appendingPathComponent("en-US/metadata/title.txt"), atomically: true, encoding: .utf8)
        try "b@c.d".write(to: dir.appendingPathComponent("metadata/contact_email.txt"), atomically: true, encoding: .utf8)
        let unknown = dir.appendingPathComponent("de-DE/metadata")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try "Titel".write(to: unknown.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        let dry = router()
        try await CmdStub.google(dry, ["google", "metadata", "upload", "--dry-run", dir.path] + pkg, as: GoogleMetadataUploadCommand.self)
        #expect(!CmdStub.has(dry, "POST", ":commit"))
        let real = router()
        try await CmdStub.google(real, ["google", "metadata", "upload", dir.path] + pkg, as: GoogleMetadataUploadCommand.self)
        #expect(CmdStub.has(real, "PATCH", "/listings/en-US"))
        #expect(CmdStub.has(real, "POST", ":commit"))
        let validate = router()
        try await CmdStub.google(validate, ["google", "metadata", "upload", "--validate-only", "--changes-not-sent-for-review", "--locale", "en-US", dir.path] + pkg, as: GoogleMetadataUploadCommand.self)
        #expect(CmdStub.has(validate, "POST", ":validate"))

        try String(repeating: "x", count: 100).write(to: dir.appendingPathComponent("en-US/metadata/title.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(router(), ["google", "metadata", "upload", "--locale", "en-US", dir.path] + pkg, as: GoogleMetadataUploadCommand.self)
        }
        let listing = GoogleMetadataUploadCommand.listingChanges(language: "en-US", changes: [])
        #expect(listing.title == nil)
    }
}
