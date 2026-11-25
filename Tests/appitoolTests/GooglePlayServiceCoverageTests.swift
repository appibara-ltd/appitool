import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GooglePlayStoreAPI
import Testing
@testable import appitool
@testable import GoogleServices

private func withPlay<T>(_ router: StubRouter, _ body: (GooglePlayService) async throws -> T) async throws -> T {
    HTTPStub.googleTokenRoute(router)
    return try await DefaultNetworkStub.with(router) { session in
        let service = try GooglePlayService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport(router), urlSession: session)
        return try await body(service)
    }
}

private let pkg = "com.example.app"

@Suite("GooglePlayService Coverage Tests")
struct GooglePlayServiceCoverageTests {

    // MARK: - Auth Middleware

    @Test("Service account key initializer keeps values and defaults the token URI")
    func serviceAccountKeyInit() {
        let key = GoogleServiceAccountKey(projectId: "p", privateKeyId: "k", privateKey: "pem", clientEmail: "e", clientId: "c", authUri: "a", authProviderX509CertUrl: "x", clientX509CertUrl: "y")
        #expect(key.type == "service_account")
        #expect(key.tokenUri == "https://oauth2.googleapis.com/token")
        #expect(key.clientX509CertUrl == "y")
    }

    @Test("Service account parsing accepts unpadded Base64 and rejects unknown input")
    func parseServiceAccountVariants() throws {
        let json = TestCredentials.serviceAccountJSON(projectId: "b64")
        var base64 = Data(json.utf8).base64EncodedString()
        while base64.hasSuffix("=") { base64.removeLast() }
        #expect(try GooglePlayAuthMiddleware.parseServiceAccount(from: base64).projectId == "b64")
        #expect(throws: (any Error).self) { _ = try GooglePlayAuthMiddleware.parseServiceAccount(from: "~/appitool-missing-\(UUID().uuidString).json") }
        #expect(throws: (any Error).self) { _ = try GooglePlayAuthMiddleware.parseServiceAccount(from: "not a key") }
    }

    @Test("Access tokens are cached and token exchange failures are reported")
    func tokenExchange() async throws {
        let router = StubRouter()
        let tokens = try await withPlay(router) { service in
            [try await service.getAccessToken(), try await service.getAccessToken()]
        }
        #expect(tokens == ["test-token", "test-token"])
        let tokenRequests = router.log.requests.filter { $0.url.host == "oauth2.googleapis.com" }
        #expect(tokenRequests.count == 1)
        #expect(tokenRequests[0].bodyString.contains("grant_type=urn"))

        let failing = StubRouter().on("POST", "oauth2.googleapis.com/token", .status(400, #"{"error":"invalid_grant"}"#))
        let error = await #expect(throws: NSError.self) {
            try await HTTPStub.withSession(failing) { session in
                let middleware = try GooglePlayAuthMiddleware(key: TestCredentials.serviceAccountJSON(), urlSession: session)
                return try await middleware.getAccessToken()
            }
        }
        #expect(error?.localizedDescription.contains("invalid_grant") == true)
    }

    @Test("Token responses without expiry use the default lifetime and non-UTF-8 failures are reported")
    func tokenEdgeCases() async throws {
        let router = StubRouter().on("POST", "oauth2.googleapis.com/token", .ok(#"{"access_token":"no-expiry"}"#))
        let token = try await HTTPStub.withSession(router) { session in
            try await GooglePlayAuthMiddleware(key: TestCredentials.serviceAccountJSON(), urlSession: session).getAccessToken()
        }
        #expect(token == "no-expiry")

        let binary = StubRouter().on("POST", "oauth2.googleapis.com/token", StubResponse(500, Data([0xFF, 0xFE])))
        let error = await #expect(throws: NSError.self) {
            try await HTTPStub.withSession(binary) { session in
                try await GooglePlayAuthMiddleware(key: TestCredentials.serviceAccountJSON(), urlSession: session).getAccessToken()
            }
        }
        #expect(error?.localizedDescription.contains("Unknown error") == true)
    }

    @Test("Empty error bodies fall back to HTTP status messages")
    func emptyErrorBodies() async throws {
        let dir = try TestFiles.makeTempDir()
        let png = dir.appendingPathComponent("shot.png")
        try Data([0x89]).write(to: png)
        let router = StubRouter()
        router.fallback = .status(502, "")
        try await withPlay(router) { service in
            let cases: [(String, () async throws -> Void)] = [
                ("HTTP 502 while reading app details.", { _ = try await service.fetchAppDetails(packageName: pkg, editId: "e") }),
                ("HTTP 502 while listing images.", { _ = try await service.listImages(packageName: pkg, editId: "e", language: "en", imageType: .icon) }),
                ("HTTP 502 while deleting image 'i'.", { try await service.deleteImage(packageName: pkg, editId: "e", language: "en", imageType: .icon, imageId: "i") }),
                ("HTTP 502 while deleting images.", { _ = try await service.deleteAllImages(packageName: pkg, editId: "e", language: "en", imageType: .icon) }),
                ("HTTP 502", { _ = try await service.uploadImage(packageName: pkg, editId: "e", language: "en", imageType: .icon, fileUrl: png) }),
                ("HTTP 502", { _ = try await service.searchAccessibleApps() }),
                ("HTTP 502", { _ = try await service.listGeneratedApks(packageName: pkg, versionCode: 1) }),
            ]
            for (message, call) in cases {
                let error = await #expect(throws: GooglePlayImageError.self) { try await call() }
                #expect(error == .apiError(status: 502, message: message))
            }
        }
    }

    @Test("User pages without a users array are treated as empty")
    func emptyUsersPage() async throws {
        let router = StubRouter().on("GET", "/users", .ok("{}"))
        let users = try await withPlay(router) { try await $0.listUsers(developerId: "1") }
        #expect(users.isEmpty)
    }

    // MARK: - Edits & Publishing

    @Test("Edit lifecycle calls create, update tracks, commit, validate, and delete")
    func editLifecycle() async throws {
        let router = StubRouter()
            .on("POST", "androidpublisher.edits.insert", .ok(#"{"id":"e1"}"#))
            .on("PUT", "androidpublisher.edits.tracks.update", .ok(#"{"track":"internal","releases":[{"status":"completed","versionCodes":["7"]}]}"#))
            .on("POST", "androidpublisher.edits.commit", .ok(#"{"id":"e1"}"#))
            .on("POST", "androidpublisher.edits.validate", .ok(#"{"id":"e1"}"#))
            .on("DELETE", "androidpublisher.edits.delete", .status(204, ""))
        try await withPlay(router) { service in
            let editId = try await service.createEdit(packageName: pkg)
            #expect(editId == "e1")
            let track = try await service.updateTrack(packageName: pkg, editId: editId, track: "internal", releases: [.init(status: .init(rawValue: "completed"), versionCodes: ["7"])])
            #expect(track.track == "internal")
            #expect(try await service.commitEdit(packageName: pkg, editId: editId, changesNotSentForReview: true).id == "e1")
            #expect(try await service.validateEdit(packageName: pkg, editId: editId).id == "e1")
            try await service.deleteEdit(packageName: pkg, editId: editId)
        }
        let commit = try #require(router.log.first { $0.operationID == "androidpublisher.edits.commit" })
        #expect(commit.query.contains("changesNotSentForReview=true"))
        #expect(commit.headers["authorization"] == "Bearer test-token")
    }

    @Test("Edit operations throw when the API does not return a success payload")
    func editFailures() async throws {
        let router = StubRouter()
        router.fallback = .status(500, #"{"error":{"message":"server"}}"#)
        try await withPlay(router) { service in
            await #expect(throws: NSError.self) { _ = try await service.createEdit(packageName: pkg) }
            await #expect(throws: NSError.self) { _ = try await service.updateTrack(packageName: pkg, editId: "e", track: "beta", releases: []) }
            await #expect(throws: NSError.self) { _ = try await service.commitEdit(packageName: pkg, editId: "e") }
            await #expect(throws: NSError.self) { _ = try await service.validateEdit(packageName: pkg, editId: "e") }
        }
    }

    @Test("Bundle and APK uploads parse version codes and hashes")
    func binaryUploads() async throws {
        let dir = try TestFiles.makeTempDir()
        let file = dir.appendingPathComponent("app.aab")
        try Data("bundle".utf8).write(to: file)
        let router = StubRouter()
            .on("POST", "/bundles", .ok(#"{"versionCode":42,"sha1":"s1","sha256":"s256"}"#), .ok(#"{"versionCode":"43"}"#))
            .on("POST", "/apks", .ok(#"{"versionCode":7,"binary":{"sha1":"b1","sha256":"b256"}}"#), .ok(#"{"versionCode":"8","sha1":"f1"}"#))
        try await withPlay(router) { service in
            let bundle = try await service.uploadBundle(packageName: pkg, editId: "e1", fileUrl: file, ackBundleInstallationWarning: true)
            #expect(bundle.versionCode == 42)
            #expect(bundle.sha256 == "s256")
            let bundle2 = try await service.uploadBundle(packageName: pkg, editId: "e1", fileUrl: file)
            #expect(bundle2.versionCode == 43)
            let apk = try await service.uploadApk(packageName: pkg, editId: "e1", fileUrl: file)
            #expect(apk.versionCode == 7)
            #expect(apk.sha1 == "b1")
            let apk2 = try await service.uploadApk(packageName: pkg, editId: "e1", fileUrl: file)
            #expect(apk2.versionCode == 8)
            #expect(apk2.sha1 == "f1")
        }
        let bundleRequests = router.log.requests.filter { $0.path.hasSuffix("/bundles") }
        #expect(bundleRequests[0].query.contains("ackBundleInstallationWarning=true"))
        #expect(!bundleRequests[1].query.contains("ackBundleInstallationWarning"))
        #expect(bundleRequests[0].headers["Content-Type"] == "application/octet-stream")
        #expect(router.log.first { $0.path.hasSuffix("/apks") }?.headers["Content-Type"] == "application/vnd.android.package-archive")
        #expect(GooglePlayBundleUploadResult(versionCode: 1).sha1 == nil)
        #expect(GooglePlayApkUploadResult(versionCode: 1).sha256 == nil)
    }

    @Test("Bundle and APK uploads surface HTTP errors, bad JSON, and missing version codes")
    func binaryUploadFailures() async throws {
        let dir = try TestFiles.makeTempDir()
        let file = dir.appendingPathComponent("app.apk")
        try Data("apk".utf8).write(to: file)
        let router = StubRouter()
            .on("POST", "/bundles",
                .status(403, #"{"error":{"message":"forbidden"}}"#),
                .status(500, #"{"message":"top-level"}"#),
                .ok("not json"),
                .ok(#"{"sha1":"x"}"#))
            .on("POST", "/apks",
                .status(400, "plain text"),
                .status(400, #"{"other":1}"#),
                .ok("[]"),
                .ok(#"{"versionCode":"abc"}"#))
        try await withPlay(router) { service in
            let codes: [Int] = [403, 500, 4, 5]
            for code in codes {
                let error = await #expect(throws: NSError.self) { _ = try await service.uploadBundle(packageName: pkg, editId: "e", fileUrl: file) }
                #expect(error?.code == code)
            }
            let first = await #expect(throws: NSError.self) { _ = try await service.uploadApk(packageName: pkg, editId: "e", fileUrl: file) }
            #expect(first?.localizedDescription.contains("plain text") == true)
            let second = await #expect(throws: NSError.self) { _ = try await service.uploadApk(packageName: pkg, editId: "e", fileUrl: file) }
            #expect(second?.localizedDescription.contains("other") == true)
            let third = await #expect(throws: NSError.self) { _ = try await service.uploadApk(packageName: pkg, editId: "e", fileUrl: file) }
            #expect(third?.code == 8)
            let fourth = await #expect(throws: NSError.self) { _ = try await service.uploadApk(packageName: pkg, editId: "e", fileUrl: file) }
            #expect(fourth?.code == 9)
        }
    }

    // MARK: - Listings & Details

    @Test("App details and listings are read and patched")
    func listingsAndDetails() async throws {
        let router = StubRouter()
            .on("GET", "androidpublisher.edits.details.get", .ok(#"{"contactEmail":"a@b.c","contactPhone":"1","contactWebsite":"https://w","defaultLanguage":"en-US"}"#))
            .on("PATCH", "androidpublisher.edits.details.patch", .ok("{}"))
            .on("GET", "androidpublisher.edits.listings.list", .ok(#"{"listings":[{"language":"en-US","title":"T","shortDescription":"S","fullDescription":"F","video":"V"},{"title":"no language"}]}"#))
            .on("PATCH", "androidpublisher.edits.listings.patch", .ok(#"{"language":"de-DE"}"#))
        try await withPlay(router) { service in
            let details = try await service.fetchAppDetails(packageName: pkg, editId: "e")
            #expect(details == GooglePlayAppDetails(contactEmail: "a@b.c", contactPhone: "1", contactWebsite: "https://w", defaultLanguage: "en-US"))
            #expect(!details.isEmpty)
            #expect(GooglePlayAppDetails().isEmpty)
            try await service.patchAppDetails(packageName: pkg, editId: "e", changes: GooglePlayAppDetails(contactEmail: "x@y.z"))
            let listings = try await service.listListings(packageName: pkg, editId: "e")
            #expect(listings == [GooglePlayListing(language: "en-US", title: "T", shortDescription: "S", fullDescription: "F", video: "V")])
            #expect(try await service.listListingLanguages(packageName: pkg, editId: "e") == ["en-US"])
            try await service.patchListing(packageName: pkg, editId: "e", changes: GooglePlayListing(language: "de-DE", title: "Titel"))
        }
        let patch = try #require(router.log.first { $0.operationID == "androidpublisher.edits.listings.patch" })
        #expect(patch.path.hasSuffix("/listings/de-DE"))
        #expect(patch.json()["title"] as? String == "Titel")
        #expect(router.log.first { $0.operationID == "androidpublisher.edits.details.patch" }?.json()["contactEmail"] as? String == "x@y.z")
    }

    @Test("Listing and detail calls map undocumented responses to API errors")
    func listingsFailures() async throws {
        let router = StubRouter()
            .on("GET", "androidpublisher.edits.details.get", .status(404, #"{"error":{"message":"no edit"}}"#))
        router.fallback = .status(500, "")
        try await withPlay(router) { service in
            let detailsError = await #expect(throws: GooglePlayImageError.self) { _ = try await service.fetchAppDetails(packageName: pkg, editId: "e") }
            #expect(detailsError == .apiError(status: 404, message: "no edit"))
            let patchError = await #expect(throws: GooglePlayImageError.self) { try await service.patchAppDetails(packageName: pkg, editId: "e", changes: .init()) }
            #expect(patchError == .apiError(status: 500, message: "HTTP 500 while updating app details."))
            await #expect(throws: GooglePlayImageError.self) { _ = try await service.listListings(packageName: pkg, editId: "e") }
            await #expect(throws: GooglePlayImageError.self) { _ = try await service.listListingLanguages(packageName: pkg, editId: "e") }
            await #expect(throws: GooglePlayImageError.self) { try await service.patchListing(packageName: pkg, editId: "e", changes: .init(language: "en-US")) }
        }
    }

    // MARK: - Images

    @Test("withEditSession commits, validates, or discards the edit and cleans up on failure")
    func withEditSession() async throws {
        struct Boom: Error {}
        let router = StubRouter()
            .on("POST", "androidpublisher.edits.insert", .ok(#"{"id":"e1"}"#))
            .on("POST", "androidpublisher.edits.commit", .ok(#"{"id":"e1"}"#))
            .on("POST", "androidpublisher.edits.validate", .ok(#"{"id":"e1"}"#))
            .on("DELETE", "androidpublisher.edits.delete", .status(204, ""))
        try await withPlay(router) { service in
            let committed = try await service.withEditSession(packageName: pkg, commit: true, changesNotSentForReview: false) { $0 }
            #expect(committed == "e1")
            let validated = try await service.withEditSession(packageName: pkg, commit: true, validateOnly: true) { _ in 1 }
            #expect(validated == 1)
            let discarded = try await service.withEditSession(packageName: pkg, commit: false) { _ in 2 }
            #expect(discarded == 2)
            await #expect(throws: Boom.self) { _ = try await service.withEditSession(packageName: pkg, commit: true) { _ -> Int in throw Boom() } }
        }
        let ops = router.log.requests.compactMap(\.operationID).filter { $0 != "androidpublisher.edits.insert" }
        #expect(ops == [
            "androidpublisher.edits.commit",
            "androidpublisher.edits.validate", "androidpublisher.edits.delete",
            "androidpublisher.edits.delete",
            "androidpublisher.edits.delete",
        ])
    }

    @Test("Images are listed, deleted individually, and deleted in bulk")
    func imageOperations() async throws {
        let router = StubRouter()
            .on("GET", "androidpublisher.edits.images.list", .ok(#"{"images":[{"id":"i1","url":"https://u","sha1":"a","sha256":"b"},{"id":""}]}"#))
            .on("DELETE", "androidpublisher.edits.images.deleteall", .ok(#"{"deleted":[{"id":"i1"},{"url":"x"}]}"#))
            .on("DELETE", "androidpublisher.edits.images.delete", StubResponse(200, Data()))
        try await withPlay(router) { service in
            let images = try await service.listImages(packageName: pkg, editId: "e", language: "en-US", imageType: .phoneScreenshots)
            #expect(images == [GooglePlayImage(id: "i1", url: "https://u", sha1: "a", sha256: "b")])
            try await service.deleteImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, imageId: "i1")
            let deleted = try await service.deleteAllImages(packageName: pkg, editId: "e", language: "en-US", imageType: .featureGraphic)
            #expect(deleted.map(\.id) == ["i1"])
        }
        #expect(router.log.first { $0.operationID == "androidpublisher.edits.images.delete" }?.path.hasSuffix("/listings/en-US/icon/i1") == true)
    }

    @Test("Image operations map undocumented responses to API errors")
    func imageFailures() async throws {
        let router = StubRouter()
        router.fallback = .status(403, #"{"message":"denied"}"#)
        try await withPlay(router) { service in
            let listError = await #expect(throws: GooglePlayImageError.self) { _ = try await service.listImages(packageName: pkg, editId: "e", language: "en-US", imageType: .tvBanner) }
            #expect(listError == .apiError(status: 403, message: "denied"))
            await #expect(throws: GooglePlayImageError.self) { try await service.deleteImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, imageId: "x") }
            await #expect(throws: GooglePlayImageError.self) { _ = try await service.deleteAllImages(packageName: pkg, editId: "e", language: "en-US", imageType: .icon) }
        }
    }

    @Test("uploadImage validates the file and parses nested or flat image payloads")
    func uploadImage() async throws {
        let dir = try TestFiles.makeTempDir()
        let png = dir.appendingPathComponent("shot.png")
        let jpg = dir.appendingPathComponent("shot.JPEG")
        let gif = dir.appendingPathComponent("shot.gif")
        let empty = dir.appendingPathComponent("empty.png")
        try Data([0x89, 0x50]).write(to: png)
        try Data([0xFF, 0xD8]).write(to: jpg)
        try Data([0x47]).write(to: gif)
        try Data().write(to: empty)

        let router = StubRouter().on("POST", "/upload/androidpublisher/v3/applications/",
            .ok(#"{"image":{"id":"n1","url":"https://n","sha1":"a","sha256":"b"}}"#),
            .ok(#"{"id":"f1"}"#),
            .status(400, #"{"error":{"message":"too small"}}"#),
            .ok("not json"),
            .ok(#"{"image":{"url":"x"}}"#))
        try await withPlay(router) { service in
            let nested = try await service.uploadImage(packageName: pkg, editId: "e", language: "en US", imageType: .phoneScreenshots, fileUrl: png)
            #expect(nested == GooglePlayImage(id: "n1", url: "https://n", sha1: "a", sha256: "b"))
            let flat = try await service.uploadImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, fileUrl: jpg)
            #expect(flat.id == "f1")
            let http = await #expect(throws: GooglePlayImageError.self) { _ = try await service.uploadImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, fileUrl: png) }
            #expect(http == .apiError(status: 400, message: "too small"))
            await #expect(throws: GooglePlayImageError.self) { _ = try await service.uploadImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, fileUrl: png) }
            let missingId = await #expect(throws: GooglePlayImageError.self) { _ = try await service.uploadImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, fileUrl: png) }
            #expect(missingId == .invalidResponse("Image upload response missing image ID."))
            let ext = await #expect(throws: GooglePlayImageError.self) { _ = try await service.uploadImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, fileUrl: gif) }
            #expect(ext == .unsupportedFileExtension("gif"))
            await #expect(throws: GooglePlayImageError.self) { _ = try await service.uploadImage(packageName: pkg, editId: "e", language: "en-US", imageType: .icon, fileUrl: empty) }
        }
        let uploads = router.log.requests.filter { $0.path.contains("/upload/") }
        #expect(uploads[0].url.absoluteString.contains("/listings/en%20US/phoneScreenshots?uploadType=media"))
        #expect(uploads[0].headers["Content-Type"] == "image/png")
        #expect(uploads[1].headers["Content-Type"] == "image/jpeg")
    }

    @Test("Image downloads return bytes with content type and fail on HTTP errors")
    func downloadImage() async throws {
        let router = StubRouter()
            .on("GET", "cdn.example.com/ok", StubResponse(200, Data([1, 2, 3]), headers: ["Content-Type": "image/png"]))
            .on("GET", "cdn.example.com/missing", .status(404))
        try await withPlay(router) { service in
            let result = try await service.downloadImageData(from: URL(string: "https://cdn.example.com/ok")!)
            #expect(result.data == Data([1, 2, 3]))
            #expect(result.contentType == "image/png")
            let error = await #expect(throws: GooglePlayImageError.self) { _ = try await service.downloadImageData(from: URL(string: "https://cdn.example.com/missing")!) }
            if case .apiError(let status, _) = error { #expect(status == 404) } else { Issue.record("expected apiError") }
        }
    }

    @Test("Image helpers parse types, build full-resolution URLs, and describe errors")
    func imageHelpers() throws {
        #expect(try GooglePlayImageType.parse("featureGraphic") == .featureGraphic)
        #expect(try GooglePlayImageType.parse("PHONESCREENSHOTS") == .phoneScreenshots)
        #expect(try GooglePlayImageType.parse(" Watch ") == .wearScreenshots)
        #expect(throws: GooglePlayImageError.self) { _ = try GooglePlayImageType.parse("  ") }
        #expect(throws: GooglePlayImageError.self) { _ = try GooglePlayImageType.parse("poster") }
        for type in GooglePlayImageType.allCases {
            #expect(!type.description.isEmpty)
            #expect(type.aliases.contains(type.cliKey))
            #expect(try GooglePlayImageType.parse(type.cliKey) == type)
        }

        #expect(GooglePlayService.fullResolutionImageURL(from: "https://play-lh.googleusercontent.com/abc=w526-h296")?.absoluteString == "https://play-lh.googleusercontent.com/abc=s0")
        #expect(GooglePlayService.fullResolutionImageURL(from: "https://lh3.ggpht.com/a/b")?.absoluteString == "https://lh3.ggpht.com/a/b=s0")
        #expect(GooglePlayService.fullResolutionImageURL(from: "https://googleusercontent.com/")?.absoluteString == "https://googleusercontent.com/")
        #expect(GooglePlayService.fullResolutionImageURL(from: "https://example.com/x=w1")?.absoluteString == "https://example.com/x=w1")
        #expect(GooglePlayService.fullResolutionImageURL(from: "   ") == nil)

        #expect(GooglePlayImageError.unsupportedImageType("x").errorDescription?.contains("Unsupported Google Play image type 'x'") == true)
        #expect(GooglePlayImageError.unsupportedFileExtension("gif").errorDescription?.contains(".gif") == true)
        #expect(GooglePlayImageError.invalidResponse("m").errorDescription == "Invalid Google Play image response: m")
        #expect(GooglePlayImageError.apiError(status: 4, message: "m").errorDescription == "Google Play API Error (HTTP 4): m")

        #expect(GooglePlayService.parseGoogleErrorMessage(from: Data("  ".utf8)) == nil)
        #expect(GooglePlayService.parseGoogleErrorMessage(from: Data(#"{"a":1}"#.utf8)) == #"{"a":1}"#)
        #expect(GooglePlayService.encodePathSegment("a/b c") == "a%2Fb%20c")
    }

    // MARK: - Users & Grants

    @Test("Users are listed across pages and invited, updated, and removed")
    func users() async throws {
        let router = StubRouter()
            .on("GET", "/developers/123/users",
                .ok(#"{"users":[{"email":"a@b.c","accessState":"ACCESS_GRANTED"}],"nextPageToken":"p2"}"#),
                .ok(#"{"users":[{"email":"d@e.f","accessState":"INVITED"}],"nextPageToken":""}"#))
            .on("POST", "/grants", .ok(#"{"packageName":"com.example.app","appLevelPermissions":["CAN_ACCESS_APP"]}"#))
            .on("PATCH", "/grants/", .ok(#"{"appLevelPermissions":["CAN_REPLY_TO_REVIEWS"]}"#))
            .on("DELETE", "/grants/", .ok("{}"))
            .on("POST", "/developers/123/users", .ok(#"{"email":"n@e.w","accessState":"INVITED"}"#))
            .on("PATCH", "/users/", .ok(#"{"email":"a@b.c","expirationTime":"2030-01-01T00:00:00Z"}"#))
            .on("DELETE", "/users/", .ok("{}"))
        try await withPlay(router) { service in
            let users = try await service.listUsers(developerId: "123")
            #expect(users.map(\.email) == ["a@b.c", "d@e.f"])
            #expect(users[1].isInvitation)
            let created = try await service.createUser(developerId: "123", email: "n@e.w", permissions: ["CAN_SEE_ALL_APPS"], expirationTime: nil)
            #expect(created.isInvitation)
            let updated = try await service.updateUser(developerId: "123", email: "a+b@c.d", permissions: ["CAN_SEE_ALL_APPS"], expirationTime: "2030-01-01T00:00:00Z")
            #expect(updated.expirationTime != nil)
            _ = try await service.updateUser(developerId: "123", email: "a@b.c", permissions: nil, expirationTime: nil)
            try await service.deleteUser(developerId: "123", email: "a@b.c")
            let grant = try await service.createGrant(developerId: "123", email: "a@b.c", packageName: pkg, permissions: ["CAN_ACCESS_APP"])
            #expect(grant.packageName == pkg)
            let updatedGrant = try await service.updateGrant(developerId: "123", email: "a@b.c", packageName: pkg, permissions: ["CAN_REPLY_TO_REVIEWS"])
            #expect(updatedGrant.appLevelPermissions == ["CAN_REPLY_TO_REVIEWS"])
            try await service.deleteGrant(developerId: "123", email: "a@b.c", packageName: pkg)
        }
        let lists = router.log.requests.filter { $0.method == "GET" && $0.path.hasSuffix("/users") }
        #expect(lists[0].query == "pageSize=-1")
        #expect(lists[1].query == "pageSize=-1&pageToken=p2")
        let patches = router.log.requests.filter { $0.method == "PATCH" && !$0.path.contains("/grants") }
        #expect(patches[0].query == "updateMask=developerAccountPermissions,expirationTime")
        #expect(patches[0].url.absoluteString.contains("/users/a+b@c.d"))
        #expect(patches[1].query == "updateMask=")
        let invite = try #require(router.log.first { $0.method == "POST" && $0.path.hasSuffix("/users") })
        #expect(invite.json()["email"] as? String == "n@e.w")
        #expect(invite.headers["Content-Type"] == "application/json")
        #expect(router.log.first { $0.method == "PATCH" && $0.path.contains("/grants/") }?.query == "updateMask=appLevelPermissions")
        #expect(router.log.first { $0.method == "DELETE" && $0.path.contains("/grants/") }?.body?.isEmpty ?? true)
        #expect(GooglePlayGrant(name: "n").name == "n")
    }

    @Test("User requests map Google errors to API errors")
    func usersFailure() async throws {
        let router = StubRouter().on("GET", "/users", .status(403, #"{"error":{"message":"no access"}}"#))
        let error = await #expect(throws: GooglePlayImageError.self) {
            try await withPlay(router) { try await $0.listUsers(developerId: "1") }
        }
        #expect(error == .apiError(status: 403, message: "no access"))
        let plain = StubRouter().on("DELETE", "/users/", .status(500, ""))
        let plainError = await #expect(throws: GooglePlayImageError.self) {
            try await withPlay(plain) { try await $0.deleteUser(developerId: "1", email: "a@b.c") }
        }
        #expect(plainError == .apiError(status: 500, message: "HTTP 500"))
    }

    // MARK: - Accessible Apps & Generated APKs

    @Test("searchAccessibleApps follows pages and maps errors")
    func accessibleApps() async throws {
        let router = StubRouter().on("GET", "apps:search",
            .ok(#"{"apps":[{"name":"apps/a","packageName":"com.a","displayName":"A"}],"nextPageToken":"n"}"#),
            .ok("{}"))
        let apps = try await withPlay(router) { try await $0.searchAccessibleApps() }
        #expect(apps == [GooglePlayAccessibleApp(name: "apps/a", packageName: "com.a", displayName: "A")])
        let requests = router.log.requests.filter { $0.path.hasSuffix("apps:search") }
        #expect(requests.map(\.query) == ["pageSize=1000", "pageSize=1000&pageToken=n"])

        let failing = StubRouter().on("GET", "apps:search", .status(403, #"{"error":{"message":"API disabled"}}"#))
        let error = await #expect(throws: GooglePlayImageError.self) { try await withPlay(failing) { try await $0.searchAccessibleApps() } }
        #expect(error == .apiError(status: 403, message: "API disabled"))
    }

    @Test("Generated APKs are listed smallest-first and downloaded")
    func generatedApks() async throws {
        let list = #"""
        {"generatedApks":[{"certificateSha256Hash":"aa",
          "generatedUniversalApk":{"downloadId":"u"},
          "generatedStandaloneApks":[{"downloadId":"s"}],
          "generatedSplitApks":[{"downloadId":"base","splitId":""},{"downloadId":"cfg","splitId":"config.en"},{"downloadId":""}]},
          {}]}
        """#
        let router = StubRouter()
            .on("GET", ":download", StubResponse(200, Data([9, 9]), headers: ["Content-Type": "application/octet-stream"]))
            .on("GET", "/generatedApks/7", .ok(list))
        try await withPlay(router) { service in
            let groups = try await service.listGeneratedApks(packageName: pkg, versionCode: 7)
            #expect(groups.map(\.certificateSha256Hash) == ["aa", ""])
            #expect(groups.map(\.downloadIds) == [["cfg", "base", "s", "u"], []])
            #expect(try await service.downloadGeneratedApk(packageName: pkg, versionCode: 7, downloadId: "cfg") == Data([9, 9]))
        }
        #expect(router.log.first { $0.path.hasSuffix(":download") }?.query == "alt=media")

        let failing = StubRouter().on("GET", "/generatedApks/", .status(404, #"{"error":{"message":"not found"}}"#))
        let error = await #expect(throws: GooglePlayImageError.self) {
            try await withPlay(failing) { try await $0.listGeneratedApks(packageName: pkg, versionCode: 1) }
        }
        #expect(error == .apiError(status: 404, message: "not found"))
    }
}
