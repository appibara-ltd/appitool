import Crypto
import Foundation
import Testing
@testable import appitool

// These tests run *fake* `gradlew` shell scripts written into temp directories (never real Gradle)
// and local temp Git repositories (never real remotes). Webhooks go through `StubURLProtocol`.

private func makeDir() throws -> URL { try TestFiles.makeTempDir("appitool-tasks-cov") }

private func writeScript(_ body: String, to url: URL, executable: Bool) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
}

// MARK: - GradleTask

@Suite("GradleTask Coverage")
struct GradleTaskCoverageTests {
    @Test("Task names combine format, flavor, and build type")
    func taskNames() {
        #expect(GradleTask.resolveTaskName(format: .aab, buildType: "release", flavor: "production") == "bundleProductionRelease")
        #expect(GradleTask.resolveTaskName(format: .apk, buildType: "debug", flavor: nil) == "assembleDebug")
        #expect(GradleTask.resolveTaskName(format: .apk, buildType: "debug", flavor: "") == "assembleDebug")
    }

    @Test("run passes sanitized flags, properties, and signing; copies the artifact to the output directory")
    func runWithOutputDirectory() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let android = dir.appendingPathComponent("android")
        try writeScript(
            """
            HERE="$(cd "$(dirname "$0")" && pwd)"
            printf '%s\\n' "$@" > "$HERE/args.txt"
            mkdir -p "$HERE/app/build/outputs/bundle/stagingRelease"
            echo aab > "$HERE/app/build/outputs/bundle/stagingRelease/app-staging-release.aab"
            echo "BUILD SUCCESSFUL"
            """,
            to: android.appendingPathComponent("gradlew"),
            executable: false
        )
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: out.appendingPathComponent("MyApp.aab"))

        let output = try await GradleTask().run(.init(
            projectDirectory: dir.path,
            flavor: "staging",
            outputDirectory: out.path,
            artifactName: "MyApp",
            signing: .init(storeFile: "/k.jks", storePassword: "sp", keyAlias: "up", keyPassword: "kp"),
            properties: ["versionCode": "42"],
            systemProperties: ["org.gradle.jvmargs": "-Xmx8g", "custom.prop": "1"],
            flags: ["--daemon", "--build-cache"],
            clean: true,
            silent: false,
            formatter: nil
        ))
        #expect(output.aabPath == out.appendingPathComponent("MyApp.aab").path)
        #expect(output.apkPath == nil)
        #expect(output.allArtifactPaths == [out.appendingPathComponent("MyApp.aab").path])
        #expect(try String(contentsOf: out.appendingPathComponent("MyApp.aab"), encoding: .utf8) == "aab\n")

        let args = try String(contentsOf: android.appendingPathComponent("args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.first == "--no-daemon")
        #expect(!args.contains("--daemon"))
        #expect(args.contains("-Dcustom.prop=1"))
        #expect(!args.contains { $0.contains("jvmargs") })
        #expect(args.contains("-Dorg.gradle.daemon=false"))
        #expect(args.contains("-Pandroid.injected.signing.key.alias=up"))
        #expect(args.contains("-PversionCode=42"))
        #expect(Array(args.suffix(2)) == ["clean", "bundleStagingRelease"])
    }

    @Test("run without output directory returns discovered APKs from the fallback build/outputs search")
    func runWithoutOutputDirectory() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeScript(
            """
            HERE="$(cd "$(dirname "$0")" && pwd)"
            mkdir -p "$HERE/feature/build/outputs/apk"
            echo apk > "$HERE/feature/build/outputs/apk/feature.apk"
            """,
            to: dir.appendingPathComponent("gradlew"),
            executable: true
        )
        let output = try await GradleTask().run(.init(projectDirectory: dir.path, tasks: ["assembleDebug"], format: .apk, silent: true))
        #expect(output.apkPath?.hasSuffix("feature/build/outputs/apk/feature.apk") == true)
        #expect(output.aabPath == nil)
        #expect(output.allArtifactPaths.count == 1)

        let aab = try await GradleTask().run(.init(projectDirectory: dir.path, tasks: ["noop"], format: .apk, outputDirectory: dir.appendingPathComponent("o").path, silent: true))
        #expect(aab.apkPath?.hasSuffix("o/feature.apk") == true)
    }

    @Test("run surfaces build failures, missing artifacts, and a missing wrapper")
    func runFailures() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing = dir.appendingPathComponent("failing")
        try writeScript("echo boom\nexit 3", to: failing.appendingPathComponent("gradlew"), executable: true)
        let buildError = await #expect(throws: GradleTask.GradleError.self) {
            try await GradleTask().run(.init(projectDirectory: failing.path, silent: true))
        }
        #expect(buildError?.errorDescription?.contains("exit code 3") == true)

        let empty = dir.appendingPathComponent("empty")
        try writeScript("exit 0", to: empty.appendingPathComponent("gradlew"), executable: true)
        await #expect(throws: GradleTask.GradleError.self) {
            try await GradleTask().run(.init(projectDirectory: empty.path, silent: true))
        }

        let missing = dir.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let notFound = await #expect(throws: GradleTask.GradleError.self) {
            try await GradleTask().run(.init(projectDirectory: missing.path, silent: true))
        }
        #expect(notFound?.errorDescription?.contains("gradlew") == true)
        #expect(GradleTask.GradleError.artifactNotFound(expectedFormat: .aab).errorDescription?.contains(".aab") == true)
    }
}

// MARK: - AndroidTasks Gradle evaluation

@Suite("AndroidTasks Gradle Evaluation Coverage")
struct AndroidTasksGradleEvaluationCoverageTests {
    private func makeProject(gradleBody: String, script: String) throws -> URL {
        let root = try makeDir()
        let android = root.appendingPathComponent("android")
        try FileManager.default.createDirectory(at: android.appendingPathComponent("app"), withIntermediateDirectories: true)
        try gradleBody.write(to: android.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8)
        try writeScript(script, to: android.appendingPathComponent("gradlew"), executable: false)
        return root
    }

    private let appInfoScript = """
    echo "APPI_VERSION_CODE=42"
    echo "APPI_VERSION_NAME=2.0.0"
    echo "APPI_APPLICATION_ID=com.dynamic.app"
    echo "APPI_NAMESPACE=com.dynamic"
    echo "APPI_FLAVOR=staging|com.dynamic.staging||2.0.0-beta||43"
    echo "APPI_FLAVOR=prod|||||"
    """

    @Test("inspectAndroidProject and resolveProjectVersion fall back to a (fake) Gradle evaluation")
    func gradleFallback() async throws {
        let root = try makeProject(gradleBody: "android {\n  namespace \"com.static\"\n  productFlavors { }\n}\n", script: appInfoScript)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try await AndroidTasks.inspectAndroidProject(in: root)
        #expect(info.applicationId == "com.dynamic.app")
        #expect(info.versionCode == "42")
        #expect(info.versionName == "2.0.0")
        #expect(info.namespace == "com.dynamic")
        #expect(info.flavors.map(\.name) == ["staging", "prod"])

        let staging = try await AndroidTasks.inspectAndroidProject(in: root, flavor: "staging")
        #expect(staging.applicationId == "com.dynamic.staging")
        #expect(staging.versionCode == "43")

        let version = await AndroidTasks.resolveProjectVersion(in: root, flavor: "staging")
        #expect(version.versionCode == "43")
        #expect(version.versionName == "2.0.0-beta")

        let evaluated = try await AndroidTasks.evaluateAppInfoViaGradle(workspaceRoot: root, offline: true)
        #expect(evaluated.packageName == "com.dynamic.app")
    }

    @Test("Offline evaluation failure retries online; missing project or wrapper throw")
    func retryAndErrors() async throws {
        let root = try makeProject(
            gradleBody: "android { defaultConfig { applicationId \"com.static\" } }\n",
            script: "for a in \"$@\"; do if [ \"$a\" = \"--offline\" ]; then echo offline-fail; exit 1; fi; done\necho APPI_VERSION_CODE=9\necho APPI_VERSION_NAME=0.9\n"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try await AndroidTasks.inspectAndroidProject(in: root)
        #expect(info.versionCode == "9")
        #expect(info.applicationId == "com.static")
        let version = await AndroidTasks.resolveProjectVersion(in: root)
        #expect(version.versionName == "0.9")
        let offline = await #expect(throws: NSError.self) {
            _ = try await AndroidTasks.evaluateAppInfoViaGradle(workspaceRoot: root, offline: true)
        }
        #expect(offline?.code == 1)

        let empty = try makeDir()
        defer { try? FileManager.default.removeItem(at: empty) }
        let notFound = await #expect(throws: NSError.self) { _ = try await AndroidTasks.evaluateAppInfoViaGradle(workspaceRoot: empty) }
        #expect(notFound?.code == 1)
        try "".write(to: empty.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        let noWrapper = await #expect(throws: NSError.self) { _ = try await AndroidTasks.evaluateAppInfoViaGradle(workspaceRoot: empty) }
        #expect(noWrapper?.code == 2)
    }
}

// MARK: - NotifyTask

@Suite("NotifyTask Coverage")
struct NotifyTaskCoverageTests {
    private let slack = "https://hooks.slack.test/services/T/B/X"
    private let kokono = "https://kokono.test/notify?token=tok123"

    @Test("Slack payload orders metadata fields and reports HTTP failures")
    func slackPayload() async throws {
        let router = StubRouter()
            .on("POST", "hooks.slack.test", .ok(), .status(500, "nope"))
        try await DefaultNetworkStub.with(router) { _ in
            try await NotifyTask().run(.init(
                provider: .slack, status: .success, title: "T", message: "M",
                metadata: ["Zeta": "z", "Version": "1.0", "Platform": "IOS", "Alpha": "a"],
                slackUrl: slack
            ))
            let error = await #expect(throws: NotifyTask.NotifyError.self) {
                try await NotifyTask().run(.init(provider: .slack, status: .failure, title: "T", message: "M", slackUrl: slack))
            }
            #expect(error?.errorDescription?.contains("HTTP 500") == true)
        }
        let body = try #require(router.log.requests.first?.json())
        let attachment = try #require((body["attachments"] as? [[String: Any]])?.first)
        #expect(attachment["color"] as? String == "#2EB67D")
        let titles = (attachment["fields"] as? [[String: Any]])?.compactMap { $0["title"] as? String }
        #expect(titles == ["Platform", "Version", "Alpha", "Zeta"])
    }

    @Test("Missing URLs and tokens are rejected before any request")
    func validation() async throws {
        await #expect(throws: NotifyTask.NotifyError.self) {
            try await NotifyTask().run(.init(provider: .slack, status: .success, title: "T", message: "M"))
        }
        await #expect(throws: NotifyTask.NotifyError.self) {
            try await NotifyTask().run(.init(provider: .kokono, status: .success, title: "T", message: "M", kokonoUrl: ""))
        }
        await #expect(throws: NotifyTask.NotifyError.self) {
            try await NotifyTask().run(.init(provider: .kokono, status: .success, title: "T", message: "M", kokonoUrl: "https://kokono.test/notify"))
        }
        await #expect(throws: NotifyTask.NotifyError.self) {
            try await NotifyTask().run(.init(provider: .kokono, status: .success, title: "T", message: "M", kokonoUrl: "http://[bad"))
        }
        let descriptions: [NotifyTask.NotifyError] = [.missingWebhookUrl("x"), .invalidWebhookUrl("u"), .invalidPublicKey("k"), .requestFailed(statusCode: 1, response: "r")]
        #expect(descriptions.allSatisfy { $0.errorDescription?.isEmpty == false })
        #expect(NotifyTask.Provider.kokono.displayName == "KokoNo")
        #expect(NotifyTask.Provider.slack.displayName == "Slack")
        #expect(NotifyTask.Status.failure.emoji == "💥")
        #expect(NotifyTask.Status.success.emoji == "🎉")
        #expect(NotifyTask.Status.failure.colorHex == "#E01E5A")
    }

    @Test("KokoNo plaintext payload truncates messages around metadata and checks success flags")
    func kokonoPlaintext() async throws {
        let router = StubRouter()
            .on("POST", "kokono.test", .ok(#"{"success":true}"#), .ok(#"{"success":true}"#), .ok(#"{"success":true}"#),
                .ok(#"{"success":true}"#), .ok(#"{"success":false,"message":"bad token"}"#), .status(502, "gateway"))
        let longMessage = String(repeating: "m", count: 400)
        let bigMetadata = ["Platform": String(repeating: "p", count: 300)]
        try await DefaultNetworkStub.with(router) { _ in
            let task = NotifyTask()
            try await task.run(.init(provider: .kokono, status: .success, title: "T", message: longMessage, metadata: ["Version": "1", "Other": "o"], kokonoUrl: kokono))
            try await task.run(.init(provider: .kokono, status: .success, title: "T", message: "", metadata: ["Version": "1"], kokonoUrl: kokono))
            try await task.run(.init(provider: .kokono, status: .success, title: "T", message: "short", metadata: bigMetadata, kokonoUrl: kokono))
            try await task.run(.init(provider: .kokono, status: .success, title: "T", message: longMessage, kokonoUrl: kokono))
            let rejected = await #expect(throws: NotifyTask.NotifyError.self) {
                try await task.run(.init(provider: .kokono, status: .success, title: "T", message: "x", kokonoUrl: kokono))
            }
            #expect(rejected?.errorDescription?.contains("bad token") == true)
            await #expect(throws: NotifyTask.NotifyError.self) {
                try await task.run(.init(provider: .kokono, status: .success, title: "T", message: "x", kokonoUrl: kokono))
            }
        }
        let requests = router.log.requests
        #expect(requests.count == 6)
        #expect(requests.allSatisfy { $0.url.query == nil && $0.url.path == "/notify" })
        let messages = requests.prefix(4).compactMap { $0.json()["message"] as? String }
        #expect(messages.allSatisfy { $0.count <= 250 })
        #expect(messages[0].hasSuffix("Version: 1\nOther: o"))
        #expect(messages[1] == "Version: 1")
        #expect(messages[2].hasSuffix("..."))
        #expect(requests.first?.json()["token"] as? String == "tok123")
    }

    @Test("KokoNo E2E payload encrypts title and message for a valid X25519 key; invalid keys throw")
    func kokonoEncrypted() async throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = recipient.publicKey.rawRepresentation.base64EncodedString()
        let router = StubRouter().on("POST", "kokono.test", .ok("{}"))
        try await DefaultNetworkStub.with(router) { _ in
            try await NotifyTask().run(.init(provider: .kokono, status: .success, title: "Secret", message: "Body", kokonoUrl: kokono, kokonoPublicKey: publicKey))
            await #expect(throws: NotifyTask.NotifyError.self) {
                try await NotifyTask().run(.init(provider: .kokono, status: .success, title: "T", message: "M", kokonoUrl: kokono, kokonoPublicKey: "%%%not-base64"))
            }
            await #expect(throws: NotifyTask.NotifyError.self) {
                try await NotifyTask().run(.init(provider: .kokono, status: .success, title: "T", message: "M", kokonoUrl: kokono, kokonoPublicKey: Data([1, 2, 3]).base64EncodedString()))
            }
        }
        let body = try #require(router.log.requests.first?.json())
        #expect(body["encrypted"] as? Int == 1)
        let title = try #require(body["title"] as? [String: String])
        #expect(Set(title.keys) == ["key", "iv", "ciphertext", "tag"])

        // Decrypt the title to prove protocol compatibility.
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: title["key"]!)!)
        let shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("kokono-salt-v1".utf8), sharedInfo: Data("kokono-info-v1".utf8), outputByteCount: 32)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(base64Encoded: title["iv"]!)!),
            ciphertext: Data(base64Encoded: title["ciphertext"]!)!,
            tag: Data(base64Encoded: title["tag"]!)!
        )
        #expect(String(data: try AES.GCM.open(box, using: key), encoding: .utf8) == "Secret")
    }

    @Test("notifyAllConfigured sends to every configured provider and swallows failures")
    func notifyAll() async throws {
        let router = StubRouter()
            .on("POST", "hooks.slack.test", .ok(), .status(500))
            .on("POST", "kokono.test", .ok("{}"), .status(500))
        try await DefaultNetworkStub.with(router) { _ in
            await NotifyTask().notifyAllConfigured(status: .success, title: "T", message: "M", slackUrl: slack, kokonoUrl: kokono)
            await NotifyTask().notifyAllConfigured(status: .failure, title: "T", message: "M", slackUrl: slack, kokonoUrl: kokono)
            await NotifyTask().notifyAllConfigured(status: .failure, title: "T", message: "M", slackUrl: "", kokonoUrl: "")
        }
        #expect(router.log.count == 4)
    }
}

// MARK: - GitTagTask

@Suite("GitTagTask Coverage")
struct GitTagTaskCoverageTests {
    private func git(_ args: [String], in dir: URL) async throws -> ProcessRunner.Output {
        try await ProcessRunner.git(args, in: dir.path)
    }

    private func makeRepo(commit: Bool = true) async throws -> URL {
        let dir = try makeDir()
        _ = try await git(["init", "-q"], in: dir)
        _ = try await git(["config", "tag.gpgsign", "false"], in: dir)
        _ = try await git(["config", "commit.gpgsign", "false"], in: dir)
        _ = try await git(["config", "user.name", "Test"], in: dir)
        _ = try await git(["config", "user.email", "test@example.com"], in: dir)
        if commit {
            let result = try await git(["commit", "--allow-empty", "-q", "-m", "init"], in: dir)
            try #require(result.isSuccess, "commit failed: \(result.stderr)")
        }
        return dir
    }

    @Test("Creates local tags, skips push without a remote, and pushes to a local bare remote")
    func tagAndPush() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let local = try await GitTagTask().run(.init(tagName: " v1.0 ", push: false, workingDirectory: repo.path))
        #expect(local.tagName == "v1.0" && !local.pushed)
        let message = try await git(["tag", "-n1", "-l", "v1.0"], in: repo)
        #expect(message.stdout.contains("Release v1.0"))

        let noRemote = try await GitTagTask().run(.init(tagName: "v1.1", message: "Custom", workingDirectory: repo.path))
        #expect(!noRemote.pushed)

        let bare = try makeDir()
        defer { try? FileManager.default.removeItem(at: bare) }
        _ = try await git(["init", "-q", "--bare"], in: bare)
        _ = try await git(["remote", "add", "origin", bare.path], in: repo)
        let pushed = try await GitTagTask().run(.init(tagName: "v1.2", workingDirectory: repo.path))
        #expect(pushed.pushed)
        let remoteTags = try await git(["tag", "-l"], in: bare)
        #expect(remoteTags.stdout.contains("v1.2"))

        _ = try await git(["remote", "add", "broken", bare.appendingPathComponent("does-not-exist").path], in: repo)
        let pushError = await #expect(throws: GitTagTask.GitTagError.self) {
            try await GitTagTask().run(.init(tagName: "v1.3", remote: "broken", workingDirectory: repo.path))
        }
        #expect(pushError?.errorDescription?.contains("broken") == true)
    }

    @Test("Rejects empty names, non-repositories, and repositories without commits")
    func failures() async throws {
        await #expect(throws: GitTagTask.GitTagError.self) { try await GitTagTask().run(.init(tagName: "  ")) }

        let plain = try makeDir()
        defer { try? FileManager.default.removeItem(at: plain) }
        let notRepo = await #expect(throws: GitTagTask.GitTagError.self) {
            try await GitTagTask().run(.init(tagName: "v1", workingDirectory: plain.path))
        }
        #expect(notRepo?.errorDescription?.contains("not a Git repository") == true)

        let empty = try await makeRepo(commit: false)
        defer { try? FileManager.default.removeItem(at: empty) }
        let tagError = await #expect(throws: GitTagTask.GitTagError.self) {
            try await GitTagTask().run(.init(tagName: "v1", workingDirectory: empty.path))
        }
        #expect(tagError?.errorDescription?.contains("Failed to create") == true)
        #expect(GitTagTask.GitTagError.emptyTagName.errorDescription?.isEmpty == false)
    }
}

// MARK: - GenerateReleaseNotesTask

@Suite("GenerateReleaseNotesTask Coverage")
struct GenerateReleaseNotesTaskCoverageTests {
    private func makeRepo(commits: [String]) async throws -> URL {
        let dir = try makeDir()
        _ = try await ProcessRunner.git(["init", "-q"], in: dir.path)
        for message in commits {
            let result = try await ProcessRunner.git(
                ["-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", message],
                in: dir.path
            )
            try #require(result.isSuccess, "commit failed: \(result.stderr)")
        }
        return dir
    }

    @Test("Commit links follow the origin remote format (config only, never contacted)")
    func commitLinks() async throws {
        let repo = try await makeRepo(commits: ["feat(ui): button", "fix: crash", "chore: deps", "plain message"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let cases: [(remote: String?, expected: String?)] = [
            (nil, nil),
            ("git@github.example:owner/repo.git", "https://github.example/owner/repo/commit/"),
            ("ssh://git@git.example/owner/repo.git", "https://git.example/owner/repo/commit/"),
            ("https://git.example/owner/repo", "https://git.example/owner/repo/commit/"),
            ("/local/path/repo.git", nil),
        ]
        for testCase in cases {
            _ = try await ProcessRunner.git(["config", "--unset", "remote.origin.url"], in: repo.path)
            if let remote = testCase.remote {
                _ = try await ProcessRunner.git(["config", "remote.origin.url", remote], in: repo.path)
            }
            let output = try await GenerateReleaseNotesTask().run(.init(workingDirectory: repo.path, autoDetectLatestTag: true))
            if let expected = testCase.expected {
                #expect(output.notes.contains(expected))
            } else {
                #expect(output.notes.contains("(#"))
                #expect(!output.notes.contains("/commit/"))
            }
            #expect(output.notes.contains("### 🚀 Features"))
            #expect(output.notes.contains("* **ui**:"))
            #expect(output.notes.contains("### 🔧 Other Changes"))
        }
    }

    @Test("explicitToOnly, fullHistory, unlimited fallback, output files, and git failures")
    func sourcesAndOutputs() async throws {
        let repo = try await makeRepo(commits: ["feat: one", "fix(core): two"])
        defer { try? FileManager.default.removeItem(at: repo) }

        let toOnly = try await GenerateReleaseNotesTask().run(.init(to: "HEAD", workingDirectory: repo.path, autoDetectLatestTag: false, plainText: true))
        #expect(toOnly.source == .explicitToOnly("HEAD"))
        #expect(toOnly.notes.contains("- core:"))

        let full = try await GenerateReleaseNotesTask().run(.init(workingDirectory: repo.path, outputPath: "NOTES.md", autoDetectLatestTag: false, plainText: true))
        #expect(full.source == .fullHistory)
        #expect(try String(contentsOf: repo.appendingPathComponent("NOTES.md"), encoding: .utf8) == full.notes)

        let absolute = repo.appendingPathComponent("abs.txt").path
        let unlimited = try await GenerateReleaseNotesTask().run(.init(workingDirectory: repo.path, outputPath: absolute, fallbackMaxCommits: 0, plainText: true))
        #expect(unlimited.source == .fallback(limit: nil))
        #expect(FileManager.default.fileExists(atPath: absolute))

        await #expect(throws: GenerateReleaseNotesTask.ReleaseNotesError.self) {
            _ = try await GenerateReleaseNotesTask().run(.init(workingDirectory: repo.path, outputPath: repo.appendingPathComponent("missing/dir/x.md").path, plainText: true))
        }
        let gitError = await #expect(throws: GenerateReleaseNotesTask.ReleaseNotesError.self) {
            _ = try await GenerateReleaseNotesTask().run(.init(from: "no-such-ref", workingDirectory: repo.path, plainText: true))
        }
        #expect(gitError?.errorDescription?.contains("git log failed") == true)
        #expect(GenerateReleaseNotesTask.ReleaseNotesError.emptyCommitHistory.errorDescription?.isEmpty == false)
    }

    @Test("Truncation handles zero, tiny, line-boundary, and single long line limits")
    func truncation() async throws {
        let repo = try await makeRepo(commits: ["feat: " + String(repeating: "x", count: 60), "fix: short"])
        defer { try? FileManager.default.removeItem(at: repo) }
        func notes(_ max: Int) async throws -> String {
            try await GenerateReleaseNotesTask().run(.init(workingDirectory: repo.path, plainText: true, maxLength: max)).notes
        }
        #expect(try await notes(0) == "")
        #expect(try await notes(3).count == 3)
        let boundary = try await notes(40)
        #expect(boundary.hasSuffix("\n...") && boundary.count <= 40)
        let long = try await notes(8)
        #expect(long.count <= 8)
        #expect(try await notes(10_000).contains("short"))
    }
}
