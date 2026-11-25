import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import AppleServices
import GoogleServices
import Testing
@testable import appitool

// MARK: - Shared JSON

private enum CheckJSON {
    static let iosAppId = "1:1234567890:ios:abcdef"
    static let androidAppId = "1:1234567890:android:abcdef"

    static let iosApp = #"{"name":"projects/p/iosApps/x","appId":"1:1234567890:ios:abcdef","bundleId":"com.example.ios","displayName":"iOS App","projectId":"p","appStoreId":"123","teamId":"TEAM","state":"ACTIVE"}"#
    static let androidApp = #"{"name":"projects/p/androidApps/x","appId":"1:1234567890:android:abcdef","packageName":"com.example.android","displayName":"Android App","projectId":"p","state":"ACTIVE"}"#
    static let releases = #"{"releases":[{"name":"projects/1/apps/x/releases/r1","displayVersion":"4.5.6","buildVersion":"77"}]}"#

    static func build(_ id: String = "b1", version: String = "42", minOs: String? = nil) -> String {
        var attrs = #""version":"\#(version)""#
        if let minOs { attrs += #","minOsVersion":"\#(minOs)""# }
        return ASCStub.res("builds", id, "{\(attrs)}")
    }

    static let preRelease = ASCStub.res("preReleaseVersions", "p1", #"{"version":"2.1.0","platform":"IOS"}"#)

    static let tracks = """
    {"tracks":[
      {"track":"production","releases":[{"name":"1.2","versionCodes":["10","x"]},{"name":"no-codes"}]},
      {"track":"internal","releases":[{"name":"","versionCodes":["20"]},{"name":"2.0","versionCodes":["15"]}]},
      {"track":"beta"}
    ]}
    """
}

private func playService(_ router: StubRouter, session: URLSession) throws -> GooglePlayService {
    try GooglePlayService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport(router), urlSession: session)
}

// MARK: - GetLatestBuildNumberTask

@Suite("GetLatestBuildNumberTask Coverage", .serialized)
struct GetLatestBuildNumberTaskCoverageTests {

    @Test("Error descriptions are human readable")
    func errorDescriptions() {
        let errors: [GetLatestBuildNumberError] = [
            .appNotFound(identifier: "x"), .apiError("m"), .unauthorized("m"), .developmentNotSupported, .missingConfiguration("m"),
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        #expect(LatestBuildInfo(version: "1", buildNumber: "2") == LatestBuildInfo(version: "1", buildNumber: "2"))
    }

    @Test("Missing configuration and development distribution are rejected")
    func configurationErrors() async throws {
        let task = GetLatestBuildNumberTask()
        let firebase = try FirebaseService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport())
        let inputs: [GetLatestBuildNumberTask.Input] = [
            .init(target: .ios(), distribution: .development),
            .init(target: .ios(bundleId: ""), distribution: .appstore),
            .init(target: .ios(bundleId: "com.a"), distribution: .appstore),
            .init(target: .android(packageName: ""), distribution: .appstore),
            .init(target: .android(packageName: "com.a"), distribution: .appstore),
            .init(target: .ios(firebaseAppId: ""), distribution: .adhoc),
            .init(target: .ios(firebaseAppId: "1:1:ios:a"), distribution: .adhoc),
            .init(target: .android(firebaseAppId: ""), distribution: .adhoc),
            .init(target: .android(firebaseAppId: "1:1:android:a"), distribution: .adhoc),
        ]
        for input in inputs {
            await #expect(throws: GetLatestBuildNumberError.self) { try await task.run(input) }
        }
        _ = firebase
    }

    @Test("TestFlight: resolves marketing version from the included pre-release version")
    func testFlightWithPreRelease() async throws {
        let router = StubRouter()
            .on("GET", "apps_getCollection", .ok(ASCStub.list([AppleJSON.app("app-1", bundleId: "com.a")])))
            .on("GET", "builds_getCollection", .ok(ASCStub.list([CheckJSON.build(minOs: "15.0")], included: [CheckJSON.preRelease])))
        let info = try await GetLatestBuildNumberTask().run(.init(target: .ios(bundleId: "com.a", service: try ASCStub.service(router))))
        #expect(info == LatestBuildInfo(version: "2.1.0", buildNumber: "42"))
        let builds = try #require(router.log.first { $0.operationID == "builds_getCollection" })
        #expect(builds.query.contains("app-1"))
        #expect(builds.query.contains("-uploadedDate"))
    }

    @Test("TestFlight: falls back to minOsVersion, defaults with no builds, and reports missing apps")
    func testFlightFallbacks() async throws {
        let router = StubRouter()
            .on("GET", "apps_getCollection",
                .ok(ASCStub.list([AppleJSON.app("app-1")])),
                .ok(ASCStub.list([AppleJSON.app("app-1")])),
                .ok(ASCStub.list([AppleJSON.app("app-1")])),
                .ok(ASCStub.list([])),
                ASCStub.undocumented)
            .on("GET", "builds_getCollection",
                .ok(ASCStub.list([CheckJSON.build(version: "9", minOs: "16.0")])),
                .ok(ASCStub.list([])),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let task = GetLatestBuildNumberTask()
        let input = GetLatestBuildNumberTask.Input(target: .ios(bundleId: "com.a", service: service))
        #expect(try await task.run(input) == LatestBuildInfo(version: "16.0", buildNumber: "9"))
        #expect(try await task.run(input) == LatestBuildInfo(version: "1.0.0", buildNumber: "0"))
        do {
            try await task.run(input)
            Issue.record("expected apiError for builds")
        } catch GetLatestBuildNumberError.apiError(let message) {
            #expect(message.contains("builds"))
        }
        do {
            try await task.run(input)
            Issue.record("expected appNotFound")
        } catch GetLatestBuildNumberError.appNotFound(let identifier) {
            #expect(identifier == "com.a")
        }
        do {
            try await task.run(input)
            Issue.record("expected apiError for apps")
        } catch GetLatestBuildNumberError.apiError(let message) {
            #expect(message.contains("app details"))
        }
    }

    @Test("Google Play: picks the highest version code, honoring the track filter")
    func googlePlayTracks() async throws {
        let router = StubRouter()
            .on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok(#"{"id":"e1"}"#)])
            .on("GET", where: { $0.path.hasSuffix("/edits/e1/tracks") }, [.ok(CheckJSON.tracks)])
            .on("DELETE", where: { $0.path.hasSuffix("/edits/e1") }, [PlayStub.noContent])
        HTTPStub.googleTokenRoute(router)
        try await HTTPStub.withSession(router) { session in
            let service = try playService(router, session: session)
            let task = GetLatestBuildNumberTask()
            let all = try await task.run(.init(target: .android(packageName: "com.a", service: service)))
            #expect(all == LatestBuildInfo(version: "1.2", buildNumber: "20"))
            let production = try await task.run(.init(target: .android(packageName: "com.a", service: service, track: "PRODUCTION")))
            #expect(production == LatestBuildInfo(version: "1.2", buildNumber: "10"))
            let beta = try await task.run(.init(target: .android(packageName: "com.a", service: service, track: "beta")))
            #expect(beta == LatestBuildInfo(version: "1.0.0", buildNumber: "0"))
        }
    }

    @Test("Google Play: edit and track failures become apiError")
    func googlePlayFailures() async throws {
        let router = StubRouter()
            .on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok("{}"), .ok(#"{"id":"e1"}"#)])
            .on("GET", where: { $0.path.hasSuffix("/tracks") }, [.status(404, "{}")])
        HTTPStub.googleTokenRoute(router)
        try await HTTPStub.withSession(router) { session in
            let service = try playService(router, session: session)
            let input = GetLatestBuildNumberTask.Input(target: .android(packageName: "com.a", service: service))
            do {
                try await GetLatestBuildNumberTask().run(input)
                Issue.record("expected edit failure")
            } catch GetLatestBuildNumberError.apiError(let message) {
                #expect(message.contains("edit session"))
            }
            do {
                try await GetLatestBuildNumberTask().run(input)
                Issue.record("expected tracks failure")
            } catch GetLatestBuildNumberError.apiError(let message) {
                #expect(message.contains("release tracks"))
            }
        }
    }

    @Test("Firebase App Distribution: latest release or defaults for both platforms")
    func firebaseReleases() async throws {
        let router = StubRouter().on("GET", "/releases",
            .ok(CheckJSON.releases),
            .ok(#"{"releases":[{"name":"projects/1/apps/x/releases/r2"}]}"#),
            .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let task = GetLatestBuildNumberTask()
            let ios = try await task.run(.init(target: .ios(firebaseAppId: CheckJSON.iosAppId, firebaseService: service), distribution: .adhoc))
            #expect(ios == LatestBuildInfo(version: "4.5.6", buildNumber: "77"))
            let partial = try await task.run(.init(target: .android(firebaseAppId: CheckJSON.androidAppId, firebaseService: service), distribution: .adhoc))
            #expect(partial == LatestBuildInfo(version: "1.0.0", buildNumber: "0"))
            let empty = try await task.run(.init(target: .android(firebaseAppId: CheckJSON.androidAppId, firebaseService: service), distribution: .adhoc))
            #expect(empty == LatestBuildInfo(version: "1.0.0", buildNumber: "0"))
        }
        #expect(router.log.requests.contains { $0.query.contains("pageSize=1") })
    }
}

// MARK: - GetFirebaseAppInfoTask

@Suite("GetFirebaseAppInfoTask Coverage", .serialized)
struct GetFirebaseAppInfoTaskCoverageTests {

    @Test("Error descriptions are human readable")
    func errorDescriptions() {
        let errors: [GetFirebaseAppInfoError] = [.missingAppId(platform: "iOS"), .unauthorized("m"), .appNotFound(identifier: "x"), .apiError("m")]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test("Fetches iOS and Android apps using the project number from the app ID")
    func fetchesApps() async throws {
        let router = StubRouter()
            .on("GET", "firebase.projects.iosApps.get", .ok(CheckJSON.iosApp))
            .on("GET", "firebase.projects.androidApps.get", .ok(CheckJSON.androidApp))
        try await DefaultNetworkStub.firebase(router) { service in
            guard case .ios(let ios) = try await GetFirebaseAppInfoTask().run(.init(platform: .ios, firebaseAppId: CheckJSON.iosAppId, service: service)) else {
                Issue.record("expected iOS output"); return
            }
            #expect(ios.bundleId == "com.example.ios")
            guard case .android(let android) = try await GetFirebaseAppInfoTask().run(.init(platform: .android, firebaseAppId: "plain", service: service)) else {
                Issue.record("expected Android output"); return
            }
            #expect(android.packageName == "com.example.android")
        }
        let ios = try #require(router.log.first { $0.operationID == "firebase.projects.iosApps.get" })
        #expect(ios.path.contains("projects/1234567890/iosApps/"))
        let android = try #require(router.log.first { $0.operationID == "firebase.projects.androidApps.get" })
        #expect(android.path.contains("projects/-/androidApps/plain"))
    }

    @Test("Missing IDs, 404s, and other statuses map to dedicated errors")
    func failures() async throws {
        let router = StubRouter()
            .on("GET", "firebase.projects.iosApps.get", .status(404, "{}"), .status(500, "{}"))
            .on("GET", "firebase.projects.androidApps.get", .status(404, "{}"), .status(403, "{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let task = GetFirebaseAppInfoTask()
            for platform in [GetFirebaseAppInfoTask.Platform.ios, .android] {
                do {
                    try await task.run(.init(platform: platform, firebaseAppId: "", service: service))
                    Issue.record("expected missingAppId")
                } catch GetFirebaseAppInfoError.missingAppId {}
                do {
                    try await task.run(.init(platform: platform, firebaseAppId: "1:1:x:y", service: service))
                    Issue.record("expected appNotFound")
                } catch GetFirebaseAppInfoError.appNotFound(let identifier) {
                    #expect(identifier == "1:1:x:y")
                }
                do {
                    try await task.run(.init(platform: platform, firebaseAppId: "1:1:x:y", service: service))
                    Issue.record("expected apiError")
                } catch GetFirebaseAppInfoError.apiError(let message) {
                    #expect(message.contains("HTTP"))
                }
            }
        }
    }
}

// MARK: - check ios / check android

@Suite("Check Commands Coverage", .serialized)
struct CheckCommandsCoverageTests {
    private func run<T: BaseCommand>(_ router: StubRouter, _ args: [String], as _: T.Type) async throws {
        HTTPStub.googleTokenRoute(router)
        let cmd: T = try CmdStub.parse(args)
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    @Test("check ios adhoc prints Firebase app info and the latest release")
    func iosAdhoc() async throws {
        let router = StubRouter()
            .on("GET", "/iosApps/", .ok(CheckJSON.iosApp))
            .on("GET", "/releases", .ok(CheckJSON.releases))
        try await run(router, ["check", "ios", "-b", "com.example.ios", "--firebase-app-id", CheckJSON.iosAppId] + CmdStub.googleCreds(), as: CheckIOSCommand.self)
        #expect(CmdStub.has(router, "GET", "/iosApps/"))
        #expect(CmdStub.has(router, "GET", "/releases"))
    }

    @Test("check ios adhoc tolerates release lookup failures and surfaces app lookup failures")
    func iosAdhocFailures() async throws {
        let tolerant = StubRouter()
            .on("GET", "/iosApps/", .ok(#"{"name":"x"}"#))
            .on("GET", "/releases", .status(500, "err"))
        try await run(tolerant, ["check", "ios", "-d", "adhoc", "-b", "com.a", "--firebase-app-id", CheckJSON.iosAppId] + CmdStub.googleCreds(), as: CheckIOSCommand.self)

        let missing = StubRouter().on("GET", "/iosApps/", .status(404, "{}"))
        await #expect(throws: GetFirebaseAppInfoError.self) {
            try await run(missing, ["check", "ios", "-b", "com.a", "--firebase-app-id", CheckJSON.iosAppId] + CmdStub.googleCreds(), as: CheckIOSCommand.self)
        }
    }

    @Test("check ios appstore prints the latest TestFlight build; development is a no-op")
    func iosAppStore() async throws {
        let router = StubRouter()
            .on("GET", "/v1/apps", .ok(ASCStub.list([AppleJSON.app("app-1", bundleId: "com.a")])))
            .on("GET", "/v1/builds", .ok(ASCStub.list([CheckJSON.build()], included: [CheckJSON.preRelease])))
        try await run(router, ["check", "ios", "-d", "appstore", "-b", "com.a"] + CmdStub.appleCreds(), as: CheckIOSCommand.self)
        #expect(CmdStub.has(router, "GET", "/v1/builds"))

        let none = StubRouter()
        try await run(none, ["check", "ios", "-d", "development", "-b", "com.a"], as: CheckIOSCommand.self)
        #expect(none.log.count == 0)
    }

    @Test("check android adhoc prints Firebase app info and the latest release")
    func androidAdhoc() async throws {
        let router = StubRouter()
            .on("GET", "/androidApps/", .ok(CheckJSON.androidApp))
            .on("GET", "/releases", .ok(CheckJSON.releases))
        try await run(router, ["check", "android", "--package-name", "com.example.android", "--firebase-app-id", CheckJSON.androidAppId] + CmdStub.googleCreds(), as: CheckAndroidCommand.self)
        #expect(CmdStub.has(router, "GET", "/androidApps/"))
        #expect(CmdStub.has(router, "GET", "/releases"))

        let missing = StubRouter().on("GET", "/androidApps/", .status(404, "{}"))
        await #expect(throws: GetFirebaseAppInfoError.self) {
            try await run(missing, ["check", "android", "--package-name", "com.a", "--firebase-app-id", CheckJSON.androidAppId] + CmdStub.googleCreds(), as: CheckAndroidCommand.self)
        }
    }

    @Test("check android appstore prints the latest Play build; development is a no-op")
    func androidAppStore() async throws {
        let router = StubRouter()
            .on("POST", where: { $0.path.hasSuffix("/edits") }, [.ok(#"{"id":"e1"}"#)])
            .on("GET", where: { $0.path.hasSuffix("/tracks") }, [.ok(CheckJSON.tracks)])
            .on("DELETE", where: { $0.path.hasSuffix("/edits/e1") }, [PlayStub.noContent])
        HTTPStub.googleTokenRoute(router)
        let cmd: CheckAndroidCommand = try CmdStub.parse(["check", "android", "-d", "appstore", "--package-name", "com.a"] + CmdStub.googleCreds())
        try await DefaultNetworkStub.with(router) { _ in
            try await cmd.execute()
        }
        #expect(router.log.requests.contains { $0.path.hasSuffix("/tracks") })
        #expect(router.log.requests.contains { $0.method == "DELETE" })

        let none = StubRouter()
        try await run(none, ["check", "android", "-d", "development", "--package-name", "com.a"], as: CheckAndroidCommand.self)
        #expect(none.log.requests.allSatisfy { !$0.path.contains("androidpublisher") })
    }
}

// MARK: - kokono

@Suite("Kokono Command Coverage", .serialized)
struct KokonoCommandCoverageTests {
    private func run(_ router: StubRouter, _ args: [String]) async throws {
        let cmd: KokonoCommand = try CmdStub.parse(["kokono"] + args)
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    @Test("Sends plaintext and E2E-encrypted notifications to the explicit URL")
    func sends() async throws {
        let router = StubRouter().on("POST", "kokono.test/notify", .ok(#"{"success":true}"#))
        try await run(router, ["-m", "Hello", "--title", "T", "--url", "https://kokono.test/notify?token=tok"])
        let plain = try #require(router.log.requests.first)
        #expect(plain.json()["token"] as? String == "tok")
        #expect(plain.json()["message"] as? String == "Hello")
        #expect(plain.json()["title"] as? String == "T")
        #expect(plain.query.isEmpty)

        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        try await run(router, ["-m", "Secret", "--url", "https://kokono.test/notify?token=tok", "--e2e", publicKey])
        let encrypted = try #require(router.log.requests.last)
        #expect(encrypted.json()["encrypted"] as? Int == 1)
        #expect((encrypted.json()["message"] as? [String: Any])?["ciphertext"] != nil)
    }

    @Test("Failures are wrapped in a CommandError")
    func failures() async throws {
        let failing = StubRouter().on("POST", "kokono.test/notify", .status(500, "boom"), .ok(#"{"success":false,"message":"nope"}"#))
        await #expect(throws: CommandError.self) {
            try await run(failing, ["-m", "x", "--url", "https://kokono.test/notify?token=tok"])
        }
        await #expect(throws: CommandError.self) {
            try await run(failing, ["-m", "x", "--url", "https://kokono.test/notify?token=tok"])
        }
        let none = StubRouter()
        await #expect(throws: CommandError.self) {
            try await run(none, ["-m", "x", "--url", "https://kokono.test/notify"])
        }
        await #expect(throws: CommandError.self) {
            try await run(none, ["-m", "x", "--url", "https://kokono.test/notify?token=t", "--e2e", "not base64!"])
        }
        await #expect(throws: CommandError.self) {
            try await run(none, ["-m", "x", "--url", "https://kokono.test/notify?token=t", "--e2e", Data("short".utf8).base64EncodedString()])
        }
        #expect(none.log.count == 0)
    }
}

// MARK: - self-update (release metadata & checksum paths only; never reaches binary replacement)

@Suite("SelfUpdate Command Coverage", .serialized)
struct SelfUpdateCommandCoverageTests {
    private func release(_ tag: String, assets: [String] = []) -> String {
        let list = assets.map {
            #"{"name":"\#($0)","url":"https://downloads.test/api/\#($0)","browser_download_url":"https://downloads.test/dl/\#($0)"}"#
        }
        return #"{"tag_name":"\#(tag)","name":"r","body":"b","assets":[\#(list.joined(separator: ","))]}"#
    }

    private var tarballName: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        #if os(macOS)
        return "appitool-darwin-\(arch).tar.gz"
        #else
        return "appitool-linux-\(arch).tar.gz"
        #endif
    }

    private func run(_ router: StubRouter, _ args: [String] = []) async throws {
        let cmd: SelfUpdateCommand = try CmdStub.parse(["self-update"] + args)
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    @Test("--check reports newer, equal, and older releases without downloading")
    func check() async throws {
        let router = StubRouter().on("GET", "api.github.com/repos", .ok(release("v999.0.0")), .ok(release("v0.0.1")), .ok(release("v0.0.1")), .ok(release("nightly")))
        try await run(router, ["--check"])
        try await run(router, ["--check"])
        try await run(router, ["--check", "--force"])
        try await run(router, ["--check"])
        #expect(router.log.requests.allSatisfy { $0.url.host == "api.github.com" })
        #expect(router.log.requests.first?.headers["Accept"] == "application/vnd.github.v3+json")
    }

    @Test("Release lookup HTTP failures exit with failure")
    func fetchFailures() async throws {
        let router = StubRouter().on("GET", "api.github.com/repos", .status(404), .status(403), .status(500, "oops"))
        for _ in 0..<3 {
            await #expect(throws: ExitCode.self) { try await run(router, ["--check"]) }
        }
    }

    @Test("Missing artifacts, missing checksums, download failures, and checksum mismatches abort before installing")
    func abortsBeforeInstall() async throws {
        // No compatible artifact.
        let noArtifact = StubRouter().on("GET", "api.github.com/repos", .ok(release("v999.0.0", assets: ["appitool-plan9-mips.tar.gz"])), .ok(release("v999.0.0")))
        await #expect(throws: ExitCode.self) { try await run(noArtifact) }
        await #expect(throws: ExitCode.self) { try await run(noArtifact) }

        // Artifact without checksums file.
        let noChecksums = StubRouter().on("GET", "api.github.com/repos", .ok(release("v999.0.0", assets: [tarballName])))
        await #expect(throws: CommandError.self) { try await run(noChecksums) }

        // Download failure.
        let downloadFail = StubRouter()
            .on("GET", "api.github.com/repos", .ok(release("v999.0.0", assets: [tarballName, "checksums.txt"])))
            .on("GET", "downloads.test", .status(404))
        await #expect(throws: CommandError.self) { try await run(downloadFail) }

        // Checksum file lacks the artifact entry.
        let noEntry = StubRouter()
            .on("GET", "api.github.com/repos", .ok(release("v999.0.0", assets: [tarballName, "checksums.txt"])))
            .on("GET", "checksums.txt", StubResponse(200, Data("abc  other-file.tar.gz\n".utf8), headers: [:]))
            .on("GET", tarballName, StubResponse(200, Data("tarball".utf8), headers: [:]))
        await #expect(throws: CommandError.self) { try await run(noEntry) }

        // Checksum mismatch.
        let mismatch = StubRouter()
            .on("GET", "api.github.com/repos", .ok(release("v999.0.0", assets: [tarballName, "checksums.txt"])))
            .on("GET", "checksums.txt", StubResponse(200, Data("\(String(repeating: "0", count: 64))  \(tarballName)\n".utf8), headers: [:]))
            .on("GET", tarballName, StubResponse(200, Data("tarball".utf8), headers: [:]))
        await #expect(throws: ExitCode.self) { try await run(mismatch) }
    }
}

// MARK: - inspect (explicit temp project dirs; no gradlew/xcodebuild available)

@Suite("Inspect Command Coverage", .serialized)
struct InspectCommandCoverageTests {
    private func androidProject(gradle: String) throws -> URL {
        let root = try TestFiles.makeTempDir("appitool-inspect-tests")
        let app = root.appendingPathComponent("android/app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try gradle.write(to: app.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        return root
    }

    private let gradle = """
    android {
        namespace "com.example.inspect"
        defaultConfig {
            applicationId "com.example.inspect.app"
            versionName "1.5.0"
            versionCode 12
        }
        productFlavors {
            staging {
                applicationIdSuffix ".staging"
                versionNameSuffix "-staging"
                versionCode 13
            }
            prod {
                applicationId "com.example.prod"
            }
        }
    }
    """

    private func run(_ args: [String]) async throws {
        let cmd: InspectCommand = try CmdStub.parse(["inspect"] + args)
        try await cmd.execute()
    }

    @Test("Inspects an Android project as text and JSON, with and without flavor filters")
    func android() async throws {
        let root = try androidProject(gradle: gradle)
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(["--project-dir", root.path])
        try await run(["-p", "android", "--project-dir", root.path, "--flavor", "staging"])
        try await run(["-p", "android", "--project-dir", root.path, "--json"])
        try await run(["-p", "all", "--project-dir", root.path, "--flavor", "missing"])

        let minimal = try androidProject(gradle: "android {\n    defaultConfig {\n        versionCode 3\n    }\n}\n")
        defer { try? FileManager.default.removeItem(at: minimal) }
        try await run(["-p", "android", "--project-dir", minimal.path])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("android/gradlew").path))
    }

    @Test("Missing platform projects raise validation errors")
    func missingProjects() async throws {
        let empty = try TestFiles.makeTempDir("appitool-inspect-tests")
        defer { try? FileManager.default.removeItem(at: empty) }
        await #expect(throws: ValidationError.self) { try await run(["-p", "ios", "--project-dir", empty.path]) }
        await #expect(throws: ValidationError.self) { try await run(["-p", "android", "--project-dir", empty.path]) }
        await #expect(throws: ValidationError.self) { try await run(["--project-dir", empty.path]) }
    }
}
