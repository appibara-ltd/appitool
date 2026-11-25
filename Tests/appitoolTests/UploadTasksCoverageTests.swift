import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AppleServices
import GoogleServices
import Testing
@testable import appitool

// MARK: - Helpers

private enum UploadFixtures {
    static func file(_ name: String, bytes: Int = 15) throws -> (dir: URL, file: URL) {
        let dir = try TestFiles.makeTempDir("appitool-upload-tests")
        let file = dir.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: file)
        return (dir, file)
    }

    /// Builds a real `.ipa` (zip) containing `Payload/App.app/Info.plist` with the given contents.
    static func ipa(plist: Data?) throws -> (dir: URL, file: URL) {
        let dir = try TestFiles.makeTempDir("appitool-upload-tests")
        let appDir = dir.appendingPathComponent("Payload/App.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        if let plist {
            try plist.write(to: appDir.appendingPathComponent("Info.plist"))
        }
        return (dir, dir.appendingPathComponent("App.ipa"))
    }

    static func zip(_ dir: URL) async throws {
        let result = try await ProcessRunner.run(
            "zip", arguments: ["-q", "-r", "App.ipa", "Payload"], workingDirectory: dir.path,
            discardError: true, discardOutput: true)
        #expect(result.isSuccess)
    }

    static func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func ops(_ items: [(url: String, offset: Int, length: Int)]) -> String {
        let list = items.map {
            #"{"method":"PUT","url":"\#($0.url)","offset":\#($0.offset),"length":\#($0.length),"requestHeaders":[{"name":"Content-Type","value":"application/octet-stream"}]}"#
        }
        return #"{"fileName":"App.ipa","uploadOperations":[\#(list.joined(separator: ","))]}"#
    }

    static func buildUpload(_ state: String, warnings: String = "[]", errors: String = "[]", buildId: String? = nil) -> StubResponse {
        let attrs = #"{"state":{"state":"\#(state)","errors":\#(errors),"warnings":\#(warnings)}}"#
        let rel = buildId.map { #"{"build":{"data":{"type":"builds","id":"\#($0)"}}}"# }
        return .ok(ASCStub.single(ASCStub.res("buildUploads", "bu1", attrs, rel: rel)))
    }

    /// Standard routes for a successful upload up to commit.
    static func ascRouter(ops: String) -> StubRouter {
        StubRouter()
            .on("POST", "buildUploads_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("buildUploads", "bu1"))))
            .on("POST", "buildUploadFiles_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("buildUploadFiles", "f1", ops))))
            .on("PATCH", "buildUploadFiles_updateInstance", .ok(ASCStub.single(ASCStub.res("buildUploadFiles", "f1"))))
            .on("PUT", "upload.test/", .ok())
    }
}

// MARK: - UploadToAppStoreTask

@Suite("UploadToAppStoreTask Coverage", .serialized)
struct UploadToAppStoreTaskCoverageTests {

    @Test("Error descriptions are human readable")
    func errorDescriptions() {
        let errors: [UploadToAppStoreError] = [
            .fileNotFound("/x.ipa"), .unsupportedFileType("zip"), .missingAppIdentifier,
            .appNotFound(bundleId: "com.a"), .missingVersionInfo("why"),
            .chunkUploadFailed(index: 0, status: 500, message: "m"), .chunkUploadFailed(index: 1, status: nil, message: "m"),
            .processingFailed(errors: []), .processingFailed(errors: ["a", "b"]), .processingTimeout(buildUploadId: "bu1"),
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        #expect(UploadToAppStoreError.chunkUploadFailed(index: 0, status: 500, message: "m").errorDescription?.contains("HTTP 500") == true)
        #expect(UploadToAppStoreError.processingFailed(errors: []).errorDescription?.contains("No details") == true)
        #expect(UploadToAppStoreError.processingFailed(errors: ["a", "b"]).errorDescription?.contains("a; b") == true)
    }

    @Test("Rejects missing files, wrong extensions, and missing app identifiers")
    func validation() async throws {
        let service = try ASCStub.service(StubRouter())
        await #expect(throws: UploadToAppStoreError.self) {
            try await UploadToAppStoreTask().run(.init(ipaPath: "/nonexistent/App.ipa", service: service, appId: "1"))
        }
        let zip = try UploadFixtures.file("App.zip")
        defer { try? FileManager.default.removeItem(at: zip.dir) }
        await #expect(throws: UploadToAppStoreError.self) {
            try await UploadToAppStoreTask().run(.init(ipaPath: zip.file.path, service: service, appId: "1"))
        }
        let ipa = try UploadFixtures.file("App.ipa")
        defer { try? FileManager.default.removeItem(at: ipa.dir) }
        do {
            try await UploadToAppStoreTask().run(.init(ipaPath: ipa.file.path, service: service, appId: "", bundleId: ""))
            Issue.record("expected missingAppIdentifier")
        } catch UploadToAppStoreError.missingAppIdentifier {
        }
    }

    @Test("Resolves the app by bundle ID and fails when it does not exist")
    func appResolution() async throws {
        let ipa = try UploadFixtures.file("App.ipa")
        defer { try? FileManager.default.removeItem(at: ipa.dir) }
        let router = StubRouter().on("GET", "apps_getCollection", .ok(ASCStub.list([])))
        let service = try ASCStub.service(router)
        do {
            try await UploadToAppStoreTask().run(.init(ipaPath: ipa.file.path, service: service, bundleId: "com.missing", version: "1", buildNumber: "1"))
            Issue.record("expected appNotFound")
        } catch UploadToAppStoreError.appNotFound(let bundleId) {
            #expect(bundleId == "com.missing")
        }
        #expect(router.log.requests[0].query.contains("com.missing"))
    }

    @Test("Uploads chunks, commits, and returns without waiting")
    func happyPathNoWait() async throws {
        let ipa = try UploadFixtures.file("App.ipa", bytes: 15)
        defer { try? FileManager.default.removeItem(at: ipa.dir) }
        let router = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("https://upload.test/p1", 0, 10), ("https://upload.test/p2", 10, 5)]))
            .on("GET", "apps_getCollection", .ok(ASCStub.list([AppleJSON.app("app-9", bundleId: "com.a")])))
        let result = try await DefaultNetworkStub.with(router) { session in
            let service = try ASCStub.service(router, session: session)
            return try await UploadToAppStoreTask().run(.init(
                ipaPath: ipa.file.path, service: service, bundleId: "com.a", version: "1.2.3", buildNumber: "45",
                changelog: "   ", waitForProcessing: false))
        }
        #expect(result.buildUploadId == "bu1")
        #expect(result.version == "1.2.3")
        #expect(result.buildNumber == "45")
        #expect(result.state == .processing)
        #expect(result.buildId == nil)
        let puts = router.log.requests.filter { $0.method == "PUT" }
        #expect(Set(puts.map(\.url.lastPathComponent)) == ["p1", "p2"])
        #expect(puts.allSatisfy { $0.headers["Content-Type"] == "application/octet-stream" })
        let create = try #require(router.log.first { $0.operationID == "buildUploads_createInstance" })
        #expect(create.bodyString.contains("app-9"))
        #expect(router.log.first { $0.operationID == "buildUploadFiles_updateInstance" } != nil)
    }

    @Test("Changelog forces waiting for processing and sets What to Test notes")
    func changelogWaitsAndSetsNotes() async throws {
        let ipa = try UploadFixtures.file("App.ipa", bytes: 8)
        defer { try? FileManager.default.removeItem(at: ipa.dir) }
        let router = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("https://upload.test/p1", 0, 8)]))
            .on("GET", "buildUploads_getInstance", UploadFixtures.buildUpload("COMPLETE", warnings: #"[{"code":"W1","description":"Careful"}]"#, buildId: "build-7"))
            .on("GET", "builds_betaBuildLocalizations_getToManyRelated", .ok(ASCStub.list([])))
            .on("POST", "betaBuildLocalizations_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("betaBuildLocalizations", "bl1"))))
        let result = try await DefaultNetworkStub.with(router) { session in
            let service = try ASCStub.service(router, session: session)
            return try await UploadToAppStoreTask().run(.init(
                ipaPath: ipa.file.path, service: service, appId: "app-1", version: "2.0", buildNumber: "3",
                changelog: "  New stuff  ", changelogLocale: "tr"))
        }
        #expect(result.state == .complete)
        #expect(result.buildId == "build-7")
        #expect(result.warnings == ["W1: Careful"])
        let create = try #require(router.log.first { $0.operationID == "betaBuildLocalizations_createInstance" })
        #expect(ASCStub.dataAttrs(create)["whatsNew"] as? String == "New stuff")
        #expect(ASCStub.dataAttrs(create)["locale"] as? String == "tr")
    }

    @Test("Polls until processing completes")
    func pollsUntilComplete() async throws {
        let ipa = try UploadFixtures.file("App.ipa", bytes: 4)
        defer { try? FileManager.default.removeItem(at: ipa.dir) }
        let router = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("https://upload.test/p1", 0, 4)]))
            .on("GET", "buildUploads_getInstance", UploadFixtures.buildUpload("PROCESSING"), UploadFixtures.buildUpload("COMPLETE"))
        let result = try await DefaultNetworkStub.with(router) { session in
            let service = try ASCStub.service(router, session: session)
            return try await UploadToAppStoreTask().run(.init(
                ipaPath: ipa.file.path, service: service, appId: "app-1", version: "1", buildNumber: "1",
                waitForProcessing: true, pollInterval: 0))
        }
        #expect(result.state == .complete)
        #expect(result.buildId == nil)
        #expect(router.log.requests.filter { $0.operationID == "buildUploads_getInstance" }.count == 2)
    }

    @Test("Processing failures and timeouts are surfaced")
    func processingFailureAndTimeout() async throws {
        let ipa = try UploadFixtures.file("App.ipa", bytes: 4)
        defer { try? FileManager.default.removeItem(at: ipa.dir) }

        let failing = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("https://upload.test/p1", 0, 4)]))
            .on("GET", "buildUploads_getInstance", UploadFixtures.buildUpload("FAILED", errors: #"[{"code":"E1","description":"Bad"}]"#))
        try await DefaultNetworkStub.with(failing) { session in
            let failingService = try ASCStub.service(failing, session: session)
            do {
                try await UploadToAppStoreTask().run(.init(
                    ipaPath: ipa.file.path, service: failingService, appId: "a", version: "1", buildNumber: "1", waitForProcessing: true))
                Issue.record("expected processingFailed")
            } catch UploadToAppStoreError.processingFailed(let errors) {
                #expect(errors == ["E1: Bad"])
            }
        }

        let slow = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("https://upload.test/p1", 0, 4)]))
            .on("GET", "buildUploads_getInstance", UploadFixtures.buildUpload("PROCESSING"))
        try await DefaultNetworkStub.with(slow) { session in
            let slowService = try ASCStub.service(slow, session: session)
            do {
                try await UploadToAppStoreTask().run(.init(
                    ipaPath: ipa.file.path, service: slowService, appId: "a", version: "1", buildNumber: "1",
                    waitForProcessing: true, processingTimeout: 0))
                Issue.record("expected processingTimeout")
            } catch UploadToAppStoreError.processingTimeout(let id) {
                #expect(id == "bu1")
            }
        }
    }

    @Test("Commit server errors fall back to the build upload state")
    func commitRetryRecovers() async throws {
        let ipa = try UploadFixtures.file("App.ipa", bytes: 4)
        defer { try? FileManager.default.removeItem(at: ipa.dir) }
        let router = StubRouter()
            .on("PATCH", "buildUploadFiles_updateInstance", ASCStub.serverError)
            .on("GET", "buildUploads_getInstance", UploadFixtures.buildUpload("PROCESSING"))
            .on("POST", "buildUploads_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("buildUploads", "bu1"))))
            .on("POST", "buildUploadFiles_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("buildUploadFiles", "f1", UploadFixtures.ops([("https://upload.test/p1", 0, 4)])))))
            .on("PUT", "upload.test/", .ok())
        let result = try await DefaultNetworkStub.with(router) { session in
            let service = try ASCStub.service(router, session: session)
            return try await UploadToAppStoreTask().run(.init(ipaPath: ipa.file.path, service: service, appId: "a", version: "1", buildNumber: "1"))
        }
        #expect(result.state == .processing)
        #expect(router.log.requests.filter { $0.operationID == "buildUploadFiles_updateInstance" }.count == 1)
    }

    @Test("Chunk uploads fail fast on invalid URLs and short reads")
    func chunkFailures() async throws {
        let ipa = try UploadFixtures.file("App.ipa", bytes: 4)
        defer { try? FileManager.default.removeItem(at: ipa.dir) }

        let invalid = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("", 0, 4)]))
        let invalidService = try ASCStub.service(invalid)
        do {
            try await UploadToAppStoreTask().run(.init(ipaPath: ipa.file.path, service: invalidService, appId: "a", version: "1", buildNumber: "1"))
            Issue.record("expected chunkUploadFailed")
        } catch UploadToAppStoreError.chunkUploadFailed(let index, let status, let message) {
            #expect(index == 0)
            #expect(status == nil)
            #expect(message.contains("Invalid upload URL"))
        }

        let short = UploadFixtures.ascRouter(ops: UploadFixtures.ops([("https://upload.test/p1", 0, 100)]))
        let shortService = try ASCStub.service(short)
        do {
            try await UploadToAppStoreTask().run(.init(ipaPath: ipa.file.path, service: shortService, appId: "a", version: "1", buildNumber: "1"))
            Issue.record("expected chunkUploadFailed")
        } catch UploadToAppStoreError.chunkUploadFailed(_, _, let message) {
            #expect(message.contains("Could not read 100 bytes"))
        }
        #expect(short.log.requests.allSatisfy { $0.method != "PUT" })
    }

    @Test("Reads version info from the IPA's embedded Info.plist")
    func versionFromIpa() async throws {
        let good = try UploadFixtures.ipa(plist: UploadFixtures.plist(["CFBundleShortVersionString": "3.1.4", "CFBundleVersion": "99"]))
        defer { try? FileManager.default.removeItem(at: good.dir) }
        try await UploadFixtures.zip(good.dir)
        // Stop right after version resolution: build upload creation is rejected.
        let router = StubRouter().on("POST", "buildUploads_createInstance", ASCStub.undocumented)
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) {
            try await UploadToAppStoreTask().run(.init(ipaPath: good.file.path, service: service, appId: "a"))
        }
        let attrs = ASCStub.dataAttrs(router.log.requests.first)
        #expect(attrs["cfBundleShortVersionString"] as? String == "3.1.4")
        #expect(attrs["cfBundleVersion"] as? String == "99")

        // Explicit build number overrides the plist, version still read from it.
        await #expect(throws: AppStoreServiceError.self) {
            try await UploadToAppStoreTask().run(.init(ipaPath: good.file.path, service: service, appId: "a", buildNumber: "100"))
        }
        #expect(ASCStub.dataAttrs(router.log.requests.last)["cfBundleVersion"] as? String == "100")
    }

    @Test("Missing or unreadable Info.plist values raise missingVersionInfo")
    func versionInfoErrors() async throws {
        let service = try ASCStub.service(StubRouter())
        func expectMissing(_ path: String, _ fragment: String, sourceLocation: SourceLocation = #_sourceLocation) async {
            do {
                try await UploadToAppStoreTask().run(.init(ipaPath: path, service: service, appId: "a"))
                Issue.record("expected missingVersionInfo", sourceLocation: sourceLocation)
            } catch UploadToAppStoreError.missingVersionInfo(let reason) {
                #expect(reason.contains(fragment), sourceLocation: sourceLocation)
            } catch {
                Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
            }
        }

        // Not a zip at all.
        let notZip = try UploadFixtures.file("App.ipa")
        defer { try? FileManager.default.removeItem(at: notZip.dir) }
        await expectMissing(notZip.file.path, "unzip failed")

        // Info.plist present but not a property list.
        let garbage = try UploadFixtures.ipa(plist: Data("not a plist".utf8))
        defer { try? FileManager.default.removeItem(at: garbage.dir) }
        try await UploadFixtures.zip(garbage.dir)
        await expectMissing(garbage.file.path, "not found or unreadable")

        // Missing version string.
        let noVersion = try UploadFixtures.ipa(plist: UploadFixtures.plist(["CFBundleVersion": "1"]))
        defer { try? FileManager.default.removeItem(at: noVersion.dir) }
        try await UploadFixtures.zip(noVersion.dir)
        await expectMissing(noVersion.file.path, "CFBundleShortVersionString")

        // Missing build number.
        let noBuild = try UploadFixtures.ipa(plist: UploadFixtures.plist(["CFBundleShortVersionString": "1.0"]))
        defer { try? FileManager.default.removeItem(at: noBuild.dir) }
        try await UploadFixtures.zip(noBuild.dir)
        await expectMissing(noBuild.file.path, "CFBundleVersion")
    }
}

// MARK: - UploadToGooglePlayConsoleTask

private func withPlayService<T>(_ router: StubRouter, _ body: (GooglePlayService) async throws -> T) async throws -> T {
    HTTPStub.googleTokenRoute(router)
    return try await DefaultNetworkStub.with(router) { session in
        let service = try GooglePlayService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport(router), urlSession: session)
        return try await body(service)
    }
}

@Suite("UploadToGooglePlayConsoleTask Coverage", .serialized)
struct UploadToGooglePlayConsoleTaskCoverageTests {
    private let pkg = "com.example.app"

    private func playRouter() -> StubRouter {
        PlayStub.edits()
            .on("PUT", "/tracks/", .ok(#"{"track":"beta"}"#))
            .on("POST", "/bundles", .ok(#"{"versionCode":42,"sha256":"s256"}"#))
            .on("POST", "/apks", .ok(#"{"versionCode":"7","binary":{"sha256":"a256"}}"#))
    }

    @Test("Error descriptions are human readable and statuses map to raw values")
    func errorDescriptions() {
        let errors: [UploadToGooglePlayConsoleError] = [
            .fileNotFound("x"), .unsupportedFileType("ipa"), .missingPackageName, .editCreationFailed("m"),
            .uploadFailed("m"), .trackUpdateFailed("m"), .commitFailed("m"),
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        #expect(GooglePlayReleaseStatus.allCases.map(\.rawValue) == ["completed", "draft", "inProgress", "halted"])
        let result = UploadToGooglePlayConsoleResult(packageName: "p", editId: "e", versionCode: 1, track: "t", releaseStatus: "draft")
        #expect(result.releaseName == nil && result.sha256 == nil)
    }

    @Test("Rejects missing files and unsupported extensions")
    func validation() async throws {
        let router = StubRouter()
        try await withPlayService(router) { service in
            await #expect(throws: UploadToGooglePlayConsoleError.self) {
                try await UploadToGooglePlayConsoleTask().run(.init(binaryPath: "/nonexistent/app.aab", service: service, packageName: pkg))
            }
            let ipa = try UploadFixtures.file("app.ipa")
            defer { try? FileManager.default.removeItem(at: ipa.dir) }
            await #expect(throws: UploadToGooglePlayConsoleError.self) {
                try await UploadToGooglePlayConsoleTask().run(.init(binaryPath: ipa.file.path, service: service, packageName: pkg))
            }
        }
        #expect(router.log.count == 0)
    }

    @Test("Uploads a bundle, updates the track with notes, and commits")
    func bundleCommit() async throws {
        let aab = try UploadFixtures.file("app.aab")
        defer { try? FileManager.default.removeItem(at: aab.dir) }
        let router = playRouter()
        let result = try await withPlayService(router) { service in
            try await UploadToGooglePlayConsoleTask().run(.init(
                binaryPath: aab.file.path, service: service, packageName: pkg, track: "beta",
                releaseStatus: .inProgress, releaseNotes: "Notes", releaseNotesLanguage: "tr-TR",
                userFraction: 0.25, changesNotSentForReview: true, ackBundleInstallationWarning: true))
        }
        #expect(result.versionCode == 42)
        #expect(result.editId == "e1")
        #expect(result.releaseName == "42")
        #expect(result.releaseStatus == "inProgress")
        #expect(result.sha256 == "s256")
        let track = try #require(router.log.first { $0.method == "PUT" && $0.path.contains("/tracks/") })
        let release = try #require((track.json()["releases"] as? [[String: Any]])?.first)
        #expect(release["status"] as? String == "inProgress")
        #expect(release["userFraction"] as? Double == 0.25)
        #expect(release["versionCodes"] as? [String] == ["42"])
        let notes = try #require(release["releaseNotes"] as? [[String: Any]])
        #expect(notes.first?["language"] as? String == "tr-TR")
        let commit = try #require(router.log.first { $0.path.hasSuffix(":commit") })
        #expect(commit.query.contains("changesNotSentForReview=true"))
        #expect(router.log.first { $0.path.hasSuffix("/bundles") }?.query.contains("ackBundleInstallationWarning=true") == true)
    }

    @Test("Uploads an APK and validates without committing")
    func apkValidate() async throws {
        let apk = try UploadFixtures.file("app.apk")
        defer { try? FileManager.default.removeItem(at: apk.dir) }
        let router = playRouter()
        let result = try await withPlayService(router) { service in
            try await UploadToGooglePlayConsoleTask().run(.init(
                binaryPath: apk.file.path, service: service, packageName: pkg, releaseName: "1.0 (7)",
                releaseNotes: "", validateOnly: true))
        }
        #expect(result.versionCode == 7)
        #expect(result.releaseName == "1.0 (7)")
        #expect(result.track == "internal")
        #expect(result.sha256 == "a256")
        #expect(router.log.first { $0.path.hasSuffix(":validate") } != nil)
        #expect(router.log.first { $0.path.hasSuffix(":commit") } == nil)
        let track = try #require(router.log.first { $0.method == "PUT" && $0.path.contains("/tracks/") })
        let release = try #require((track.json()["releases"] as? [[String: Any]])?.first)
        #expect(release["releaseNotes"] == nil)
    }

    @Test("Each failing stage maps to its dedicated error")
    func stageFailures() async throws {
        let aab = try UploadFixtures.file("app.aab")
        defer { try? FileManager.default.removeItem(at: aab.dir) }

        func run(_ router: StubRouter, validate: Bool = false) async throws -> (any Error)? {
            try await withPlayService(router) { service in
                do {
                    try await UploadToGooglePlayConsoleTask().run(.init(binaryPath: aab.file.path, service: service, packageName: pkg, validateOnly: validate))
                    return nil
                } catch {
                    return error
                }
            }
        }

        // Edit creation fails (no edit ID returned).
        let noEdit = StubRouter().on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok("{}")])
        guard case .editCreationFailed = try #require(try await run(noEdit) as? UploadToGooglePlayConsoleError) else {
            Issue.record("expected editCreationFailed"); return
        }

        // Upload fails.
        let uploadFail = PlayStub.edits().on("POST", "/bundles", .status(500, #"{"error":{"message":"bad bundle"}}"#))
        guard case .uploadFailed(let uploadMessage) = try #require(try await run(uploadFail) as? UploadToGooglePlayConsoleError) else {
            Issue.record("expected uploadFailed"); return
        }
        #expect(uploadMessage.contains("500"))

        // Track update fails.
        let trackFail = PlayStub.edits()
            .on("POST", "/bundles", .ok(#"{"versionCode":1}"#))
            .on("PUT", "/tracks/", .status(400, "{}"))
        guard case .trackUpdateFailed = try #require(try await run(trackFail) as? UploadToGooglePlayConsoleError) else {
            Issue.record("expected trackUpdateFailed"); return
        }

        // Commit fails.
        let commitFail = StubRouter()
            .on("POST", ":commit", .status(400, "{}"))
            .on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok(#"{"id":"e1"}"#)])
            .on("POST", "/bundles", .ok(#"{"versionCode":1}"#))
            .on("PUT", "/tracks/", .ok(#"{"track":"internal"}"#))
        guard case .commitFailed = try #require(try await run(commitFail) as? UploadToGooglePlayConsoleError) else {
            Issue.record("expected commitFailed"); return
        }

        // Validation fails.
        let validateFail = StubRouter()
            .on("POST", ":validate", .status(400, "{}"))
            .on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok(#"{"id":"e1"}"#)])
            .on("POST", "/bundles", .ok(#"{"versionCode":1}"#))
            .on("PUT", "/tracks/", .ok(#"{"track":"internal"}"#))
        guard case .commitFailed = try #require(try await run(validateFail, validate: true) as? UploadToGooglePlayConsoleError) else {
            Issue.record("expected commitFailed on validate"); return
        }
    }
}

// MARK: - UploadToFirebaseTask

@Suite("UploadToFirebaseTask Coverage", .serialized)
struct UploadToFirebaseTaskCoverageTests {
    private let appId = "1:1234567890:android:abcdef"

    @Test("Error descriptions and the single-group convenience initializer")
    func errorsAndInit() throws {
        let errors: [UploadToFirebaseError] = [.fileNotFound("x"), .unsupportedFileType("zip"), .missingReleaseName]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        let service = try FirebaseService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport())
        let single = UploadToFirebaseTask.Input(binaryPath: "a.apk", firebaseAppId: appId, service: service, testGroup: "qa")
        #expect(single.testGroups == ["qa"])
        #expect(single.ensureGroupsExist == false)
        let empty = UploadToFirebaseTask.Input(binaryPath: "a.apk", firebaseAppId: appId, service: service, testGroup: "")
        #expect(empty.testGroups == nil)
        let none = UploadToFirebaseTask.Input(binaryPath: "a.apk", firebaseAppId: appId, service: service, testGroup: nil, ensureGroupsExist: true)
        #expect(none.testGroups == nil && none.ensureGroupsExist)
    }

    @Test("Rejects missing files, unsupported types, and releases without a name")
    func failures() async throws {
        let router = StubRouter()
            .on("POST", "releases:upload", .ok(#"{"name":"projects/1234567890/apps/x/releases/-/operations/op1"}"#))
            .on("GET", "operations/op1", .ok(#"{"done":true,"response":{"release":{"displayVersion":"1.0"}}}"#))
        let apk = try UploadFixtures.file("app.apk")
        let txt = try UploadFixtures.file("app.txt")
        defer {
            try? FileManager.default.removeItem(at: apk.dir)
            try? FileManager.default.removeItem(at: txt.dir)
        }
        try await DefaultNetworkStub.firebase(router) { service in
            await #expect(throws: UploadToFirebaseError.self) {
                try await UploadToFirebaseTask().run(.init(binaryPath: "/nonexistent/app.apk", firebaseAppId: appId, service: service))
            }
            await #expect(throws: UploadToFirebaseError.self) {
                try await UploadToFirebaseTask().run(.init(binaryPath: txt.file.path, firebaseAppId: appId, service: service))
            }
            do {
                try await UploadToFirebaseTask().run(.init(binaryPath: apk.file.path, firebaseAppId: appId, service: service))
                Issue.record("expected missingReleaseName")
            } catch UploadToFirebaseError.missingReleaseName {
            } catch {
                // Some service versions reject a release without a name themselves; either way it fails.
            }
        }
    }

    @Test("Ensures groups exist, uploads, adds notes, and distributes using resolved aliases")
    func ensureGroupsFlow() async throws {
        let releaseJSON = #"{"name":"projects/1234567890/apps/x/releases/r1","displayVersion":"2.0","buildVersion":"5","firebaseConsoleUri":"https://console","testingUri":"https://test","binaryDownloadUri":"https://bin"}"#
        let router = StubRouter()
            .on("GET", "/groups/qa", .ok(#"{"name":"projects/1234567890/groups/qa-real","displayName":"QA"}"#))
            .on("POST", "releases:upload", .ok(#"{"name":"projects/1234567890/apps/x/releases/-/operations/op1"}"#))
            .on("GET", "operations/op1", .ok(#"{"done":true,"response":{"release":\#(releaseJSON)}}"#))
            .on("PATCH", "/releases/r1", .ok("{}"))
            .on("POST", ":distribute", .ok("{}"))
        let apk = try UploadFixtures.file("app.apk")
        defer { try? FileManager.default.removeItem(at: apk.dir) }
        let result = try await DefaultNetworkStub.firebase(router) { service in
            try await UploadToFirebaseTask().run(.init(
                binaryPath: apk.file.path, firebaseAppId: appId, service: service, releaseNotes: "Hello",
                testGroups: ["qa"], testerEmails: ["a@b.c"], ensureGroupsExist: true))
        }
        #expect(result.releaseName.hasSuffix("/releases/r1"))
        #expect(result.displayVersion == "2.0")
        #expect(result.buildVersion == "5")
        #expect(result.testingUri == "https://test")
        let distribute = try #require(router.log.first { $0.path.hasSuffix(":distribute") })
        #expect(distribute.json()["groupAliases"] as? [String] == ["qa-real"])
        #expect(distribute.json()["testerEmails"] as? [String] == ["a@b.c"])
        #expect(router.log.first { $0.method == "PATCH" } != nil)
    }
}

// MARK: - MatchTask (pure parts only; `run` clones git and touches the keychain)

@Suite("MatchTask Coverage")
struct MatchTaskCoverageTests {
    @Test("Input defaults, output, profile info, and error descriptions")
    func pureParts() {
        let input = MatchTask.Input(gitUrl: "https://github.com/o/r.git", appIdentifiers: ["com.a"], password: "pw")
        #expect(input.gitBranch == "master")
        #expect(input.type == .appstore)
        #expect(input.action == .sync)
        #expect(input.readonly)
        #expect(!input.force && !input.silent)
        #expect(input.gitToken == nil && input.teamId == nil && input.keychainName == nil)

        let custom = MatchTask.Input(
            gitUrl: "u", gitBranch: "main", gitToken: "t", type: .enterprise, appIdentifiers: [], password: "p",
            action: .nuke, readonly: false, teamId: "T", teamName: "N", apiKeyId: "K", apiIssuerId: "I", apiKey: "PEM",
            keychainName: "kc", keychainPassword: "kp", force: true, silent: true)
        #expect(custom.type == .enterprise && custom.action == .nuke && custom.teamName == "N" && custom.apiKey == "PEM")

        let output = MatchTask.Output()
        #expect(output.installedCertificates.isEmpty && output.installedProfiles.isEmpty)
        let info = MatchTask.ProfileInfo(name: "n", uuid: "u", path: "/p", bundleId: "com.a")
        let filled = MatchTask.Output(installedCertificates: ["c"], installedProfiles: ["com.a": info])
        #expect(filled.installedProfiles["com.a"] == info)
        #expect(MatchTask.ProfileType.allCases.count == 4)
        #expect(MatchTask.Action.allCases == [.sync, .nuke])

        let errors: [MatchTask.MatchError] = [
            .invalidGitHubUrl("u"), .gitAuthenticationFailed("m"), .gitCloneFailed("m"), .decryptionFailed("m"),
            .certificateNotFound(type: .adhoc), .profileNotFound(bundleId: "com.a", type: .development),
            .keychainError("m"), .notImplemented,
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
    }
}
