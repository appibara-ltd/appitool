import ArgumentParser
import Foundation
import Testing
import GoogleServices
@testable import appitool

// MARK: - Credentials Options

@Suite("CredentialsOptions Coverage")
struct CredentialsOptionsCoverageTests {
    @Test("Apple credentials resolve from flags, reject empty values, and build a service")
    func apple() throws {
        let pem = TestCredentials.appleKeyPEM()
        let options = try AppleCredentialsOptions.parse(["--apple-key-id", "KEY1", "--apple-issuer-id", "ISS", "--apple-key=\(pem)"])
        let resolved = try #require(options.resolve())
        #expect(resolved.keyId == "KEY1" && resolved.issuerId == "ISS" && resolved.key == pem)
        #expect(try options.makeService() != nil)
        _ = try options.requireService()

        let empty = try AppleCredentialsOptions.parse(["--apple-key-id", "", "--apple-issuer-id", "", "--apple-key", ""])
        #expect(empty.resolve() == nil)
        #expect(try empty.makeService() == nil)
        #expect(throws: ValidationError.self) { try empty.requireService() }
    }

    @Test("Google credentials resolve from flags, reject empty values, and build a service")
    func google() throws {
        let json = TestCredentials.serviceAccountJSON()
        let options = try GoogleCredentialsOptions.parse(["-g", json])
        #expect(options.resolveKey() == json)
        #expect(try options.makeService() != nil)
        _ = try options.requireService()

        let empty = try GoogleCredentialsOptions.parse(["--google-key", ""])
        #expect(empty.resolveKey() == nil)
        #expect(try empty.makeService() == nil)
        #expect(throws: ValidationError.self) { try empty.requireService() }
    }

    @Test("Firebase project options resolve explicit project, app-id fallbacks, and service-account project")
    func firebaseProject() throws {
        let json = TestCredentials.serviceAccountJSON()
        let options = try FirebaseProjectOptions.parse(["--google-key", json, "--project", "my-proj"])
        #expect(options.googleKey == json)
        #expect(options.resolveKey() == json)
        #expect(options.resolveProject() == "my-proj")
        #expect(try options.requireProject() == "my-proj")
        #expect(try options.requireProjectId(fallbackServiceProjectId: "sa") == "my-proj")
        #expect(try options.makeService() != nil)
        _ = try options.requireService()

        // With no explicit project, either an env value or the app-id project number is used (never nil here).
        let noProject = try FirebaseProjectOptions.parse(["--google-key", "", "--project", ""])
        #expect(noProject.resolveProject(fallbackAppId: "1:424242:ios:abc") != nil)
        #expect(try noProject.requireProject(fallbackAppId: "1:424242:ios:abc").isEmpty == false)
        #expect(try noProject.requireProjectId(fallbackServiceProjectId: " sa-project ").isEmpty == false)
        _ = noProject.resolveProject(fallbackAppId: "no-colons")
        #expect(try noProject.makeService() == nil)
        #expect(throws: ValidationError.self) { try noProject.requireService() }
    }

    @Test("Firebase credentials options resolve explicit app IDs and delegate to project options")
    func firebaseCredentials() throws {
        let json = TestCredentials.serviceAccountJSON()
        let options = try FirebaseCredentialsOptions.parse([
            "--google-key", json, "--project", "p1", "--firebase-app-id", "1:77:android:x", "-p", "android",
        ])
        #expect(options.googleKey == json)
        #expect(options.project == "p1")
        #expect(options.platform == .android)
        #expect(options.resolveKey() == json)
        #expect(options.resolveAppId() == "1:77:android:x")
        #expect(options.resolveAppId(for: .ios) == "1:77:android:x")
        #expect(try options.requireAppId() == "1:77:android:x")
        #expect(options.resolveProject() == "p1")
        #expect(try options.makeService() != nil)
        _ = try options.requireService()
        #expect(FirebaseCredentialsOptions.Platform.allCases.count == 2)
    }

    @Test("Notification options prefer explicit flags and drop empty values")
    func notifications() throws {
        let explicit = try NotificationOptions.parse(["--slack-url", "https://s", "--kokono-url", "https://k?token=t"])
        let resolved = explicit.resolve()
        #expect(resolved.slackUrl == "https://s")
        #expect(resolved.kokonoUrl == "https://k?token=t")
        #expect(resolved.kokonoPublicKey == nil)

        let withKey = try NotificationOptions.parse(["--kokono-url", "https://k?token=t", "--kokono-public-key", "KEY"])
        #expect(withKey.resolve().kokonoPublicKey == "KEY")

        let empty = try NotificationOptions.parse(["--slack-url", "", "--kokono-url", "", "--kokono-public-key", ""])
        let none = empty.resolve()
        #expect(none.slackUrl == nil && none.kokonoUrl == nil && none.kokonoPublicKey == nil)
    }

    @Test("Match options fall back to default keychain values for empty flags")
    func matchOptions() throws {
        let options = try MatchOptions.parse(["--keychain-name", "", "--keychain-password", "", "--team-id", "", "--match-git-url", "u", "--match-password", "p"])
        let resolved = options.resolve(defaultReadonly: false)
        #expect(resolved.keychainName == "appitool")
        #expect(resolved.keychainPassword == "appipass")
        #expect(resolved.teamId == nil)
        #expect(resolved.readonly == false)
        #expect(resolved.gitUrl == "u")
        let readonly = try MatchOptions.parse(["--readonly"]).resolve()
        #expect(readonly.readonly)
    }

    @Test("Release notes options trim values and default the locale")
    func releaseNotes() throws {
        let resolved = try ReleaseNotesOptions.parse(["--release-notes", "  hi  ", "--notes-from", " v1 ", "--notes-locale", " tr-TR "]).resolve()
        #expect(resolved.releaseNotes == "hi" && resolved.notesFrom == "v1" && resolved.notesLocale == "tr-TR")
        let blank = try ReleaseNotesOptions.parse(["--release-notes", " ", "--notes-locale", " "]).resolve()
        #expect(blank.releaseNotes == nil && blank.notesFrom == nil && blank.notesLocale == "en-US")
    }
}

// MARK: - Small Core helpers

@Suite("Core Helpers Coverage")
struct CoreHelpersCoverageTests {
    @Test("AppIdentifierResolver prefers explicit values")
    func resolver() async throws {
        #expect(AppIdentifierResolver.androidPackageName(explicit: " com.a ") == "com.a")
        #expect(await AppIdentifierResolver.iosBundleId(explicit: "com.ios") == "com.ios")
        #expect(AppIdentifierResolver.firebaseAppId(explicit: "1:2:ios:3", platform: nil) == "1:2:ios:3")
        // Paths that read the environment / project: values depend on the environment, so only exercise them.
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = AppIdentifierResolver.androidPackageName(explicit: nil, projectRoot: dir)
        _ = AppIdentifierResolver.androidPackageName(explicit: nil, projectRoot: dir, detectFromProject: false)
        _ = await AppIdentifierResolver.iosBundleId(explicit: nil, detectFromProject: false)
        _ = AppIdentifierResolver.firebaseAppId(explicit: nil, platform: .ios)
        _ = AppIdentifierResolver.firebaseAppId(explicit: nil, platform: .android)
        _ = AppIdentifierResolver.firebaseAppId(explicit: nil, platform: nil)
    }

    @Test("??= assigns only when nil, for optional and non-optional right-hand sides")
    func operators() {
        var a: Int? = nil
        a ??= 1
        a ??= 2
        #expect(a == 1)
        var b: String? = nil
        let optional: String? = "x"
        b ??= optional
        b ??= Optional("y")
        #expect(b == "x")
    }

    @Test("Log prints with indentation and empty initializer")
    func log() {
        let saved = Log.depth
        Log.depth = 2
        Log("indented", 1, separator: "-", terminator: "\n")
        Log()
        Log.depth = saved
    }

    @Test("AppitoolPaths derived directories and sanitization")
    func paths() {
        let root = AppitoolPaths.rootDirectory
        #expect(AppitoolPaths.targetBuildRoot(platform: "ios", target: "App") == root.appendingPathComponent("ios/App/build"))
        #expect(AppitoolPaths.iosDerivedDataDirectory(target: "App") == root.appendingPathComponent("ios/App/derivedData"))
        #expect(AppitoolPaths.androidKeystoresDirectory == root.appendingPathComponent("android/keystores"))
        #expect(AppitoolPaths.androidKeystoreFile(packageName: "com.a").lastPathComponent == "com.a.keystore")
        #expect(AppitoolPaths.assetsDirectory(project: ".", store: "apple", customRoot: nil).pathComponents.suffix(2) == ["default", "apple"])
        #expect(AppitoolPaths.buildDirectory(platform: "ios", target: "T", name: "a/b").lastPathComponent == "a_b")
    }

    @Test("TemporaryFileRestorer arms and disarms signal handlers, and skips unwritable restores")
    func restorer() throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("original".utf8).write(to: file)

        let restorer = TemporaryFileRestorer(enableSignalHandlers: true)
        try restorer.backup(file)
        try restorer.backup(file) // already recorded
        #expect(restorer.hasPendingBackups)
        try Data("changed".utf8).write(to: file)
        #expect(restorer.restoreAll() == [file.standardizedFileURL])
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(!restorer.hasPendingBackups)

        let failing = TemporaryFileRestorer(enableSignalHandlers: false)
        failing.registerBackup(Data("x".utf8), for: dir.appendingPathComponent("missing-dir/file.txt"))
        #expect(failing.restoreAll().isEmpty)
    }

    @Test("ProcessRunner streams through a formatter, log lines, raw stdout, and discarded stderr")
    func processRunner() async throws {
        let piped = try await ProcessRunner.stream("/bin/echo", arguments: ["hello world", "x"], formatter: "cat", style: .silent)
        #expect(piped.exitCode == 0)
        #expect(piped.stdout.contains("hello world"))

        let noFormatter = try await ProcessRunner.stream("/bin/echo", arguments: ["plain"], formatter: "definitely-missing-formatter-xyz", style: .logLines)
        #expect(noFormatter.stdout.contains("plain"))

        let partial = try await ProcessRunner.stream("/usr/bin/printf", arguments: ["a\\nno-newline"], style: .logLines)
        #expect(partial.stdout.contains("no-newline"))

        let raw = try await ProcessRunner.stream("/bin/echo", arguments: ["raw"], style: .rawStdout)
        #expect(raw.stdout.contains("raw"))

        let discarded = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"], discardError: true)
        #expect(discarded.stdout.contains("out"))
        #expect(!discarded.stdout.contains("err"))

        #expect(ProcessRunner.hasExecutable("/bin/sh"))
        #expect(!ProcessRunner.hasExecutable("/definitely/missing"))
        #expect(!ProcessRunner.hasExecutable(""))
        #expect(!ProcessRunner.hasExecutable("definitely-missing-binary-xyz"))
    }
}

// MARK: - GitStorage pure helpers

@Suite("GitStorage Helpers Coverage")
struct GitStorageHelpersCoverageTests {
    @Test("Authenticated URL keeps URLs without token or with existing credentials")
    func authenticatedUrl() {
        #expect(GitStorage(gitUrl: "https://github.com/o/r.git").resolveAuthenticatedGitUrl() == "https://github.com/o/r.git")
        #expect(GitStorage(gitUrl: "https://github.com/o/r.git", gitToken: "").resolveAuthenticatedGitUrl() == "https://github.com/o/r.git")
        #expect(GitStorage(gitUrl: "https://user@github.com/o/r.git", gitToken: "tok").resolveAuthenticatedGitUrl() == "https://user@github.com/o/r.git")
        #expect(GitStorage(gitUrl: "https://github.com/o/r.git", gitToken: "tok").resolveAuthenticatedGitUrl() == "https://x-access-token:tok@github.com/o/r.git")
    }

    @Test("SSH URL detection edge cases and home-relative key paths")
    func sshDetection() {
        #expect(!GitStorage.isSSHGitUrl("hostonly"))
        #expect(!GitStorage.isSSHGitUrl("   "))
        #expect(GitStorage.isSSHGitUrl("ssh://git@host/repo"))
        #expect(!GitStorage.isSSHGitUrl("~/repo"))
        #expect(GitStorage.resolveSSHPrivateKey(from: "~/definitely-missing-\(UUID().uuidString)") == nil)
        #expect(GitStorage.resolveSSHPrivateKey(from: "\"\"") == nil)
        #expect(GitStorage.shellSingleQuote("a'b") == "'a'\\''b'")
    }
}

// MARK: - Play signing certificates

private func withPlayService<T>(_ router: StubRouter, _ body: (GooglePlayService) async throws -> T) async throws -> T {
    HTTPStub.googleTokenRoute(router)
    return try await DefaultNetworkStub.with(router) { session in
        let service = try GooglePlayService(key: TestCredentials.serviceAccountJSON(), transport: StubTransport(router), urlSession: session)
        return try await body(service)
    }
}

@Suite("PlaySigningCertificates Coverage")
struct PlaySigningCertificatesCoverageTests {
    private let pkg = "com.example.play"

    private func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private func u64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private func prefixed(_ bytes: [UInt8]) -> [UInt8] { u32(bytes.count) + bytes }

    /// Minimal APK whose v2 signing block carries a single fake DER certificate.
    private func fakeAPK() -> Data {
        let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        let content: [UInt8] = [0x06, UInt8(oid.count)] + oid + [UInt8](repeating: 0xAA, count: 20)
        let cert = [0x30, UInt8(content.count)] + content
        let certificates = prefixed(prefixed(cert))
        let signedData = prefixed(prefixed([]) + certificates)
        let signer = prefixed(signedData + prefixed([]) + prefixed([0x01]))
        let value = prefixed(signer)
        let pairBytes = u64(value.count + 4) + u32(0x7109_871A) + value
        let blockSize = pairBytes.count + 8 + 16
        let block = u64(blockSize) + pairBytes + u64(blockSize) + [UInt8]("APK Sig Block 42".utf8)
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0] + u32(0) + u32(block.count) + [0, 0]
        return Data(block + eocd)
    }

    @Test("fetch reads certificates, records per-key failures, and supports skipping downloads")
    func fetch() async throws {
        let list = #"""
        {"generatedApks":[
          {"certificateSha256Hash":"AA:BB","generatedSplitApks":[{"downloadId":"good","splitId":"config.en"}]},
          {"certificateSha256Hash":"cc"},
          {"certificateSha256Hash":"dd","generatedUniversalApk":{"downloadId":"denied"}},
          {"certificateSha256Hash":"ee","generatedUniversalApk":{"downloadId":"garbage"}}
        ]}
        """#
        let router = StubRouter()
            .on("GET", "good:download", StubResponse(200, fakeAPK(), headers: ["Content-Type": "application/octet-stream"]))
            .on("GET", "denied:download", .status(403, #"{"error":{"message":"forbidden"}}"#))
            .on("GET", "garbage:download", StubResponse(200, Data([1, 2, 3]), headers: ["Content-Type": "application/octet-stream"]))
            .on("GET", "/generatedApks/5", .ok(list))
        let keys = try await withPlayService(router) { service in
            try await PlaySigningCertificates.fetch(packageName: pkg, versionCode: 5, service: service)
        }
        #expect(keys.map(\.apiSha256) == ["AABB", "CC", "DD", "EE"])
        #expect(keys[0].certificates.count == 1 && keys[0].failure == nil)
        #expect(keys[1].failure?.contains("No downloadable APK") == true)
        #expect(keys[2].failure?.contains("release access") == true)
        #expect(keys[3].failure?.contains("Could not read") == true)

        let skipped = try await withPlayService(StubRouter().on("GET", "/generatedApks/5", .ok(list))) { service in
            try await PlaySigningCertificates.fetch(packageName: pkg, versionCode: 5, service: service, downloadApks: false)
        }
        #expect(skipped.allSatisfy { $0.certificates.isEmpty && $0.failure == nil })
    }

    @Test("fetch maps list errors and empty results to command errors with hints")
    func fetchErrors() async throws {
        let forbidden = StubRouter().on("GET", "/generatedApks/", .status(404, #"{"error":{"message":"nope"}}"#))
        let error = await #expect(throws: CommandError.self) {
            try await withPlayService(forbidden) { try await PlaySigningCertificates.fetch(packageName: pkg, versionCode: 1, service: $0) }
        }
        #expect(error?.hint == "Check --package-name and --version-code.")

        let empty = StubRouter().on("GET", "/generatedApks/", .ok(#"{"generatedApks":[]}"#))
        await #expect(throws: CommandError.self) {
            try await withPlayService(empty) { try await PlaySigningCertificates.fetch(packageName: pkg, versionCode: 1, service: $0) }
        }
        #expect(PlaySigningCertificates.hint(for: .apiError(status: 500, message: "x")) == nil)
        #expect(PlaySigningCertificates.hint(for: .invalidResponse("x")) == nil)
    }

    @Test("latestVersionCode returns the highest code and rejects apps without releases")
    func latestVersionCode() async throws {
        let tracks = #"{"tracks":[{"track":"internal","releases":[{"name":"1.0","versionCodes":["3","12"]}]},{"track":"production","releases":[{"versionCodes":["7"]}]}]}"#
        let router = StubRouter()
            .on("POST", "androidpublisher.edits.insert", .ok(#"{"id":"e1"}"#))
            .on("GET", "androidpublisher.edits.tracks.list", .ok(tracks))
            .on("DELETE", "androidpublisher.edits.delete", StubResponse(204, Data()))
        let code = try await withPlayService(router) { try await PlaySigningCertificates.latestVersionCode(packageName: pkg, service: $0) }
        #expect(code == 12)

        let none = StubRouter()
            .on("POST", "androidpublisher.edits.insert", .ok(#"{"id":"e1"}"#))
            .on("GET", "androidpublisher.edits.tracks.list", .ok(#"{"tracks":[]}"#))
            .on("DELETE", "androidpublisher.edits.delete", StubResponse(204, Data()))
        await #expect(throws: CommandError.self) {
            try await withPlayService(none) { try await PlaySigningCertificates.latestVersionCode(packageName: pkg, service: $0) }
        }
    }
}

// MARK: - Screenshot manifest

@Suite("ScreenshotManifest Coverage")
struct ScreenshotManifestCoverageTests {
    @Test("load rejects unsupported schema versions and invalid JSON")
    func loadErrors() throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try ScreenshotManifest.load(from: dir) == nil)

        var manifest = ScreenshotManifest(store: "apple", locale: "en-US", type: "phone", remoteSetId: "set", entries: [])
        manifest.schemaVersion = 99
        try manifest.write(to: dir)
        let unsupported = #expect(throws: CommandError.self) { _ = try ScreenshotManifest.load(from: dir) }
        #expect(unsupported?.message.contains("Unsupported") == true)

        try Data("{not json".utf8).write(to: dir.appendingPathComponent(ScreenshotManifest.fileName))
        let invalid = #expect(throws: CommandError.self) { _ = try ScreenshotManifest.load(from: dir) }
        #expect(invalid?.message.contains("Invalid screenshot manifest") == true)
    }

    @Test("cleanUpAfterDownload removes stale tracked files and keeps untracked ones")
    func cleanUp() throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["kept.png", "stale.png", "still-remote.png", "untracked.jpg", "notes.txt"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }
        let previous = ScreenshotManifest(store: "apple", locale: "en-US", type: "phone", remoteSetId: "set", entries: [
            .init(file: "kept.png", remoteId: "1", sha256: "a"),
            .init(file: "stale.png", remoteId: "2", sha256: "b"),
            .init(file: "still-remote.png", remoteId: "3", sha256: "c"),
            .init(file: "already-gone.png", remoteId: "4", sha256: "d"),
        ])
        try previous.write(to: dir)
        try ScreenshotManifest.cleanUpAfterDownload(
            directory: dir,
            newEntries: [.init(file: "kept.png", remoteId: "1", sha256: "a")],
            label: "en-US/phone",
            storeName: "App Store Connect",
            isStillRemote: { $0.remoteId == "3" }
        )
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("kept.png").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("stale.png").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("still-remote.png").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("untracked.jpg").path))
    }

    @Test("Google Play slot limits")
    func limits() {
        #expect(GooglePlayImageSyncPlanner.limits(for: "icon") == (1, 1))
        #expect(GooglePlayImageSyncPlanner.limits(for: "phone") == (2, 8))
        #expect(GooglePlayImageSyncPlanner.limits(for: "tablet") == (1, 8))
    }
}
