import ArgumentParser
import Foundation
import Testing
@testable import appitool

@Suite("FlowPrerelease Tests")
struct FlowPrereleaseTests {

    private struct StubFlowPreset: FlowPreset {
        let name = "Stub"
        let description = "Stub preset for prerelease tests"
    }

    // MARK: - Git Repo Test Helpers

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appitool-flow-prerelease-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    private func withTempGitRepo(_ body: (URL) async throws -> Void) async throws {
        try await withTempDir { dir in
            let initResult = try await ProcessRunner.git(["init"], in: dir.path)
            try #require(initResult.isSuccess, "git init failed: \(initResult.stderr)")
            try await body(dir)
        }
    }

    private func commit(_ message: String, in dir: URL) async throws {
        let result = try await ProcessRunner.git(
            [
                "-c", "user.name=Test",
                "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false",
                "commit", "--allow-empty", "-m", message,
            ],
            in: dir.path
        )
        try #require(result.isSuccess, "git commit failed: \(result.stderr)")
    }

    private func tag(_ name: String, in dir: URL) async throws {
        let result = try await ProcessRunner.git(
            [
                "-c", "user.name=Test",
                "-c", "user.email=test@example.com",
                "-c", "tag.gpgsign=false",
                "tag", "-a", name, "-m", "Release \(name)",
            ],
            in: dir.path
        )
        try #require(result.isSuccess, "git tag failed: \(result.stderr)")
    }

    // MARK: - FlowPreset.prerelease Tests

    @Test("Preserves manual changelog without invoking git")
    func preservesManualChangelogWithoutGit() async throws {
        try await withTempDir { nonGitDir in
            var context = FlowContext(
                platform: .ios,
                distribution: .appstore,
                projectDirectory: nonGitDir,
                changelog: "  Custom manual notes  "
            )

            try await StubFlowPreset().prerelease(context: &context)

            #expect(context.changelog == "Custom manual notes")
        }
    }

    @Test("Uses releaseNotesFrom override instead of auto-detected tag")
    func releaseNotesFromOverridesAutoTag() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: base change", in: dir)
            try await tag("🍏_1.0.0_1", in: dir)
            try await commit("feat: included via override", in: dir)
            try await tag("🍏_1.0.0_2", in: dir)
            try await commit("fix: latest fix", in: dir)

            var context = FlowContext(
                platform: .ios,
                distribution: .appstore,
                projectDirectory: dir,
                releaseNotesFrom: "🍏_1.0.0_1"
            )

            try await StubFlowPreset().prerelease(context: &context)

            let notes = try #require(context.changelog)
            #expect(notes.contains("included via override"))
            #expect(notes.contains("latest fix"))
            #expect(!notes.contains("base change"))
        }
    }

    @Test("iOS appstore excludes adhoc/development tags and leaves changelog nil when HEAD is tagged")
    func iosAppStoreExclusionsAndTaggedHead() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: appstore baseline", in: dir)
            try await tag("🍏_1.0.0_1", in: dir)
            try await commit("feat: shipped in adhoc", in: dir)
            try await tag("🍏_1.0.0_2_adhoc", in: dir)
            try await commit("fix: post adhoc fix", in: dir)

            var appStoreContext = FlowContext(
                platform: .ios,
                distribution: .appstore,
                projectDirectory: dir
            )
            try await StubFlowPreset().prerelease(context: &appStoreContext)

            let appStoreNotes = try #require(appStoreContext.changelog)
            #expect(appStoreNotes.contains("shipped in adhoc"))
            #expect(appStoreNotes.contains("post adhoc fix"))
            #expect(!appStoreNotes.contains("appstore baseline"))

            // Now tag HEAD with an iOS appstore tag and verify changelog stays nil
            try await tag("🍏_1.0.0_3", in: dir)

            var retaggedContext = FlowContext(
                platform: .ios,
                distribution: .appstore,
                projectDirectory: dir
            )
            try await StubFlowPreset().prerelease(context: &retaggedContext)

            #expect(retaggedContext.changelog == nil)
        }
    }

    @Test("Android appstore enforces 500-char limit and excludes adhoc tags while adhoc allows up to 4000 chars")
    func androidStoreLimitVsAdHocLimitAndExclusions() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: initial release", in: dir)
            try await tag("🤖_1.0.0_1", in: dir)
            try await commit("feat: between appstore and adhoc", in: dir)
            try await tag("🤖_1.0.0_2_adhoc", in: dir)

            for index in 1...15 {
                try await commit(
                    "fix: implement descriptive android capability number \(index) for release notes limit validation",
                    in: dir
                )
            }

            var playContext = FlowContext(
                platform: .android,
                distribution: .appstore,
                projectDirectory: dir
            )
            try await StubFlowPreset().prerelease(context: &playContext)

            let playNotes = try #require(playContext.changelog)
            #expect(playNotes.count <= 500)
            #expect(playNotes.hasSuffix("..."))
            #expect(playNotes.contains("between appstore and adhoc"))
            #expect(!playNotes.contains("initial release"))

            var adhocContext = FlowContext(
                platform: .android,
                distribution: .adhoc,
                projectDirectory: dir
            )
            try await StubFlowPreset().prerelease(context: &adhocContext)

            let adhocNotes = try #require(adhocContext.changelog)
            #expect(adhocNotes.count > 500)
            #expect(adhocNotes.count <= 4000)
            #expect(!adhocNotes.contains("between appstore and adhoc"))
            #expect(adhocNotes.contains("capability number 15"))
        }
    }

    // MARK: - CLI Option Parsing Tests

    @Test("FlowIOSCommand and FlowAndroidCommand parse long-only release notes options and reject short forms")
    func flowCommandsParseLongOnlyReleaseNotesOptions() throws {
        let iosDefault = try FlowIOSCommand.parse([])
        let iosDefaultResolved = iosDefault.releaseNotesOptions.resolve()
        #expect(iosDefaultResolved.releaseNotes == nil)
        #expect(iosDefaultResolved.notesFrom == nil)
        #expect(iosDefaultResolved.notesLocale == "en-US")

        let iosCustom = try FlowIOSCommand.parse([
            "--release-notes", "  Bug fixes and improvements  ",
            "--notes-from", " 🍏_1.2.0_10 ",
            "--notes-locale", " tr-TR ",
        ])
        let iosCustomResolved = iosCustom.releaseNotesOptions.resolve()
        #expect(iosCustomResolved.releaseNotes == "Bug fixes and improvements")
        #expect(iosCustomResolved.notesFrom == "🍏_1.2.0_10")
        #expect(iosCustomResolved.notesLocale == "tr-TR")

        let androidCustom = try FlowAndroidCommand.parse([
            "--release-notes", "Play Store notes",
            "--notes-from", "🤖_2.0.0_20",
            "--notes-locale", "de-DE",
        ])
        let androidResolved = androidCustom.releaseNotesOptions.resolve()
        #expect(androidResolved.releaseNotes == "Play Store notes")
        #expect(androidResolved.notesFrom == "🤖_2.0.0_20")
        #expect(androidResolved.notesLocale == "de-DE")

        #expect(throws: (any Error).self) {
            try FlowIOSCommand.parse(["-r", "short"])
        }
        #expect(throws: (any Error).self) {
            try FlowIOSCommand.parse(["-l", "tr-TR"])
        }
        #expect(throws: (any Error).self) {
            try FlowAndroidCommand.parse(["-r", "short"])
        }
        #expect(throws: (any Error).self) {
            try FlowAndroidCommand.parse(["-l", "tr-TR"])
        }
    }
}
