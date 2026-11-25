import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import appitool

// Preset stages are invoked directly (never through `FlowRunner`, whose cleanup touches ~/.appitool).
// Build stages are only ever run in dry-run mode (no Gradle / xcodebuild), the temp projects contain no
// `gradlew`, Match is never configured, and every network call goes through the global URLSession stub.

private enum FlowFixtures {
    static let firebaseAppId = "1:1234567890:android:abcdef"
    static let gradle = """
    android {
        namespace "com.example.flow"
        defaultConfig {
            applicationId "com.example.flow"
            versionName "1.5.0"
            versionCode 12
        }
        productFlavors {
            staging {
                applicationId "com.example.flow.staging"
                versionName "1.6.0"
                versionCode 40
            }
        }
    }
    """

    static func androidProject(gradle: String = gradle) throws -> URL {
        let root = try TestFiles.makeTempDir("appitool-flow-presets")
        let app = root.appendingPathComponent("android/app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try gradle.write(to: app.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        return root
    }

    static func context(
        _ platform: FlowContext.Platform = .android,
        _ distribution: BuildCommand.Distribution = .adhoc,
        dir: URL,
        dryRun: Bool = true,
        preset: (any FlowPreset)? = nil,
        bundleId: String? = nil,
        firebaseAppId: String? = FlowFixtures.firebaseAppId,
        googleKey: String? = TestCredentials.serviceAccountJSON(),
        flavor: String? = nil
    ) -> FlowContext {
        FlowContext(
            platform: platform, distribution: distribution, projectDirectory: dir, isDryRun: dryRun,
            bundleId: bundleId, matchGitUrl: nil, matchPassword: nil,
            firebaseAppId: firebaseAppId, googleKey: googleKey, preset: preset, androidFlavor: flavor,
            fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false))
    }

    static func artifact(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("binary".utf8).write(to: url)
        return url
    }

    static func firebaseRoutes(_ router: StubRouter = StubRouter()) -> StubRouter {
        HTTPStub.googleTokenRoute(router)
        return router
            .on("GET", "/groups/internal", .ok(#"{"name":"projects/1234567890/groups/internal","displayName":"Internal"}"#))
            .on("POST", "releases:upload", .ok(#"{"name":"projects/1234567890/apps/x/releases/-/operations/op1"}"#))
            .on("GET", "operations/op1", .ok(#"{"done":true,"response":{"release":{"name":"projects/1234567890/apps/x/releases/r1","displayVersion":"9.9","buildVersion":"99","firebaseConsoleUri":"https://console","binaryDownloadUri":"https://bin","testingUri":"https://test"}}}"#))
            .on("PATCH", "/releases/r1", .ok("{}"))
            .on("POST", ":distribute", .ok("{}"))
            .on("GET", "/releases", .ok(#"{"releases":[{"name":"projects/1/apps/x/releases/r0","displayVersion":"1.4.0","buildVersion":"30"}]}"#))
    }
}

@Suite("Android Flow Presets Coverage", .serialized)
struct AndroidFlowPresetsCoverageTests {

    @Test("AdHoc preset: setup reads the project and Firebase, prebuild bumps, build/release honor dry-run")
    func adHocDryRun() async throws {
        let dir = try FlowFixtures.androidProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = AndroidAdHocPreset()
        var context = FlowFixtures.context(dir: dir, preset: preset)
        try preset.requirements(context: context)
        let router = FlowFixtures.firebaseRoutes()
        try await DefaultNetworkStub.with(router) { _ in
            try await preset.setup(context: &context)
        }
        #expect(context.bundleId == "com.example.flow")
        #expect(context.version == "1.5.0")
        #expect(context.metadata["firebase_build_number"] == "30")
        #expect(context.metadata["android_namespace"] == "com.example.flow")
        #expect(context.metadata["android_flavors"] == "staging")

        try await preset.prebuild(context: &context)
        #expect(context.buildNumber == "31")

        try await preset.build(context: &context)
        #expect(context.artifactPaths.isEmpty)

        // No artifact → release is skipped; with an artifact the dry-run stops before uploading.
        try await preset.release(context: &context)
        context.artifactPaths = [try FlowFixtures.artifact(dir, "app.apk")]
        try await preset.release(context: &context)
        #expect(context.metadata["firebase_release_name"] == nil)
        #expect(context.metadata["firebase_test_groups"] == "internal")
    }

    @Test("AdHoc preset: release uploads and distributes when not in dry-run")
    func adHocRelease() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = AndroidAdHocPreset()
        var context = FlowFixtures.context(dir: dir, dryRun: false, preset: preset)
        context.artifactPaths = [try FlowFixtures.artifact(dir, "app.apk")]
        context.changelog = "Notes"
        let router = FlowFixtures.firebaseRoutes()
        try await DefaultNetworkStub.with(router) { _ in
            try await preset.release(context: &context)
        }
        #expect(context.metadata["firebase_release_name"]?.hasSuffix("/releases/r1") == true)
        #expect(context.metadata["firebase_console_uri"] == "https://console")
        #expect(context.metadata["firebase_download_uri"] == "https://bin")
        #expect(context.metadata["firebase_testing_uri"] == "https://test")
        #expect(context.version == "9.9")
        #expect(context.buildNumber == "99")
        let distribute = try #require(router.log.first { $0.path.hasSuffix(":distribute") })
        #expect(distribute.json()["groupAliases"] as? [String] == ["internal"])
        #expect(router.log.first { $0.method == "PATCH" } != nil)
    }

    @Test("Firebase helpers require an app ID and a Google key")
    func firebaseRequirements() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let apk = try FlowFixtures.artifact(dir, "app.apk")

        var noAppId = FlowFixtures.context(dir: dir, firebaseAppId: " ")
        await #expect(throws: FlowRequirementError.self) {
            try await FirebasePresetHelpers.fetchLatestBuild(context: &noAppId, presetName: "P", appIdKey: "FIREBASE_ANDROID_APP_ID")
        }
        noAppId.artifactPaths = [apk]
        await #expect(throws: FlowRequirementError.self) {
            try await FirebasePresetHelpers.distribute(context: &noAppId, presetName: "P", artifactExtension: "apk", artifactLabel: "APK", appIdKey: "K")
        }

        var noKey = FlowFixtures.context(dir: dir, googleKey: nil)
        await #expect(throws: FlowRequirementError.self) {
            try await FirebasePresetHelpers.fetchLatestBuild(context: &noKey, presetName: "P", appIdKey: "K")
        }
        noKey.metadata["apk_path"] = apk.path
        await #expect(throws: FlowRequirementError.self) {
            try await FirebasePresetHelpers.distribute(context: &noKey, presetName: "P", artifactExtension: "APK", artifactLabel: "APK", appIdKey: "K")
        }

        let missing = FlowFixtures.context(dir: dir, preset: AndroidAdHocPreset(), firebaseAppId: nil, googleKey: nil)
        #expect(throws: FlowRequirementError.self) { try AndroidAdHocPreset().requirements(context: missing) }
        #expect(throws: FlowRequirementError.self) { try AndroidDevelopmentPreset().requirements(context: missing) }
        #expect(throws: FlowRequirementError.self) { try AndroidInternalPreset().requirements(context: missing) }
    }

    @Test("Firebase latest build lookup works for iOS contexts and surfaces failures")
    func firebaseLatestBuildIOS() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        var context = FlowFixtures.context(.ios, dir: dir, bundleId: "com.example.ios", firebaseAppId: "1:1234567890:ios:abc")
        let router = FlowFixtures.firebaseRoutes()
        try await DefaultNetworkStub.with(router) { _ in
            try await FirebasePresetHelpers.fetchLatestBuild(context: &context, presetName: "P", appIdKey: "FIREBASE_IOS_APP_ID")
        }
        #expect(context.metadata["firebase_version"] == "1.4.0")

        let failing = StubRouter()
        HTTPStub.googleTokenRoute(failing)
        failing.on("GET", "/releases", .status(500, "err"))
        await #expect(throws: (any Error).self) {
            try await DefaultNetworkStub.with(failing) { _ in
                try await FirebasePresetHelpers.fetchLatestBuild(context: &context, presetName: "P", appIdKey: "K")
            }
        }
    }

    @Test("Development preset runs every stage in dry-run")
    func developmentDryRun() async throws {
        let dir = try FlowFixtures.androidProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = AndroidDevelopmentPreset()
        var context = FlowFixtures.context(.android, .development, dir: dir, preset: preset, flavor: "staging")
        try preset.requirements(context: context)
        try await DefaultNetworkStub.with(FlowFixtures.firebaseRoutes()) { _ in
            try await preset.setup(context: &context)
        }
        #expect(context.bundleId == "com.example.flow.staging")
        #expect(context.version == "1.6.0")
        try await preset.prebuild(context: &context)
        #expect(context.buildNumber == "41")
        try await preset.build(context: &context)
        context.artifactPaths = [try FlowFixtures.artifact(dir, "app.apk")]
        try await preset.release(context: &context)
        #expect(context.metadata["firebase_release_name"] == nil)
    }

    @Test("Internal preset: setup reads Google Play, prebuild bumps, build/release honor dry-run")
    func internalDryRun() async throws {
        let dir = try FlowFixtures.androidProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = AndroidInternalPreset()
        var context = FlowFixtures.context(.android, .appstore, dir: dir, preset: preset)
        try preset.requirements(context: context)
        let router = PlayStub.edits()
            .on("GET", where: { $0.path.hasSuffix("/tracks") }, [.ok(#"{"tracks":[{"track":"internal","releases":[{"name":"1.5.0","versionCodes":["50"]}]}]}"#)])
        HTTPStub.googleTokenRoute(router)
        try await DefaultNetworkStub.with(router) { _ in
            try await preset.setup(context: &context)
        }
        #expect(context.metadata["googleplay_version_code"] == "50")
        #expect(router.log.requests.contains { $0.method == "DELETE" })
        try await preset.prebuild(context: &context)
        #expect(context.buildNumber == "51")
        try await preset.build(context: &context)
        try await preset.release(context: &context)
        context.metadata["aab_path"] = try FlowFixtures.artifact(dir, "app.aab").path
        try await preset.release(context: &context)
        #expect(context.metadata["googleplay_edit_id"] == nil)

        // Without a Google key, setup skips the remote lookup.
        var noKey = FlowFixtures.context(.android, .appstore, dir: dir, googleKey: nil)
        try await preset.setup(context: &noKey)
        #expect(noKey.metadata["googleplay_version_code"] == nil)
    }

    @Test("Internal preset: release uploads the bundle to the internal track when not in dry-run")
    func internalRelease() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = AndroidInternalPreset()
        var context = FlowFixtures.context(.android, .appstore, dir: dir, dryRun: false, preset: preset, bundleId: "com.example.flow")
        context.artifactPaths = [try FlowFixtures.artifact(dir, "app.aab")]
        context.version = "2.0.0"
        context.changelog = "Notes"
        let router = PlayStub.edits()
            .on("POST", "/bundles", .ok(#"{"versionCode":77}"#))
            .on("PUT", "/tracks/", .ok(#"{"track":"internal"}"#))
        HTTPStub.googleTokenRoute(router)
        try await DefaultNetworkStub.with(router) { _ in
            try await preset.release(context: &context)
        }
        #expect(context.buildNumber == "77")
        #expect(context.metadata["googleplay_edit_id"] == "e1")
        #expect(context.metadata["googleplay_track"] == "internal")
        let track = try #require(router.log.first { $0.method == "PUT" })
        #expect((track.json()["releases"] as? [[String: Any]])?.first?["name"] as? String == "2.0.0")

        var noKey = FlowFixtures.context(.android, .appstore, dir: dir, dryRun: false, googleKey: nil)
        noKey.artifactPaths = context.artifactPaths
        await #expect(throws: FlowRequirementError.self) { try await preset.release(context: &noKey) }
    }

    @Test("Project setup handles unknown flavors and missing projects; Match keystore needs a package name")
    func setupEdgeCases() async throws {
        let dir = try FlowFixtures.androidProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        var unknown = FlowFixtures.context(dir: dir, flavor: "nope")
        try await AndroidPresetHelpers.setupAndroidProject(context: &unknown)
        #expect(unknown.bundleId == "com.example.flow")

        let empty = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: empty) }
        var none = FlowFixtures.context(dir: empty, flavor: "staging")
        try await AndroidPresetHelpers.setupAndroidProject(context: &none)
        #expect(none.bundleId == nil && none.version == nil)

        // Match not configured → no-op.
        try await AndroidPresetHelpers.resolveMatchKeystore(context: &none)
        // Match configured but package name unknown → fails before any git access.
        none.matchGitUrl = "https://example.invalid/certs.git"
        none.matchPassword = "pw"
        await #expect(throws: AndroidPresetHelpers.MatchKeystoreError.self) {
            try await AndroidPresetHelpers.resolveMatchKeystore(context: &none)
        }

        // Version code bump without any valid values keeps the project value.
        var noVersions = FlowFixtures.context(dir: empty)
        AndroidPresetHelpers.bumpVersionCode(context: &noVersions, remoteVersionCode: "x", sourceLabel: "Test")
        #expect(noVersions.buildNumber == nil)
    }
}

@Suite("iOS Flow Presets Coverage", .serialized)
struct IOSFlowPresetsCoverageTests {

    private func ipa(_ dir: URL) async throws -> URL {
        let appDir = dir.appendingPathComponent("Payload/App.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "301"], format: .xml, options: 0)
        try plist.write(to: appDir.appendingPathComponent("Info.plist"))
        let result = try await ProcessRunner.run(
            "zip", arguments: ["-q", "-r", "App.ipa", "Payload"], workingDirectory: dir.path, discardError: true, discardOutput: true)
        #expect(result.isSuccess)
        return dir.appendingPathComponent("App.ipa")
    }

    private func iosContext(_ distribution: BuildCommand.Distribution, dir: URL, dryRun: Bool, preset: any FlowPreset) -> FlowContext {
        FlowContext(
            platform: .ios, distribution: distribution, projectDirectory: dir, isDryRun: dryRun,
            bundleId: "com.example.ios", matchGitUrl: nil, matchPassword: nil,
            appleKeyId: "KID", appleIssuerId: "ISS", appleKey: TestCredentials.appleKeyPEM(),
            firebaseAppId: "1:1234567890:ios:abc", googleKey: TestCredentials.serviceAccountJSON(),
            preset: preset, waitForProcessing: false,
            fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false))
    }

    @Test("Signing identity mapping and dry-run helpers")
    func helpers() async throws {
        #expect(IOSPresetHelpers.signingIdentity(from: nil, isDevelopment: true) == "Apple Development")
        #expect(IOSPresetHelpers.signingIdentity(from: nil, isDevelopment: false) == "Apple Distribution")
        #expect(IOSPresetHelpers.signingIdentity(from: "iPhone Distribution: ACME (T)", isDevelopment: false) == "iPhone Distribution")
        #expect(IOSPresetHelpers.signingIdentity(from: "Apple Development: Dev (T)", isDevelopment: true) == "Apple Development")
        #expect(IOSPresetHelpers.signingIdentity(from: "Custom Cert", isDevelopment: false) == "Custom Cert")

        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        var context = iosContext(.appstore, dir: dir, dryRun: true, preset: IOSInternalPreset())
        try IOSPresetHelpers.backupProjectPbxproj(context: context)
        context.buildNumber = "7"
        try IOSPresetHelpers.prepareIOSBuildNumber(context: &context, remoteBuildNumber: "10", sourceLabel: "TestFlight", configuration: "Release")
        #expect(context.buildNumber == "11")
        try IOSPresetHelpers.prepareIOSBuildNumber(context: &context, remoteBuildNumber: nil, sourceLabel: "TestFlight", configuration: "Release")
        #expect(context.buildNumber == "12")
        try await IOSPresetHelpers.build(context: &context, exportMethod: .appStore, label: "App Store")
        IOSPresetHelpers.restoreTemporaryFiles(context: context)
        #expect(context.artifactPaths.isEmpty)
    }

    @Test("AdHoc and Internal release stages honor dry-run and missing artifacts")
    func releaseDryRun() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        for preset in [IOSAdHocPreset() as any FlowPreset, IOSInternalPreset(), IOSDevelopmentPreset()] {
            var context = iosContext(.adhoc, dir: dir, dryRun: true, preset: preset)
            // Match is never configured in tests, so every iOS preset reports it as missing.
            #expect(throws: FlowRequirementError.self) { try preset.requirements(context: context) }
            context.matchGitUrl = "https://example.invalid/certs.git"
            context.matchPassword = "pw"
            try preset.requirements(context: context)
            context.matchGitUrl = nil
            context.matchPassword = nil
            try await preset.build(context: &context)
            try await preset.release(context: &context)
            context.artifactPaths = [try FlowFixtures.artifact(dir, "App.ipa")]
            try await preset.release(context: &context)
            #expect(context.metadata["firebase_release_name"] == nil)
            #expect(context.metadata["appstore_build_upload_id"] == nil)
        }
    }

    @Test("Internal release uploads the IPA to App Store Connect when not in dry-run")
    func internalRelease() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = IOSInternalPreset()
        var context = iosContext(.appstore, dir: dir, dryRun: false, preset: preset)
        context.artifactPaths = [try await ipa(dir)]
        context.changelog = "Ignored without waiting"
        let ops = #"{"fileName":"App.ipa","uploadOperations":[{"method":"PUT","url":"https://upload.test/p1","offset":0,"length":1}]}"#
        let router = StubRouter()
            .on("GET", "/v1/apps", .ok(ASCStub.list([AppleJSON.app("app-1", bundleId: "com.example.ios")])))
            .on("PATCH", "/v1/buildUploadFiles/f1", .ok(ASCStub.single(ASCStub.res("buildUploadFiles", "f1"))))
            .on("POST", "/v1/buildUploadFiles", ASCStub.created(ASCStub.single(ASCStub.res("buildUploadFiles", "f1", ops))))
            .on("POST", "/v1/buildUploads", ASCStub.created(ASCStub.single(ASCStub.res("buildUploads", "bu1"))))
            .on("PUT", "upload.test/", .ok())
        try await DefaultNetworkStub.with(router) { _ in
            try await preset.release(context: &context)
        }
        #expect(context.version == "3.0.0")
        #expect(context.buildNumber == "301")
        #expect(context.metadata["appstore_build_upload_id"] == "bu1")
        #expect(context.metadata["appstore_build_id"] == nil)

        var noCreds = FlowContext(
            platform: .ios, distribution: .appstore, projectDirectory: dir, isDryRun: false,
            fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false))
        noCreds.artifactPaths = context.artifactPaths
        await #expect(throws: FlowRequirementError.self) { try await preset.release(context: &noCreds) }
    }

    @Test("AdHoc release uploads the IPA to Firebase when not in dry-run")
    func adHocRelease() async throws {
        let dir = try TestFiles.makeTempDir("appitool-flow-presets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = IOSAdHocPreset()
        var context = iosContext(.adhoc, dir: dir, dryRun: false, preset: preset)
        context.artifactPaths = [try FlowFixtures.artifact(dir, "App.ipa")]
        let router = FlowFixtures.firebaseRoutes()
        try await DefaultNetworkStub.with(router) { _ in
            try await preset.release(context: &context)
        }
        #expect(context.metadata["firebase_release_name"]?.hasSuffix("/releases/r1") == true)
        #expect(router.log.first { $0.method == "PATCH" } == nil)
    }
}
