import ArgumentParser
import Foundation
import Testing
@testable import appitool
@testable import GoogleServices

private let project = ["--project", "test-project"]
private let androidAppId = "1:123:android:abc"

@Suite("Firebase Commands Coverage", .serialized)
struct FirebaseCommandsCoverageTests {
    private let apps = #"{"apps":[{"appId":"1:123:ios:a","platform":"IOS","namespace":"com.a","displayName":"iOS"},{"appId":"1:123:android:abc","platform":"ANDROID","namespace":"com.example.app"},{"appId":"1:123:web:w","platform":"WEB","displayName":"Web"},{"appId":"1:123:android:old","platform":"ANDROID","namespace":"com.gone","state":"DELETED"},{"appId":"x","platform":"OTHER"}]}"#

    // MARK: Apps

    @Test("apps list groups by platform, filters, and maps errors")
    func appsList() async throws {
        let r = StubRouter().on("GET", ":searchApps", .ok(apps))
        try await CmdStub.google(r, ["firebase", "apps", "list", "--show-deleted"] + project, as: FirebaseListAppsCommand.self)
        try await CmdStub.google(r, ["firebase", "apps", "list", "-p", "web"] + project, as: FirebaseListAppsCommand.self)
        let empty = StubRouter().on("GET", ":searchApps", .ok("{}"))
        try await CmdStub.google(empty, ["firebase", "apps", "list"] + project, as: FirebaseListAppsCommand.self)
        let failing = StubRouter().on("GET", ":searchApps", .status(403, #"{"error":{"message":"denied"}}"#))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(failing, ["firebase", "apps", "list"] + project, as: FirebaseListAppsCommand.self)
        }
        #expect(FirebaseAppSupport.hint(for: FirebaseAppsError(status: 404, message: "")) != nil)
        #expect(FirebaseAppSupport.hint(for: FirebaseAppsError(status: 409, message: "")) != nil)
        #expect(FirebaseAppSupport.hint(for: FirebaseAppsError(status: 500, message: "")) == nil)
        #expect(FirebaseAppSupport.appIdEnvVar(for: "IOS") == "FIREBASE_IOS_APP_ID")
        #expect(FirebaseAppSupport.appIdEnvVar(for: "WEB") == nil)
        #expect(FirebaseAppSupport.label(.sha1).contains("SHA-1"))
        #expect(FirebaseAppSupport.label(.unspecified).contains("SHA"))
    }

    @Test("apps create: existing app, new app, API failure, and validation")
    func appsCreate() async throws {
        let r = StubRouter()
            .on("GET", ":searchApps", .ok(apps))
            .on("POST", "/androidApps", .ok(#"{"name":"operations/x","done":true,"response":{"appId":"1:123:android:new","packageName":"com.new"}}"#))
            .on("POST", "/webApps", .status(409, #"{"error":{"message":"exists"}}"#))
        try await CmdStub.google(r, ["firebase", "apps", "create", "-p", "android", "--package-name", "com.example.app"] + project, as: FirebaseAddAppCommand.self)
        #expect(!CmdStub.has(r, "POST", "/androidApps"))
        try await CmdStub.google(r, ["firebase", "apps", "create", "-p", "android", "--package-name", "com.new", "--sha1", String(repeating: "a", count: 40)] + project, as: FirebaseAddAppCommand.self)
        #expect(CmdStub.has(r, "POST", "/androidApps"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["firebase", "apps", "create", "-p", "web", "-n", "Site"] + project, as: FirebaseAddAppCommand.self)
        }
        let failing = StubRouter().on("GET", ":searchApps", .status(404, "{}"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(failing, ["firebase", "apps", "create", "-p", "ios", "-b", "com.a"] + project, as: FirebaseAddAppCommand.self)
        }
        let creds = CmdStub.googleCreds() + project
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "create", "-p", "android", "-b", "com.a"] + creds, as: FirebaseAddAppCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "create", "-p", "ios", "--package-name", "com.a"] + creds, as: FirebaseAddAppCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "create", "-p", "web"] + creds, as: FirebaseAddAppCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "create", "-p", "android", "--package-name", "com.a", "--sha256", "zz"] + creds, as: FirebaseAddAppCommand.self) }
    }

    @Test("apps delete: lookup by id and identifier, dry run, failures, and validation")
    func appsDelete() async throws {
        let r = StubRouter()
            .on("GET", ":searchApps", .ok(apps))
            .on("POST", ":remove", .ok(#"{"name":"operations/r","done":true}"#))
        try await CmdStub.google(r, ["firebase", "apps", "delete", "--firebase-app-id", androidAppId, "--dry-run"] + project, as: FirebaseDeleteAppCommand.self)
        try await CmdStub.google(r, ["firebase", "apps", "delete", "-p", "ios", "-b", "com.a", "--immediate"] + project, as: FirebaseDeleteAppCommand.self)
        try await CmdStub.google(r, ["firebase", "apps", "delete", "-p", "web", "-n", "Web"] + project, as: FirebaseDeleteAppCommand.self)
        #expect(CmdStub.count(r, "POST", ":remove") == 3)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["firebase", "apps", "delete", "--firebase-app-id", "x"] + project, as: FirebaseDeleteAppCommand.self)
        }
        let failing = StubRouter().on("GET", ":searchApps", .ok(apps)).on("POST", ":remove", .status(403, "{}"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(failing, ["firebase", "apps", "delete", "--firebase-app-id", androidAppId] + project, as: FirebaseDeleteAppCommand.self)
        }
        let listFail = StubRouter().on("GET", ":searchApps", .status(500, "{}"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(listFail, ["firebase", "apps", "delete", "--firebase-app-id", androidAppId] + project, as: FirebaseDeleteAppCommand.self)
        }

        let summaries = [
            FirebaseAppSummary(appId: "a1", displayName: nil, platform: "ANDROID", namespace: "com.dup", state: nil),
            FirebaseAppSummary(appId: "a2", displayName: nil, platform: "ANDROID", namespace: "com.dup", state: nil),
        ]
        #expect(throws: CommandError.self) { try FirebaseDeleteAppCommand.findApp(in: summaries, appId: nil, platform: .android, identifier: "com.dup", displayName: nil) }
        #expect(throws: CommandError.self) { try FirebaseDeleteAppCommand.findApp(in: summaries, appId: nil, platform: .android, identifier: "com.none", displayName: nil) }
        #expect(throws: CommandError.self) { try FirebaseDeleteAppCommand.findApp(in: summaries, appId: "zz", platform: nil, identifier: nil, displayName: nil) }

        let creds = CmdStub.googleCreds() + project
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "delete", "--firebase-app-id", "a", "-p", "ios"] + creds, as: FirebaseDeleteAppCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "delete"] + creds, as: FirebaseDeleteAppCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "apps", "delete", "-p", "ios", "--package-name", "com.a"] + creds, as: FirebaseDeleteAppCommand.self) }
    }

    @Test("fingerprints sync: explicit hashes, Play keys, replace, dry run, and errors")
    func fingerprints() async throws {
        let sha1 = String(repeating: "a", count: 40)
        let sha256 = String(repeating: "b", count: 64)
        let registered = #"{"certificates":[{"name":"projects/p/androidApps/a/sha/1","shaHash":"\#(sha1)","certType":"SHA_1"},{"name":"projects/p/androidApps/a/sha/2","shaHash":"cccc","certType":"SHA_1"}]}"#
        func router() -> StubRouter {
            StubRouter()
                .on("GET", ":searchApps", .ok(apps))
                .on("GET", "/sha", .ok(registered))
                .on("POST", "/sha", .ok("{}"))
                .on("DELETE", "/sha/", .ok("{}"))
                .on("GET", ":download", .status(404, #"{"error":{"message":"gone"}}"#))
                .on("GET", "/generatedApks/7", .ok(#"{"generatedApks":[{"certificateSha256Hash":"dd","generatedUniversalApk":{"downloadId":"u"}}]}"#))
        }
        let dry = router()
        try await CmdStub.google(dry, ["firebase", "fingerprints", "sync", "--no-play", "--firebase-app-id", androidAppId, "--sha1", sha1, "--sha256", sha256, "--replace", "--dry-run"] + project, as: FirebaseSyncFingerprintsCommand.self)
        #expect(!CmdStub.has(dry, "POST", "/sha"))
        let real = router()
        try await CmdStub.google(real, ["firebase", "fingerprints", "sync", "--no-play", "--firebase-app-id", androidAppId, "--sha256", sha256, "--replace"] + project, as: FirebaseSyncFingerprintsCommand.self)
        #expect(CmdStub.has(real, "POST", "/sha"))
        #expect(CmdStub.count(real, "DELETE", "/sha/") == 2)
        let unchanged = router()
        try await CmdStub.google(unchanged, ["firebase", "fingerprints", "sync", "--no-play", "--firebase-app-id", androidAppId, "--sha1", sha1] + project, as: FirebaseSyncFingerprintsCommand.self)
        #expect(!CmdStub.has(unchanged, "POST", "/sha"))

        let play = router()
        try await CmdStub.google(play, ["firebase", "fingerprints", "sync", "--firebase-app-id", androidAppId, "--package-name", "com.example.app", "--version-code", "7"] + project, as: FirebaseSyncFingerprintsCommand.self)
        #expect(CmdStub.has(play, "GET", "/generatedApks/7"))
        #expect(CmdStub.has(play, "POST", "/sha"))

        // App lookup by package name (env-independent: called directly).
        let lookup = router()
        try await DefaultNetworkStub.firebase(lookup) { service in
            let id = try await FirebaseAppSupport.resolveAndroidAppId(explicit: nil, packageName: "com.example.app", project: "test-project", service: service)
            #expect(id == androidAppId)
            #expect(try await FirebaseAppSupport.resolveAndroidAppId(explicit: "given", packageName: nil, project: "p", service: service) == "given")
            await #expect(throws: CommandError.self) {
                _ = try await FirebaseAppSupport.resolveAndroidAppId(explicit: nil, packageName: "com.none", project: "p", service: service)
            }
            await #expect(throws: ValidationError.self) {
                _ = try await FirebaseAppSupport.resolveAndroidAppId(explicit: nil, packageName: nil, project: "p", service: service)
            }
        }
        let listFail = StubRouter().on("GET", ":searchApps", .status(403, "{}"))
        await #expect(throws: CommandError.self) {
            try await DefaultNetworkStub.firebase(listFail) { service in
                _ = try await FirebaseAppSupport.resolveAndroidAppId(explicit: nil, packageName: "com.a", project: "p", service: service)
            }
        }
        let shaFail = StubRouter().on("GET", "/sha", .status(403, "{}"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(shaFail, ["firebase", "fingerprints", "sync", "--no-play", "--firebase-app-id", androidAppId, "--sha1", sha1] + project, as: FirebaseSyncFingerprintsCommand.self)
        }
        let addFail = StubRouter().on("GET", "/sha", .ok("{}")).on("POST", "/sha", .status(400, "{}"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(addFail, ["firebase", "fingerprints", "sync", "--no-play", "--firebase-app-id", androidAppId, "--sha1", sha1] + project, as: FirebaseSyncFingerprintsCommand.self)
        }
        let creds = CmdStub.googleCreds() + project
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["firebase", "fingerprints", "sync", "--no-play"] + creds, as: FirebaseSyncFingerprintsCommand.self) }
        let plan = FirebaseSyncFingerprintsCommand.plan(
            desired: [.init(hash: "AA:BB", type: .sha1, source: "x"), .init(hash: "aabb", type: .sha1, source: "dup")],
            registered: [],
            replace: true
        )
        #expect(plan.add.count == 1)
    }

    // MARK: Groups & releases

    @Test("groups list and create")
    func groups() async throws {
        let r = StubRouter()
            .on("GET", "/groups/qa", .ok(#"{"name":"projects/123/groups/qa","displayName":"QA"}"#))
            .on("GET", "/groups", .ok(#"{"groups":[{"name":"projects/123/groups/qa","displayName":"QA","testerCount":3,"releaseCount":1},{}]}"#))
        try await CmdStub.google(r, ["firebase", "groups", "list", "-l", "1"] + project, as: FirebaseListGroupsCommand.self)
        try await CmdStub.google(r, ["firebase", "groups", "list"] + project, as: FirebaseListGroupsCommand.self)
        try await CmdStub.google(r, ["firebase", "groups", "create", "--alias", "qa", "-n", "QA"] + project, as: FirebaseCreateGroupCommand.self)
        let empty = StubRouter().on("GET", "/groups", .ok("{}"))
        try await CmdStub.google(empty, ["firebase", "groups", "list"] + project, as: FirebaseListGroupsCommand.self)
    }

    @Test("releases list, create, and update")
    func releases() async throws {
        let release = #"{"name":"projects/123/apps/\#(androidAppId)/releases/r1","displayVersion":"1.0","buildVersion":"7","createTime":"2026-01-01T10:00:00Z","releaseNotes":{"text":"line1\nline2"},"firebaseConsoleUri":"https://console","binaryDownloadUri":"https://bin"}"#
        let app = ["--firebase-app-id", androidAppId] + project
        let list = StubRouter().on("GET", "/releases", .ok(#"{"releases":[\#(release),{"createTime":"not-a-date"},{}]}"#))
        try await CmdStub.google(list, ["firebase", "releases", "list", "-l", "5", "--order-by", "createTime desc"] + app, as: FirebaseListReleasesCommand.self)
        let empty = StubRouter().on("GET", "/releases", .ok("{}"))
        try await CmdStub.google(empty, ["firebase", "releases", "list"] + app, as: FirebaseListReleasesCommand.self)

        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let apk = dir.appendingPathComponent("app.apk")
        try Data("binary".utf8).write(to: apk)
        let create = StubRouter()
            .on("POST", "releases:upload", .ok(#"{"name":"projects/123/apps/x/releases/-/operations/op1"}"#))
            .on("GET", "operations/op1", .ok(#"{"done":true,"response":{"release":\#(release)}}"#))
            .on("GET", "/groups/qa", .ok(#"{"name":"projects/123/groups/qa","displayName":"QA"}"#))
            .on("PATCH", "/releases/r1", .ok("{}"))
            .on("POST", ":distribute", .ok("{}"))
        try await CmdStub.google(create, ["firebase", "releases", "create", "--binary", apk.path, "--release-notes", "n", "--test-groups", "qa", "--tester-emails", "a@b.c"] + app, as: FirebaseCreateReleaseCommand.self)
        #expect(CmdStub.has(create, "POST", ":distribute"))

        let update = StubRouter().on("PATCH", "/releases/r1", .ok("{}")).on("POST", ":distribute", .ok("{}"))
        try await CmdStub.google(update, ["firebase", "releases", "update", "--release-id", "r1", "--release-notes", "n", "--test-groups", "qa"] + app, as: FirebaseUpdateReleaseCommand.self)
        try await CmdStub.google(update, ["firebase", "releases", "update", "--release-id", "projects/123/apps/\(androidAppId)/releases/r1", "--tester-emails", "a@b.c"] + app, as: FirebaseUpdateReleaseCommand.self)
        try await CmdStub.google(update, ["firebase", "releases", "update", "--release-id", "r1"] + app, as: FirebaseUpdateReleaseCommand.self)
        #expect(CmdStub.count(update, "POST", ":distribute") == 2)
    }

    // MARK: Auth users

    private func authRouter() -> StubRouter {
        StubRouter()
            .on("GET", "accounts:batchGet",
                .ok(#"{"users":[{"localId":"u1","email":"a@b.c","emailVerified":true,"displayName":"A, \"Q\"","createdAt":"1700000000000","lastLoginAt":"1700000000000","providerUserInfo":[{"providerId":"password","email":"a@b.c"}]},{"localId":"anon1"}],"nextPageToken":"p2"}"#),
                .ok(#"{"users":[{"localId":"u2","phoneNumber":"+1","disabled":true},{"localId":"u3","displayName":"Nameless","email":""},{"localId":"anon2"}]}"#))
            .on("POST", "accounts:lookup", .ok(#"{"users":[{"localId":"u1","email":"a@b.c"}]}"#))
            .on("POST", "accounts:batchDelete", .ok("{}"))
            .on("POST", "accounts:delete", .ok("{}"))
    }

    @Test("users list: listing, search fast path, anonymous filters, page tokens, empty")
    func usersList() async throws {
        try await CmdStub.google(authRouter(), ["firebase", "users", "list", "-l", "10"] + project, as: FirebaseListUsersCommand.self)
        try await CmdStub.google(authRouter(), ["firebase", "users", "list", "-l", "1"] + project, as: FirebaseListUsersCommand.self)
        try await CmdStub.google(authRouter(), ["firebase", "users", "list", "--search", "a@b.c"] + project, as: FirebaseListUsersCommand.self)
        try await CmdStub.google(authRouter(), ["firebase", "users", "list", "--search", "u2"] + project, as: FirebaseListUsersCommand.self)
        try await CmdStub.google(authRouter(), ["firebase", "users", "list", "--anonymous", "only", "--page-token", "p2"] + project, as: FirebaseListUsersCommand.self)
        try await CmdStub.google(authRouter(), ["firebase", "users", "list", "--anonymous", "exclude", "--page-token", " "] + project, as: FirebaseListUsersCommand.self)
        let empty = StubRouter().on("GET", "accounts:batchGet", .ok("{}")).on("POST", "accounts:lookup", .ok("{}"))
        try await CmdStub.google(empty, ["firebase", "users", "list", "--search", "zzz"] + project, as: FirebaseListUsersCommand.self)
    }

    @Test("users delete: validation, by uid, by email, anonymous (dry run, success, errors)")
    func usersDelete() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["firebase", "users", "delete", "--anonymous", "--uid", "u1"] + project, as: FirebaseDeleteUserCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(StubRouter(), ["firebase", "users", "delete"] + project, as: FirebaseDeleteUserCommand.self)
        }
        let r = authRouter()
        try await CmdStub.google(r, ["firebase", "users", "delete", "--uid", "u1", "--dry-run"] + project, as: FirebaseDeleteUserCommand.self)
        try await CmdStub.google(r, ["firebase", "users", "delete", "--uid", "u1"] + project, as: FirebaseDeleteUserCommand.self)
        try await CmdStub.google(r, ["firebase", "users", "delete", "-e", "a@b.c"] + project, as: FirebaseDeleteUserCommand.self)
        #expect(CmdStub.count(r, "POST", "accounts:delete") == 2)
        let noMatch = StubRouter().on("POST", "accounts:lookup", .ok("{}"))
        try await CmdStub.google(noMatch, ["firebase", "users", "delete", "-e", "x@y.z"] + project, as: FirebaseDeleteUserCommand.self)

        try await CmdStub.google(authRouter(), ["firebase", "users", "delete", "--anonymous", "--dry-run"] + project, as: FirebaseDeleteUserCommand.self)
        let anon = authRouter()
        try await CmdStub.google(anon, ["firebase", "users", "delete", "--anonymous"] + project, as: FirebaseDeleteUserCommand.self)
        #expect(CmdStub.has(anon, "POST", "accounts:batchDelete"))
        let none = StubRouter().on("GET", "accounts:batchGet", .ok(#"{"users":[{"localId":"u1","email":"a@b.c"}]}"#))
        try await CmdStub.google(none, ["firebase", "users", "delete", "--anonymous"] + project, as: FirebaseDeleteUserCommand.self)
        let partial = authRouter()
        partial.on("POST", "accounts:batchDelete", .ok(#"{"errors":[{"index":0,"message":"boom"}]}"#))
        let failing = StubRouter()
            .on("GET", "accounts:batchGet", .ok(#"{"users":[{"localId":"anon1"},{"localId":"anon2"}]}"#))
            .on("POST", "accounts:batchDelete", .ok(#"{"errors":[{"index":0,"message":"boom"}]}"#))
        await #expect(throws: ExitCode.self) {
            try await CmdStub.google(failing, ["firebase", "users", "delete", "--anonymous"] + project, as: FirebaseDeleteUserCommand.self)
        }
    }

    @Test("users export writes CSV with filters")
    func usersExport() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("users.csv")
        try await CmdStub.google(authRouter(), ["firebase", "users", "export", "-o", out.path] + project, as: FirebaseExportUsersCommand.self)
        let csv = try String(contentsOf: out, encoding: .utf8)
        #expect(csv.contains("u1,a@b.c,true"))
        #expect(csv.contains("\"A, \"\"Q\"\"\""))
        try await CmdStub.google(authRouter(), ["firebase", "users", "export", "-o", out.path, "--anonymous", "only"] + project, as: FirebaseExportUsersCommand.self)
        #expect(try String(contentsOf: out, encoding: .utf8).contains("anon1"))
        try await CmdStub.google(authRouter(), ["firebase", "users", "export", "-o", out.path, "--anonymous", "exclude"] + project, as: FirebaseExportUsersCommand.self)
        #expect(!(try String(contentsOf: out, encoding: .utf8)).contains("anon1"))
    }
}

// MARK: - Firestore

@Suite("Firestore Commands Coverage", .serialized)
struct FirestoreCommandsCoverageTests {
    private let doc = #"{"name":"projects/test-project/databases/(default)/documents/users/u1","fields":{"role":{"stringValue":"admin"},"age":{"integerValue":"3"}},"createTime":"2026-01-01T00:00:00Z","updateTime":"2026-01-02T00:00:00Z"}"#

    @Test("collections, list, get, query in text and JSON modes")
    func reads() async throws {
        let r = StubRouter()
            .on("POST", ":listCollectionIds", .ok(#"{"collectionIds":["users","orders"],"nextPageToken":"n"}"#))
            .on("POST", ":runQuery", .ok(#"[{"document":\#(doc)},{"readTime":"t"}]"#))
            .on("GET", "/documents/users/u1", .ok(doc))
            .on("GET", "/documents/users/ghost", .status(404, "{}"))
            .on("GET", "/documents/users", .ok(#"{"documents":[\#(doc)],"nextPageToken":"n2"}"#))
        try await CmdStub.google(r, ["firebase", "firestore", "collections"] + project, as: FirestoreCollectionsCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "collections", "users/u1", "--json", "--page-token", "t"] + project, as: FirestoreCollectionsCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "list", "users", "--order-by", "age desc"] + project, as: FirestoreListCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "list", "users", "--json"] + project, as: FirestoreListCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "get", "users/u1"] + project, as: FirestoreGetCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "get", "users/u1", "--json", "--database", " "] + project, as: FirestoreGetCommand.self)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["firebase", "firestore", "get", "users/ghost"] + project, as: FirestoreGetCommand.self)
        }
        try await CmdStub.google(r, ["firebase", "firestore", "query", "users", "-w", "role == admin", "--order-by", "age desc", "--all-descendants"] + project, as: FirestoreQueryCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "query", "users", "--json"] + project, as: FirestoreQueryCommand.self)

        let empty = StubRouter()
            .on("POST", ":listCollectionIds", .ok("{}"))
            .on("POST", ":runQuery", .ok("[]"))
            .on("GET", "/documents/users", .ok("{}"))
        try await CmdStub.google(empty, ["firebase", "firestore", "collections"] + project, as: FirestoreCollectionsCommand.self)
        try await CmdStub.google(empty, ["firebase", "firestore", "list", "users"] + project, as: FirestoreListCommand.self)
        try await CmdStub.google(empty, ["firebase", "firestore", "query", "users"] + project, as: FirestoreQueryCommand.self)
    }

    @Test("set from data or file, delete with dry run, and validation errors")
    func writes() async throws {
        let r = StubRouter()
            .on("PATCH", "/documents/users/u1", .ok(doc))
            .on("GET", "/documents/users/u1", .ok(doc))
            .on("GET", "/documents/users/ghost", .status(404, "{}"))
            .on("DELETE", "/documents/users/u1", .ok("{}"))
        try await CmdStub.google(r, ["firebase", "firestore", "set", "users/u1", "--data", #"{"role":"admin"}"#, "--merge"] + project, as: FirestoreSetCommand.self)
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.json")
        try Data(#"{"age":3}"#.utf8).write(to: file)
        try await CmdStub.google(r, ["firebase", "firestore", "set", "users/u1", "-f", file.path, "--json"] + project, as: FirestoreSetCommand.self)
        #expect(CmdStub.count(r, "PATCH", "/documents/users/u1") == 2)
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["firebase", "firestore", "set", "users/u1"] + project, as: FirestoreSetCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["firebase", "firestore", "set", "users/u1", "-f", dir.appendingPathComponent("missing.json").path] + project, as: FirestoreSetCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.google(r, ["firebase", "firestore", "set", "users/u1", "--data", "[1,2]"] + project, as: FirestoreSetCommand.self)
        }

        try await CmdStub.google(r, ["firebase", "firestore", "delete", "users/u1", "--dry-run"] + project, as: FirestoreDeleteCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "delete", "users/ghost", "--dry-run"] + project, as: FirestoreDeleteCommand.self)
        try await CmdStub.google(r, ["firebase", "firestore", "delete", "users/u1"] + project, as: FirestoreDeleteCommand.self)
        #expect(CmdStub.count(r, "DELETE", "/documents/users/u1") == 1)
        await #expect(throws: FirestoreServiceError.self) {
            try await CmdStub.google(r, ["firebase", "firestore", "delete", "users"] + project, as: FirestoreDeleteCommand.self)
        }
    }
}
