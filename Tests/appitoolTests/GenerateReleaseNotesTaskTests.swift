import Foundation
import Testing
@testable import appitool

@Suite("GenerateReleaseNotesTask Tests")
struct GenerateReleaseNotesTaskTests {

    // MARK: - Git Repo Test Helpers

    private func withTempGitRepo(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appitool-release-notes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let initResult = try await ProcessRunner.git(["init"], in: dir.path)
        try #require(initResult.isSuccess, "git init failed: \(initResult.stderr)")

        try await body(dir)
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

    private func tag(_ name: String, annotated: Bool = true, in dir: URL) async throws {
        var args = [
            "-c", "user.name=Test",
            "-c", "user.email=test@example.com",
            "-c", "tag.gpgsign=false",
            "tag",
        ]
        if annotated {
            args.append(contentsOf: ["-a", name, "-m", "Release \(name)"])
        } else {
            args.append(name)
        }
        let result = try await ProcessRunner.git(args, in: dir.path)
        try #require(result.isSuccess, "git tag failed: \(result.stderr)")
    }

    // MARK: - Tag Detection & Edge Cases

    @Test("Returns empty notes when HEAD already sits on a matching tag with an older tag behind")
    func headOnMatchingTagWithOlderTagReturnsEmpty() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: initial", in: dir)
            try await tag("🍏_1.0.0_1", in: dir)
            try await commit("fix: bug one", in: dir)
            try await tag("🍏_1.0.0_2", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    tagPrefix: "🍏_",
                    excludeTagPatterns: ["*_adhoc", "*_development"],
                    plainText: true
                )
            )

            #expect(output.notes.isEmpty)
            #expect(output.source == .tag("🍏_1.0.0_2"))
        }
    }

    @Test("Returns empty notes when HEAD sits on the only matching tag without falling back")
    func headOnOnlyMatchingTagReturnsEmpty() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: first", in: dir)
            try await commit("fix: second", in: dir)
            try await tag("🍏_1.0.0_1", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    tagPrefix: "🍏_",
                    plainText: true
                )
            )

            #expect(output.notes.isEmpty)
            #expect(output.source == .tag("🍏_1.0.0_1"))
        }
    }

    @Test("Skips excluded adhoc tag on HEAD and diffs from previous matching appstore tag")
    func headOnExcludedTagUsesPreviousMatchingTag() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: baseline", in: dir)
            try await tag("🍏_1.0.0_1", in: dir)
            try await commit("feat: new feature", in: dir)
            try await tag("🍏_1.0.0_2_adhoc", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    tagPrefix: "🍏_",
                    excludeTagPatterns: ["*_adhoc", "*_development"],
                    plainText: true
                )
            )

            #expect(output.source == .tag("🍏_1.0.0_1"))
            #expect(output.notes.contains("new feature"))
            #expect(!output.notes.contains("baseline"))
        }
    }

    @Test("Ignores other platform tag on HEAD and diffs from latest matching platform tag")
    func headOnOtherPlatformTagUsesMatchingPlatformTag() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: android base", in: dir)
            try await tag("🤖_1.0.0_1", in: dir)
            try await commit("fix: android fix", in: dir)
            try await tag("🍏_1.0.0_1", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    tagPrefix: "🤖_",
                    excludeTagPatterns: ["*_adhoc", "*_development"],
                    plainText: true
                )
            )

            #expect(output.source == .tag("🤖_1.0.0_1"))
            #expect(output.notes.contains("android fix"))
            #expect(!output.notes.contains("android base"))
        }
    }

    @Test("Generates notes for new commits after latest matching tag for notes and flow defaults")
    func newCommitsAfterLatestTag() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: old", in: dir)
            try await tag("v0.1.0", in: dir)
            try await commit("feat: new feature", in: dir)
            try await commit("fix(auth): token refresh", in: dir)

            let markdownOutput = try await GenerateReleaseNotesTask().run(
                .init(workingDirectory: dir.path)
            )

            #expect(markdownOutput.source == .tag("v0.1.0"))
            #expect(markdownOutput.notes.contains("new feature"))
            #expect(markdownOutput.notes.contains("token refresh"))
            #expect(markdownOutput.notes.contains("auth"))
            #expect(!markdownOutput.notes.contains("old"))

            let prefixedPlainOutput = try await GenerateReleaseNotesTask().run(
                .init(
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    tagPrefix: "v",
                    plainText: true
                )
            )

            #expect(prefixedPlainOutput.source == .tag("v0.1.0"))
            #expect(prefixedPlainOutput.notes.contains("new feature"))
            #expect(prefixedPlainOutput.notes.contains("token refresh"))
            #expect(prefixedPlainOutput.notes.contains("auth"))
            #expect(!prefixedPlainOutput.notes.contains("old"))
        }
    }

    @Test("Falls back to fallbackMaxCommits when no matching tags exist")
    func fallsBackToMaxCommitsWhenUntagged() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: commit one", in: dir)
            try await commit("feat: commit two", in: dir)
            try await commit("feat: commit three", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    tagPrefix: "🍏_",
                    fallbackMaxCommits: 2,
                    plainText: true
                )
            )

            #expect(output.source == .fallback(limit: 2))
            #expect(output.notes.contains("commit three"))
            #expect(output.notes.contains("commit two"))
            #expect(!output.notes.contains("commit one"))
        }
    }

    @Test("Generates notes for explicit from and to tag range")
    func explicitFromAndToRange() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: c1", in: dir)
            try await tag("v0.1.0", in: dir)
            try await commit("feat: c2", in: dir)
            try await tag("v0.2.0", in: dir)
            try await commit("feat: c3", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    from: "v0.1.0",
                    to: "v0.2.0",
                    workingDirectory: dir.path,
                    plainText: true
                )
            )

            #expect(output.source == .explicitFrom("v0.1.0"))
            #expect(output.notes.contains("c2"))
            #expect(!output.notes.contains("c1"))
            #expect(!output.notes.contains("c3"))
        }
    }

    @Test("Returns empty notes when to sits directly on a matching tag and from is omitted")
    func toOnTagWithoutFromReturnsEmpty() async throws {
        try await withTempGitRepo { dir in
            try await commit("feat: c1", in: dir)
            try await tag("v0.1.0", in: dir)
            try await commit("feat: c2", in: dir)
            try await tag("v0.2.0", in: dir)
            try await commit("feat: c3", in: dir)

            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    from: nil,
                    to: "v0.2.0",
                    workingDirectory: dir.path,
                    autoDetectLatestTag: true,
                    plainText: true
                )
            )

            #expect(output.source == .tag("v0.2.0"))
            #expect(output.notes.isEmpty)
        }
    }
}
