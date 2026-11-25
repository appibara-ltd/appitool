import Foundation
import Testing
@testable import appitool

private struct StubPreset: FlowPreset {
    var name: String = "Stub"
    var description: String = "Preset used by tests"
    var failRequirements = false
    var required: [(key: String, value: String?, description: String?)] = []

    func requirements(context: FlowContext) throws {
        if failRequirements || !required.isEmpty {
            try validateRequirements(required, context: context)
        }
    }
}

private struct BoomError: LocalizedError {
    var errorDescription: String? { "boom" }
}

private func makeDir() throws -> URL { try TestFiles.makeTempDir("appitool-flow-cov") }

private func iosContext(
    _ distribution: BuildCommand.Distribution = .appstore,
    dir: URL,
    dryRun: Bool = false,
    preset: (any FlowPreset)? = nil,
    slackUrl: String? = nil,
    kokonoUrl: String? = nil
) -> FlowContext {
    FlowContext(
        platform: .ios, distribution: distribution, projectDirectory: dir, isDryRun: dryRun,
        bundleId: "com.example.app", slackUrl: slackUrl, kokonoUrl: kokonoUrl, preset: preset,
        fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false)
    )
}

// MARK: - Stages and preset defaults

@Suite("Flow Preset Coverage")
struct FlowPresetCoverageTests {
    @Test("FlowStage metadata and duration formatting")
    func stagesAndDurations() {
        for stage in FlowStage.allCases {
            #expect(stage.description == stage.rawValue)
            #expect(!stage.displayName.isEmpty && !stage.emoji.isEmpty)
        }
        #expect(TimeInterval(12.345).formattedDuration == "12.35s")
        #expect(TimeInterval(65).formattedDuration == "1m 5s")
        #expect(TimeInterval(3600).formattedDuration == "1h")
        #expect(TimeInterval(3725).formattedDuration == "1h 2m 5s")
        #expect(TimeInterval(120).formattedDuration == "2m")
    }

    @Test("Default stage implementations run through execute(stage:) and stageHandlers")
    func executeAllStages() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = StubPreset()
        var context = iosContext(dir: dir, dryRun: true)
        context.changelog = "Existing notes\nLine two"
        for stage in FlowStage.allCases {
            try await preset.execute(stage: stage, context: &context)
        }
        #expect(context.changelog == "Existing notes\nLine two")
        #expect(preset.stageHandlers.count == FlowStage.allCases.count)
        for handler in preset.stageHandlers.values {
            try await handler.execute(context: &context)
        }
    }

    @Test("validateRequirements lists missing values and passes when all present")
    func requirements() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = iosContext(dir: dir)
        let preset = StubPreset()
        try preset.validateRequirements([("A", "x", nil)], context: context)
        let error = #expect(throws: FlowRequirementError.self) {
            try preset.validateRequirements([("A", " ", "Alpha"), ("B", nil, nil), ("C", "ok", nil)], context: context)
        }
        #expect(error?.missing == ["A (Alpha)", "B"])
        #expect(error?.errorDescription?.contains("Stub") == true)
        #expect(FlowArtifactError(message: "m").errorDescription == "m")
    }

    @Test("Default postbuild verifies artifacts by platform format")
    func postbuild() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = StubPreset()

        var missing = iosContext(dir: dir)
        await #expect(throws: FlowArtifactError.self) { try await preset.postbuild(context: &missing) }

        let emptyIpa = dir.appendingPathComponent("Empty.ipa")
        try Data().write(to: emptyIpa)
        var empty = iosContext(dir: dir)
        empty.artifactPaths = [emptyIpa]
        await #expect(throws: FlowArtifactError.self) { try await preset.postbuild(context: &empty) }

        let ipa = dir.appendingPathComponent("App.ipa")
        try Data("ipa".utf8).write(to: ipa)
        var ok = iosContext(dir: dir)
        ok.artifactPaths = [ipa]
        try await preset.postbuild(context: &ok)

        let aab = dir.appendingPathComponent("app.aab")
        try Data("aab".utf8).write(to: aab)
        var android = FlowContext(platform: .android, distribution: .appstore, projectDirectory: dir, fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false))
        android.metadata["aab_path"] = aab.path
        try await preset.postbuild(context: &android)

        var androidApk = FlowContext(platform: .android, distribution: .adhoc, projectDirectory: dir, fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false))
        await #expect(throws: FlowArtifactError.self) { try await preset.postbuild(context: &androidApk) }
        androidApk.androidFormat = .aab
        androidApk.artifactPaths = [aab]
        try await preset.postbuild(context: &androidApk)
    }

    @Test("Default prerelease handles fallback history, explicit refs without commits, and git errors")
    func prerelease() async throws {
        let preset = StubPreset()

        // Not a git repository: the error is logged and the changelog stays empty.
        let plain = try makeDir()
        defer { try? FileManager.default.removeItem(at: plain) }
        var notRepo = iosContext(dir: plain)
        try await preset.prerelease(context: &notRepo)
        #expect(notRepo.changelog == nil)

        let repo = try makeDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: [String]) async throws {
            let result = try await ProcessRunner.git(["-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args, in: repo.path)
            try #require(result.isSuccess, "git \(args) failed: \(result.stderr)")
        }
        try await git(["init", "-q"])
        try await git(["commit", "--allow-empty", "-q", "-m", "feat: first"])

        var fallback = iosContext(dir: repo)
        try await preset.prerelease(context: &fallback)
        #expect(fallback.changelog?.contains("first") == true)

        try await git(["tag", "-a", "base", "-m", "base"])
        var explicit = iosContext(dir: repo)
        explicit.releaseNotesFrom = "base"
        try await preset.prerelease(context: &explicit)
        #expect(explicit.changelog == nil)
    }

    @Test("Default postrelease: dry-run tag preview, missing tag, and local tagging with notifications")
    func postrelease() async throws {
        let preset = StubPreset()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var dry = iosContext(dir: dir, dryRun: true)
        dry.version = "1.0"
        dry.buildNumber = "3"
        try await preset.postrelease(context: &dry)

        // No version: tag creation skipped; no notification URLs configured.
        var noTag = iosContext(.adhoc, dir: dir)
        try await preset.postrelease(context: &noTag)
        #expect(noTag.metadata["git_tag"] == nil)

        // Version + build number in a non-repo directory: tag failure is logged, not thrown; notifications sent.
        let router = StubRouter().on("POST", "hooks.slack.test", .ok())
        try await DefaultNetworkStub.with(router) { _ in
            var tagged = iosContext(dir: dir, slackUrl: "https://hooks.slack.test/x")
            tagged.version = "1.0"
            tagged.buildNumber = "3"
            try await preset.postrelease(context: &tagged)
            #expect(tagged.metadata["git_tag"] == nil)
        }
        let fields = (router.log.requests.first?.json()["attachments"] as? [[String: Any]])?.first?["fields"] as? [[String: Any]]
        let titles = fields?.compactMap { $0["title"] as? String } ?? []
        #expect(titles.contains("Version") && titles.contains("Build Number") && titles.contains("Bundle ID"))

        // A real local repository gets the release tag (no remote, so nothing is pushed).
        let repo = try makeDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        for args in [["init", "-q"], ["config", "tag.gpgsign", "false"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"],
                     ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "init"]] {
            _ = try await ProcessRunner.git(args, in: repo.path)
        }
        var android = FlowContext(platform: .android, distribution: .development, projectDirectory: repo, bundleId: "com.pkg", fileRestorer: TemporaryFileRestorer(enableSignalHandlers: false))
        android.version = "2.0"
        android.buildNumber = "9"
        try await preset.postrelease(context: &android)
        #expect(android.metadata["git_tag"] == "🤖_2.0_9_development")
    }
}

// MARK: - FlowRunner

@Suite("FlowRunner Coverage")
struct FlowRunnerCoverageTests {
    @Test("Successful run with a preset restores backups, removes signing temp files, and records durations")
    func success() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracked = dir.appendingPathComponent("Info.plist")
        try Data("original".utf8).write(to: tracked)
        let signingTemp = dir.appendingPathComponent("signing-temp")
        try FileManager.default.createDirectory(at: signingTemp, withIntermediateDirectories: true)

        var context = iosContext(dir: dir, dryRun: true, preset: StubPreset())
        context.androidSigningTempUrl = signingTemp
        let handlers: [FlowStage: any FlowStageHandler] = [
            .build: AnyFlowStageHandler { ctx in
                try ctx.fileRestorer.backup(tracked)
                try Data("mutated".utf8).write(to: tracked)
                ctx.metadata["built"] = "yes"
            },
        ]
        try await FlowRunner().run(context: &context, stageHandlers: handlers)
        #expect(context.metadata["built"] == "yes")
        #expect(context.stageDurations[.build] != nil)
        #expect(context.stageDurations[.setup] != nil)
        #expect(try String(contentsOf: tracked, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: signingTemp.path))
    }

    @Test("Preset requirement failures abort before any stage runs")
    func requirementFailure() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var context = iosContext(dir: dir, preset: StubPreset(failRequirements: true, required: [("KEY", nil, nil)]))
        await #expect(throws: FlowRequirementError.self) {
            try await FlowRunner().run(context: &context)
        }
        #expect(context.currentStage == nil)
    }

    @Test("Stage failures notify configured webhooks (non dry-run) and rethrow")
    func failureNotifies() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = StubRouter()
            .on("POST", "hooks.slack.test", .ok())
            .on("POST", "kokono.test", .ok(#"{"success":true}"#))
        try await DefaultNetworkStub.with(router) { _ in
            var context = iosContext(dir: dir, slackUrl: "https://hooks.slack.test/x", kokonoUrl: "https://kokono.test/notify?token=t")
            await #expect(throws: BoomError.self) {
                try await FlowRunner().run(context: &context, stageHandlers: [.prebuild: AnyFlowStageHandler { _ in throw BoomError() }])
            }
            #expect(context.currentStage == .prebuild)
        }
        #expect(router.log.count == 2)
        let slackBody = router.log.requests.first { $0.url.host == "hooks.slack.test" }?.json()
        let attachment = (slackBody?["attachments"] as? [[String: Any]])?.first
        #expect(attachment?["text"] as? String == "boom")
    }

    @Test("Runner-built context runs handlers and dry-run failures skip notifications")
    func runnerBuiltContext() async throws {
        let runner = FlowRunner(platform: .ios, distribution: .development, isDryRun: true, bundleId: "com.example")
        try await runner.run(stageHandlers: [.setup: AnyFlowStageHandler { ctx in
            #expect(ctx.bundleId == "com.example")
            #expect(ctx.isDryRun)
        }])
        await #expect(throws: BoomError.self) {
            try await runner.run(stageHandlers: [.release: AnyFlowStageHandler { _ in throw BoomError() }])
        }
    }
}
