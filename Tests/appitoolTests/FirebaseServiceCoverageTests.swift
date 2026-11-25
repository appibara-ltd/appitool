import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import appitool
@testable import GoogleServices
import AppleServices

/// Runs `body` with every default transport/session (store services, notifications, self-update) pointed at the stub
/// router, so services and commands that build their own clients never reach the real network.
enum DefaultNetworkStub {
    static func with<T>(_ router: StubRouter, _ body: (URLSession) async throws -> T) async throws -> T {
        try await HTTPStub.withSession(router) { session in
            let transport = StubTransport(router)
            let saved = (
                AppStoreService.defaultTransport, AppStoreService.defaultURLSession,
                GooglePlayService.defaultTransport, GooglePlayService.defaultURLSession,
                FirebaseService.defaultTransport, FirebaseService.defaultURLSession,
                HTTPDefaults.urlSession
            )
            AppStoreService.defaultTransport = transport
            AppStoreService.defaultURLSession = session
            GooglePlayService.defaultTransport = transport
            GooglePlayService.defaultURLSession = session
            FirebaseService.defaultTransport = transport
            FirebaseService.defaultURLSession = session
            HTTPDefaults.urlSession = session
            defer {
                AppStoreService.defaultTransport = saved.0
                AppStoreService.defaultURLSession = saved.1
                GooglePlayService.defaultTransport = saved.2
                GooglePlayService.defaultURLSession = saved.3
                FirebaseService.defaultTransport = saved.4
                FirebaseService.defaultURLSession = saved.5
                HTTPDefaults.urlSession = saved.6
            }
            return try await body(session)
        }
    }

    static func firebase<T>(_ router: StubRouter, _ body: (FirebaseService) async throws -> T) async throws -> T {
        HTTPStub.googleTokenRoute(router)
        return try await with(router) { session in
            let service = try FirebaseService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport(router), urlSession: session)
            return try await body(service)
        }
    }
}

private struct NoTokenMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await next(request, body, baseURL)
    }
}

private func nsError(_ error: any Error) -> NSError { error as NSError }

@Suite("FirebaseService Coverage Tests")
struct FirebaseServiceCoverageTests {
    private let appId = "1:1234567890:ios:abcdef"
    private let releaseName = "projects/1234567890/apps/1:1234567890:ios:abcdef/releases/r1"
    private let releaseJSON = #"{"name":"projects/1234567890/apps/1:1234567890:ios:abcdef/releases/r1","displayVersion":"1.0","buildVersion":"7","releaseNotes":{"text":"notes"},"firebaseConsoleUri":"https://console"}"#

    // MARK: - Construction

    @Test("Custom middleware without token support throws on token retrieval and has no project ID")
    func customMiddleware() async throws {
        let service = try FirebaseService(authMiddleware: NoTokenMiddleware(), transport: StubTransport())
        #expect(service.serviceAccountProjectId == nil)
        await #expect(throws: NSError.self) { _ = try await service.getAccessToken() }
        let keyed = try FirebaseService(key: TestCredentials.serviceAccountJSON(projectId: "proj-x"), transport: StubTransport())
        #expect(keyed.serviceAccountProjectId == "proj-x")
    }

    @Test("Management client requests unescape multi-segment resource paths")
    func managementPathUnescape() async throws {
        let router = StubRouter().on("GET", "firebase.projects.iosApps.get", .ok(#"{"appId":"1:1:ios:a","bundleId":"com.a"}"#))
        try await DefaultNetworkStub.firebase(router) { service in
            _ = try await service.management.firebase_period_projects_period_iosApps_period_get(.init(path: .init(projectsId: "a/b", iosAppId: "1:1:ios:a")))
        }
        let request = try #require(router.log.first { $0.operationID == "firebase.projects.iosApps.get" })
        #expect(request.url.absoluteString.contains("projects/a/b/iosApps/"))
        #expect(!request.url.absoluteString.contains("%2F"))
    }

    @Test("Service account keys without a token URI fall back to the default endpoint")
    func defaultTokenURI() throws {
        let json = TestCredentials.serviceAccountJSON()
        let stripped = json.components(separatedBy: "\n").filter { !$0.contains("token_uri") }.joined(separator: "\n")
        let fixed = stripped.replacingOccurrences(of: "\"client_id\": \"1\",", with: "\"client_id\": \"1\"")
        #expect(try GooglePlayAuthMiddleware.parseServiceAccount(from: fixed).tokenUri == nil)
        _ = try GooglePlayAuthMiddleware(key: fixed)
    }

    @Test("makeService returns nil without a key and a service with one")
    func makeService() throws {
        #expect(try FirebaseService.makeService(googleKey: nil) == nil)
        #expect(try FirebaseService.makeService(googleKey: "") == nil)
        #expect(try FirebaseService.makeService(googleKey: TestCredentials.serviceAccountJSON()) != nil)
        #expect(try GooglePlayService.makeService(googleKey: nil) == nil)
        #expect(try GooglePlayService.makeService(googleKey: TestCredentials.serviceAccountJSON()) != nil)
    }

    @Test("Model initializers keep their values and anonymous users are detected")
    func models() throws {
        let release = FirebaseAppDistributionRelease(name: "n", releaseNotes: .init(text: "t"), displayVersion: "1", buildVersion: "2", createTime: "c", firebaseConsoleUri: "f", testingUri: "u", binaryDownloadUri: "b")
        #expect(release.releaseNotes?.text == "t")
        #expect(release.binaryDownloadUri == "b")
        let group = FirebaseAppDistributionGroup(name: "g", displayName: "G", testerCount: 1, releaseCount: 2, inviteLinkCount: 3)
        #expect(group.inviteLinkCount == 3)

        let anon = try JSONDecoder().decode(FirebaseAuthUser.self, from: Data(#"{"localId":"u1"}"#.utf8))
        #expect(anon.isAnonymous)
        let withEmail = try JSONDecoder().decode(FirebaseAuthUser.self, from: Data(#"{"localId":"u2","email":"a@b.c"}"#.utf8))
        #expect(!withEmail.isAnonymous)
        let withProvider = try JSONDecoder().decode(FirebaseAuthUser.self, from: Data(#"{"localId":"u3","providerUserInfo":[{"providerId":"google.com"}]}"#.utf8))
        #expect(!withProvider.isAnonymous)
        let withPhone = try JSONDecoder().decode(FirebaseAuthUser.self, from: Data(#"{"localId":"u4","phoneNumber":"+1"}"#.utf8))
        #expect(!withPhone.isAnonymous)
    }

    // MARK: - Upload & Operation Polling

    @Test("upload posts the binary and returns the processed release")
    func uploadSuccess() async throws {
        let dir = try TestFiles.makeTempDir()
        let file = dir.appendingPathComponent("app.ipa")
        try Data("binary".utf8).write(to: file)
        let router = StubRouter()
            .on("POST", "releases:upload", .ok(#"{"name":"projects/1234567890/apps/x/releases/-/operations/op1"}"#))
            .on("GET", "operations/op1", .ok(#"{"done":true,"response":{"release":\#(releaseJSON)}}"#))
        let release = try await DefaultNetworkStub.firebase(router) { try await $0.upload(fileUrl: file, firebaseAppId: appId) }
        #expect(release.displayVersion == "1.0")
        let upload = try #require(router.log.first { $0.path.hasSuffix("releases:upload") })
        #expect(upload.path.contains("/upload/v1/projects/1234567890/apps/1:1234567890:ios:abcdef/"))
        #expect(upload.headers["X-Goog-Upload-File-Name"] == "app.ipa")
        #expect(upload.headers["Authorization"] == "Bearer test-token")
    }

    @Test("upload surfaces HTTP failures and unparseable operation responses")
    func uploadFailures() async throws {
        let dir = try TestFiles.makeTempDir()
        let file = dir.appendingPathComponent("app.apk")
        try Data("binary".utf8).write(to: file)

        let failing = StubRouter().on("POST", "releases:upload", .status(500, "boom"))
        let error = await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.upload(fileUrl: file, firebaseAppId: "bad-id") }
        }
        #expect(error?.code == 500)
        #expect(failing.log.first { $0.path.contains("releases:upload") }?.path.contains("projects/-/apps/bad-id") == true)

        let noName = StubRouter().on("POST", "releases:upload", .ok(#"{"foo":1}"#))
        let parseError = await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(noName) { try await $0.upload(fileUrl: file, firebaseAppId: appId) }
        }
        #expect(parseError?.code == 3)
    }

    @Test("waitForRelease handles errors, missing releases, bad JSON, HTTP failures, and timeouts")
    func waitForReleaseBranches() async throws {
        func run(_ responses: StubResponse..., retries: Int = 3) async throws -> FirebaseAppDistributionRelease {
            let router = StubRouter().on(where: { $0.path.contains("operations/op") }, responses)
            return try await DefaultNetworkStub.firebase(router) {
                try await $0.waitForRelease(operationName: "operations/op", maxRetries: retries, delaySeconds: 0)
            }
        }

        let polled = try await run(.ok(#"{"done":false}"#), .ok(#"{"done":true,"response":{"release":{"name":"r"}}}"#))
        #expect(polled.name == "r")

        let failed = await #expect(throws: NSError.self) { try await run(.ok(#"{"done":true,"error":{"message":"bad build"}}"#)) }
        #expect(failed?.code == 7)
        #expect(failed?.localizedDescription.contains("bad build") == true)

        let missing = await #expect(throws: NSError.self) { try await run(.ok(#"{"done":true,"response":{}}"#)) }
        #expect(missing?.code == 8)

        let badJSON = await #expect(throws: NSError.self) { try await run(.ok("[1,2]")) }
        #expect(badJSON?.code == 6)

        let http = await #expect(throws: NSError.self) { try await run(.status(403, "denied")) }
        #expect(http?.code == 403)

        let timeout = await #expect(throws: NSError.self) { try await run(.ok(#"{"done":false}"#), retries: 2) }
        #expect(timeout?.localizedDescription.contains("Timed out") == true)
    }

    // MARK: - Releases

    @Test("listReleases sends paging and ordering parameters and decodes releases")
    func listReleases() async throws {
        let router = StubRouter().on("GET", "/releases", .ok(#"{"releases":[\#(releaseJSON)],"nextPageToken":"n2"}"#))
        let result = try await DefaultNetworkStub.firebase(router) {
            try await $0.listReleases(firebaseAppId: appId, pageSize: 5, pageToken: "p1", orderBy: "createTime desc")
        }
        #expect(result.releases.count == 1)
        #expect(result.nextPageToken == "n2")
        let request = try #require(router.log.first { $0.path.hasSuffix("/releases") })
        #expect(request.query.contains("pageSize=5"))
        #expect(request.query.contains("pageToken=p1"))
        #expect(request.query.contains("orderBy=createTime"))

        let empty = StubRouter().on("GET", "/releases", .ok("{}"))
        let none = try await DefaultNetworkStub.firebase(empty) { try await $0.listReleases(firebaseAppId: "x") }
        #expect(none.releases.isEmpty)
        #expect(empty.log.first { $0.path.hasSuffix("/releases") }?.query == "")

        let failing = StubRouter().on("GET", "/releases", .status(500, "err"))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.listReleases(firebaseAppId: appId) }
        }
    }

    @Test("getRelease decodes the release and surfaces HTTP errors")
    func getRelease() async throws {
        let router = StubRouter().on("GET", "/releases/r1", .ok(releaseJSON))
        let release = try await DefaultNetworkStub.firebase(router) { try await $0.getRelease(releaseName: releaseName) }
        #expect(release.buildVersion == "7")

        let failing = StubRouter().on("GET", "/releases/r1", .status(404, "nope"))
        let error = await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.getRelease(releaseName: releaseName) }
        }
        #expect(error?.code == 404)
    }

    @Test("addReleaseNotes patches release notes text and surfaces HTTP errors")
    func addReleaseNotes() async throws {
        let router = StubRouter().on("PATCH", "/releases/r1", .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { try await $0.addReleaseNotes(releaseName: releaseName, releaseNotes: "Hello") }
        let request = try #require(router.log.first { $0.method == "PATCH" })
        #expect(request.query == "updateMask=releaseNotes.text")
        #expect((request.json()["releaseNotes"] as? [String: Any])?["text"] as? String == "Hello")

        let failing = StubRouter().on("PATCH", "/releases/r1", .status(400, "bad"))
        let error = await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.addReleaseNotes(releaseName: releaseName, releaseNotes: "x") }
        }
        #expect(error?.code == 400)
    }

    @Test("distribute sends groups and testers only when present")
    func distribute() async throws {
        let router = StubRouter().on("POST", ":distribute", .ok("{}"))
        try await DefaultNetworkStub.firebase(router) {
            try await $0.distribute(releaseName: releaseName, groupAliases: ["qa"], testerEmails: ["a@b.c"])
            try await $0.distribute(releaseName: releaseName, groupAliases: [], testerEmails: nil)
        }
        let requests = router.log.requests.filter { $0.path.hasSuffix(":distribute") }
        #expect(requests.count == 2)
        #expect(requests[0].json()["groupAliases"] as? [String] == ["qa"])
        #expect(requests[0].json()["testerEmails"] as? [String] == ["a@b.c"])
        #expect(requests[1].json().isEmpty)

        let failing = StubRouter().on("POST", ":distribute", .status(403, "no"))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.distribute(releaseName: releaseName) }
        }
    }

    // MARK: - Groups

    @Test("listGroups extracts the project number and passes paging parameters")
    func listGroups() async throws {
        let router = StubRouter().on("GET", "/groups", .ok(#"{"groups":[{"name":"projects/1234567890/groups/qa","displayName":"QA","testerCount":3}],"nextPageToken":"t"}"#))
        let result = try await DefaultNetworkStub.firebase(router) { try await $0.listGroups(project: appId, pageSize: 10, pageToken: "p") }
        #expect(result.groups.first?.testerCount == 3)
        #expect(result.nextPageToken == "t")
        let request = try #require(router.log.first { $0.path.hasSuffix("/groups") })
        #expect(request.path.hasSuffix("/v1/projects/1234567890/groups"))
        #expect(request.query.contains("pageSize=10"))
        #expect(request.query.contains("pageToken=p"))

        let plain = StubRouter().on("GET", "/groups", .ok("{}"))
        let none = try await DefaultNetworkStub.firebase(plain) { try await $0.listGroups(project: "my-project") }
        #expect(none.groups.isEmpty)
        #expect(plain.log.first { $0.path.hasSuffix("/groups") }?.path.contains("projects/my-project/") == true)

        let failing = StubRouter().on("GET", "/groups", .status(500))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.listGroups(project: "p") }
        }
    }

    @Test("getGroup returns the group, nil on 404, and throws on other errors")
    func getGroup() async throws {
        let router = StubRouter()
            .on("GET", "/groups/qa", .ok(#"{"name":"projects/1/groups/qa","displayName":"QA"}"#))
            .on("GET", "/groups/missing", .status(404))
            .on("GET", "/groups/broken", .status(500, "err"))
        try await DefaultNetworkStub.firebase(router) { service in
            let qa = try await service.getGroup(project: "1", groupAlias: "qa")
            #expect(qa?.displayName == "QA")
            let missing = try await service.getGroup(project: "1", groupAlias: "missing")
            #expect(missing == nil)
            await #expect(throws: NSError.self) { _ = try await service.getGroup(project: "1", groupAlias: "broken") }
        }
    }

    @Test("createOrGetGroup returns an existing group found directly or by listing")
    func createOrGetExisting() async throws {
        let direct = StubRouter().on("GET", "/groups/qa-team", .ok(#"{"name":"projects/1/groups/qa-team","displayName":"QA"}"#))
        let found = try await DefaultNetworkStub.firebase(direct) { try await $0.createOrGetGroup(project: "1:1:ios:a", groupAlias: "qa-team") }
        #expect(found.displayName == "QA")

        let listed = StubRouter()
            .on("GET", "/groups/qa-team", .status(404))
            .on("GET", "/groups?", .ok(#"{"groups":[{"name":"projects/1/groups/other","displayName":"QA Team"}]}"#))
        let byDisplay = try await DefaultNetworkStub.firebase(listed) {
            try await $0.createOrGetGroup(project: "1", groupAlias: "qa-team", displayName: "qa team")
        }
        #expect(byDisplay.name == "projects/1/groups/other")
        #expect(!listed.log.requests.contains { $0.method == "POST" && $0.path.hasSuffix("/groups") })
    }

    @Test("createOrGetGroup creates a group with a sanitized ID or recovers from conflicts")
    func createOrGetCreates() async throws {
        let creating = StubRouter()
            .on("GET", "/groups/QA_Team", .status(404))
            .on("GET", "/groups?", .ok("{}"))
            .on("POST", "/groups", .ok(#"{"name":"projects/1/groups/qa-team","displayName":"QA Team"}"#))
        let created = try await DefaultNetworkStub.firebase(creating) { try await $0.createOrGetGroup(project: "1", groupAlias: "QA_Team") }
        #expect(created.name == "projects/1/groups/qa-team")
        let post = try #require(creating.log.first { $0.method == "POST" && $0.path.hasSuffix("/groups") })
        #expect(post.query == "groupId=qa-team")
        #expect(post.json()["displayName"] as? String == "QA_Team")

        // Short aliases are sent without a groupId; 409 then re-reads the group.
        let conflict = StubRouter()
            .on("GET", "/groups/qa", .status(404), .ok(#"{"name":"projects/1/groups/qa","displayName":"Existing"}"#))
            .on("GET", "/groups?", .status(500))
            .on("POST", "/groups", .status(409))
        let recovered = try await DefaultNetworkStub.firebase(conflict) { try await $0.createOrGetGroup(project: "1", groupAlias: "qa") }
        #expect(recovered.displayName == "Existing")
        #expect(conflict.log.first { $0.method == "POST" && $0.path.hasSuffix("/groups") }?.query == "")

        let conflictMissing = StubRouter()
            .on("GET", "/groups/qa", .status(404))
            .on("GET", "/groups?", .ok("{}"))
            .on("POST", "/groups", .status(409))
        let synthesized = try await DefaultNetworkStub.firebase(conflictMissing) { try await $0.createOrGetGroup(project: "1", groupAlias: "qa", displayName: "Q") }
        #expect(synthesized.name == "projects/1/groups/qa")
        #expect(synthesized.displayName == "Q")

        let failing = StubRouter()
            .on("GET", "/groups/qa", .status(404))
            .on("GET", "/groups?", .ok("{}"))
            .on("POST", "/groups", .status(400, "invalid"))
        let error = await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.createOrGetGroup(project: "1", groupAlias: "qa") }
        }
        #expect(error?.code == 400)
    }

    // MARK: - Identity Toolkit

    @Test("listAuthUsers clamps maxResults, forwards the page token, and decodes users")
    func listAuthUsers() async throws {
        let router = StubRouter().on("GET", "accounts:batchGet", .ok(#"{"users":[{"localId":"u1","email":"a@b.c"}],"nextPageToken":"n"}"#))
        let result = try await DefaultNetworkStub.firebase(router) { try await $0.listAuthUsers(project: "p", maxResults: 5000, pageToken: "tok") }
        #expect(result.users.map(\.localId) == ["u1"])
        #expect(result.nextPageToken == "n")
        let request = try #require(router.log.first { $0.path.hasSuffix("accounts:batchGet") })
        #expect(request.query.contains("maxResults=1000"))
        #expect(request.query.contains("nextPageToken=tok"))

        let empty = StubRouter().on("GET", "accounts:batchGet", .ok("{}"))
        let none = try await DefaultNetworkStub.firebase(empty) { try await $0.listAuthUsers(project: "p", maxResults: 0, pageToken: "") }
        #expect(none.users.isEmpty)
        #expect(empty.log.first { $0.path.hasSuffix("accounts:batchGet") }?.query == "maxResults=1")

        let failing = StubRouter().on("GET", "accounts:batchGet", .status(403))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.listAuthUsers(project: "p") }
        }
    }

    @Test("lookupAuthUsers posts emails and UIDs and decodes matches")
    func lookupAuthUsers() async throws {
        let router = StubRouter().on("POST", "accounts:lookup", .ok(#"{"users":[{"localId":"u1"}]}"#), .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let users = try await service.lookupAuthUsers(project: "p", emails: ["a@b.c"], uids: ["u1"])
            #expect(users.count == 1)
            let none = try await service.lookupAuthUsers(project: "p", emails: [], uids: nil)
            #expect(none.isEmpty)
        }
        let requests = router.log.requests.filter { $0.path.hasSuffix("accounts:lookup") }
        #expect(requests[0].json()["email"] as? [String] == ["a@b.c"])
        #expect(requests[0].json()["localId"] as? [String] == ["u1"])
        #expect(requests[1].json().isEmpty)

        let failing = StubRouter().on("POST", "accounts:lookup", .status(400))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.lookupAuthUsers(project: "p", uids: ["x"]) }
        }
    }

    @Test("deleteAuthUser posts the UID and surfaces HTTP errors")
    func deleteAuthUser() async throws {
        let router = StubRouter().on("POST", "accounts:delete", .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { try await $0.deleteAuthUser(project: "p", uid: "u1") }
        #expect(router.log.first { $0.path.hasSuffix("accounts:delete") }?.json()["localId"] as? String == "u1")

        let failing = StubRouter().on("POST", "accounts:delete", .status(404))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.deleteAuthUser(project: "p", uid: "u1") }
        }
    }

    @Test("deleteAuthUsers maps per-user errors and skips empty input")
    func deleteAuthUsers() async throws {
        let router = StubRouter().on("POST", "accounts:batchDelete",
            .ok(#"{"errors":[{"index":1,"message":"not disabled"},{"index":9,"message":"out of range"},{"message":null}]}"#),
            .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let empty = try await service.deleteAuthUsers(project: "p", uids: [])
            #expect(empty == [])
            let errors = try await service.deleteAuthUsers(project: "p", uids: ["a", "b"], force: false)
            #expect(errors == ["UID b: not disabled", "out of range"])
            let clean = try await service.deleteAuthUsers(project: "p", uids: ["a"])
            #expect(clean == [])
        }
        let first = try #require(router.log.first { $0.path.hasSuffix("accounts:batchDelete") })
        #expect(first.json()["localIds"] as? [String] == ["a", "b"])
        #expect(first.json()["force"] as? Bool == false)

        let failing = StubRouter().on("POST", "accounts:batchDelete", .status(500))
        await #expect(throws: NSError.self) {
            try await DefaultNetworkStub.firebase(failing) { try await $0.deleteAuthUsers(project: "p", uids: ["a"]) }
        }
    }

    // MARK: - Firebase Apps (Management API)

    @Test("listApps follows pages, forwards showDeleted, and de-duplicates apps")
    func listApps() async throws {
        let router = StubRouter().on("GET", ":searchApps",
            .ok(#"{"apps":[{"appId":"1:1:ios:a","platform":"IOS","namespace":"com.a"}],"nextPageToken":"p2"}"#),
            .ok(#"{"apps":[{"appId":"1:1:ios:a"},{"appId":"1:1:android:b","platform":"ANDROID"}],"nextPageToken":""}"#))
        let apps = try await DefaultNetworkStub.firebase(router) { try await $0.listApps(project: "my proj", showDeleted: true) }
        #expect(apps.map(\.appId) == ["1:1:ios:a", "1:1:android:b"])
        let requests = router.log.requests.filter { $0.path.hasSuffix(":searchApps") }
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString.contains("projects/my%20proj:searchApps"))
        #expect(requests[0].query.contains("showDeleted=true"))
        #expect(requests[1].query.contains("pageToken=p2"))
        #expect(requests[0].headers["Authorization"] == "Bearer test-token")
    }

    @Test("listApps treats pages without apps as empty")
    func listAppsEmpty() async throws {
        let router = StubRouter().on("GET", ":searchApps", .ok("{}"))
        let apps = try await DefaultNetworkStub.firebase(router) { try await $0.listApps(project: "p") }
        #expect(apps.isEmpty)
        #expect(router.log.first { $0.path.hasSuffix(":searchApps") }?.query == "pageSize=100")
    }

    @Test("createApp posts to the platform collection and maps an already finished operation")
    func createApp() async throws {
        let cases: [(FirebaseAppPlatform, String, String)] = [
            (.ios, "iosApps", #"{"appId":"1:1:ios:a","bundleId":"com.a","displayName":"A","state":"ACTIVE"}"#),
            (.android, "androidApps", #"{"appId":"1:1:android:b","packageName":"com.b"}"#),
            (.web, "webApps", #"{"appId":"1:1:web:c","webId":"w"}"#),
        ]
        for (platform, collection, appJSON) in cases {
            let router = StubRouter().on("POST", "/\(collection)", .ok(#"{"name":"operations/x","done":true,"response":\#(appJSON)}"#))
            let app = try await DefaultNetworkStub.firebase(router) {
                try await $0.createApp(project: "p", request: FirebaseAppCreateRequest(platform: platform, displayName: "A", identifier: "com.a"))
            }
            #expect(app.platform == platform.rawValue)
            #expect(app.namespace != nil)
            let post = try #require(router.log.first { $0.method == "POST" && $0.path.contains(collection) })
            #expect(post.path.hasSuffix("/v1beta1/projects/p/\(collection)"))
            #expect(post.headers["Content-Type"] == "application/json")
        }
    }

    @Test("Management operations surface operation errors, missing responses, and malformed operations")
    func managementOperationErrors() async throws {
        func create(_ response: StubResponse) async throws {
            let router = StubRouter().on("POST", "/iosApps", response)
            _ = try await DefaultNetworkStub.firebase(router) {
                try await $0.createApp(project: "p", request: FirebaseAppCreateRequest(platform: .ios))
            }
        }
        let opError = await #expect(throws: FirebaseAppsError.self) { try await create(.ok(#"{"done":true,"error":{"code":6,"message":"exists"}}"#)) }
        #expect(opError?.message == "exists (code 6)")
        let opErrorNoCode = await #expect(throws: FirebaseAppsError.self) { try await create(.ok(#"{"done":true,"error":{}}"#)) }
        #expect(opErrorNoCode?.message == "Operation failed")
        let noResponse = await #expect(throws: FirebaseAppsError.self) { try await create(.ok(#"{"done":true}"#)) }
        #expect(noResponse?.message.contains("without a response") == true)
        let noName = await #expect(throws: FirebaseAppsError.self) { try await create(.ok(#"{"done":false}"#)) }
        #expect(noName?.message.contains("without a name") == true)
        let notObject = await #expect(throws: FirebaseAppsError.self) { try await create(.ok("[]")) }
        #expect(notObject?.message.contains("Unexpected operation") == true)
        let http = await #expect(throws: FirebaseAppsError.self) { try await create(.status(403, #"{"error":{"message":"Permission denied"}}"#)) }
        #expect(http?.status == 403)
        #expect(http?.message == "Permission denied")
        #expect(http?.errorDescription == "Firebase Management API error (HTTP 403): Permission denied")
        let plain = await #expect(throws: FirebaseAppsError.self) { try await create(.status(500, "oops")) }
        #expect(plain?.message == "HTTP 500")
        #expect(FirebaseAppsError(status: nil, message: "m").errorDescription == "m")
    }

    @Test("removeApp sends removal flags and accepts operations without a response")
    func removeApp() async throws {
        let router = StubRouter().on("POST", ":remove", .ok(#"{"name":"operations/r","done":true}"#))
        try await DefaultNetworkStub.firebase(router) { service in
            try await service.removeApp(project: "p", platform: .android, appId: "1:1:android:b", immediate: true, validateOnly: true)
            try await service.removeApp(project: "p", platform: .web, appId: "1:1:web:c", immediate: false, validateOnly: false)
        }
        let requests = router.log.requests.filter { $0.path.hasSuffix(":remove") }
        #expect(requests[0].url.absoluteString.contains("/androidApps/1%3A1%3Aandroid%3Ab:remove"))
        #expect(requests[0].json()["immediate"] as? Bool == true)
        #expect(requests[0].json()["validateOnly"] as? Bool == true)
        #expect(requests[0].json()["allowMissing"] as? Bool == false)
        #expect(requests[1].json()["immediate"] == nil)
        #expect(requests[1].path.contains("/webApps/"))
    }

    @Test("SHA certificates are listed, added with normalized hashes, and deleted by name")
    func shaCertificates() async throws {
        let router = StubRouter()
            .on("GET", "/sha", .ok(#"{"certificates":[{"name":"projects/p/androidApps/a/sha/1","shaHash":"abcd","certType":"SHA_1"}]}"#), .ok("{}"))
            .on("POST", "/sha", .ok("{}"))
            .on("DELETE", "/sha/1", .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let certs = try await service.listShaCertificates(project: "p", appId: "a")
            #expect(certs == [FirebaseShaCertificate(name: "projects/p/androidApps/a/sha/1", shaHash: "abcd", certType: .sha1)])
            let none = try await service.listShaCertificates(project: "p", appId: "a")
            #expect(none.isEmpty)
            try await service.addShaCertificate(project: "p", appId: "a", hash: "AB:CD:EF", type: .sha256)
            try await service.deleteShaCertificate(name: "projects/p/androidApps/a/sha/1")
        }
        let post = try #require(router.log.first { $0.method == "POST" && $0.path.hasSuffix("/sha") })
        #expect(post.json()["shaHash"] as? String == "abcdef")
        #expect(post.json()["certType"] as? String == "SHA_256")
        #expect(router.log.requests.contains { $0.method == "DELETE" && $0.path == "/v1beta1/projects/p/androidApps/a/sha/1" })
        #expect(FirebaseService.googleErrorMessage(Data(#"{"error":{"message":"m"}}"#.utf8)) == "m")
        #expect(FirebaseService.googleErrorMessage(Data("x".utf8)) == nil)
    }
}
