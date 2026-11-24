import ArgumentParser
import Foundation
import Testing
@testable import appitool

@Suite("MatchOptions Tests", .serialized)
struct MatchOptionsTests {

    @Test("All five Match, Flow, and Build commands parse long Match storage options cleanly")
    func allCommandsParseLongMatchStorageOptions() throws {
        let args = [
            "--match-git-url", "https://github.com/example/certs.git",
            "--match-git-branch", "develop",
            "--match-git-token", "tok_123",
            "--match-password", "secret_pass",
        ]

        let matchIOS = try MatchIOSSyncCommand.parse(args)
        #expect(matchIOS.matchOptions.storage.matchGitUrl == "https://github.com/example/certs.git")
        #expect(matchIOS.matchOptions.storage.matchGitBranch == "develop")
        #expect(matchIOS.matchOptions.storage.matchGitToken == "tok_123")
        #expect(matchIOS.matchOptions.storage.matchPassword == "secret_pass")

        let matchAndroid = try MatchAndroidCommand.parse(args)
        #expect(matchAndroid.matchOptions.matchGitUrl == "https://github.com/example/certs.git")
        #expect(matchAndroid.matchOptions.matchGitBranch == "develop")
        #expect(matchAndroid.matchOptions.matchGitToken == "tok_123")
        #expect(matchAndroid.matchOptions.matchPassword == "secret_pass")

        let flowIOS = try FlowIOSCommand.parse(args)
        #expect(flowIOS.matchOptions.storage.matchGitUrl == "https://github.com/example/certs.git")
        #expect(flowIOS.matchOptions.storage.matchGitBranch == "develop")
        #expect(flowIOS.matchOptions.storage.matchGitToken == "tok_123")
        #expect(flowIOS.matchOptions.storage.matchPassword == "secret_pass")

        let flowAndroid = try FlowAndroidCommand.parse(args)
        #expect(flowAndroid.matchOptions.matchGitUrl == "https://github.com/example/certs.git")
        #expect(flowAndroid.matchOptions.matchGitBranch == "develop")
        #expect(flowAndroid.matchOptions.matchGitToken == "tok_123")
        #expect(flowAndroid.matchOptions.matchPassword == "secret_pass")

        let buildAndroid = try BuildAndroidCommand.parse(args)
        #expect(buildAndroid.matchOptions.matchGitUrl == "https://github.com/example/certs.git")
        #expect(buildAndroid.matchOptions.matchGitBranch == "develop")
        #expect(buildAndroid.matchOptions.matchGitToken == "tok_123")
        #expect(buildAndroid.matchOptions.matchPassword == "secret_pass")
    }

    @Test("iOS Match and Flow commands parse keychain, team-id, and readonly with proper defaults")
    func iosCommandsParseMatchOptionsAndReadonlyDefaults() throws {
        let args = [
            "--keychain-name", "ci.keychain",
            "--keychain-password", "kc_secret",
            "--team-id", "TEAM123456",
            "--readonly",
        ]

        let matchIOS = try MatchIOSSyncCommand.parse(args)
        let matchResolved = matchIOS.matchOptions.resolve(defaultReadonly: false)
        #expect(matchResolved.keychainName == "ci.keychain")
        #expect(matchResolved.keychainPassword == "kc_secret")
        #expect(matchResolved.teamId == "TEAM123456")
        #expect(matchResolved.readonly == true)

        let flowIOS = try FlowIOSCommand.parse(args)
        let flowResolved = flowIOS.matchOptions.resolve()
        #expect(flowResolved.keychainName == "ci.keychain")
        #expect(flowResolved.keychainPassword == "kc_secret")
        #expect(flowResolved.teamId == "TEAM123456")
        #expect(flowResolved.readonly == true)

        // Default readonly semantics
        let matchIOSDefault = try MatchIOSSyncCommand.parse([])
        #expect(matchIOSDefault.matchOptions.resolve(defaultReadonly: false).readonly == false)

        let flowIOSDefault = try FlowIOSCommand.parse([])
        let originalMatchReadonly = EnvLoader.value(for: "MATCH_READONLY")
        defer {
            EnvLoader.setEnvironmentVariable(
                key: "MATCH_READONLY",
                value: originalMatchReadonly ?? "",
                overwrite: true
            )
        }
        EnvLoader.setEnvironmentVariable(key: "MATCH_READONLY", value: "", overwrite: true)
        #expect(flowIOSDefault.matchOptions.resolve().readonly == true)

        EnvLoader.setEnvironmentVariable(key: "MATCH_READONLY", value: "false", overwrite: true)
        #expect(flowIOSDefault.matchOptions.resolve().readonly == false)
    }

    @Test("Removed legacy aliases and short flags fail to parse")
    func removedAliasesAndShortFlagsFail() {
        #expect(throws: (any Error).self) {
            try MatchIOSSyncCommand.parse(["--git-url", "https://github.com/example/certs.git"])
        }
        #expect(throws: (any Error).self) {
            try MatchIOSSyncCommand.parse(["--password", "secret"])
        }
        #expect(throws: (any Error).self) {
            try MatchIOSSyncCommand.parse(["-g", "https://github.com/example/certs.git"])
        }
        #expect(throws: (any Error).self) {
            try MatchIOSSyncCommand.parse(["-r"])
        }

        #expect(throws: (any Error).self) {
            try MatchAndroidCommand.parse(["--git-url", "https://github.com/example/certs.git"])
        }
        #expect(throws: (any Error).self) {
            try MatchAndroidCommand.parse(["--password", "secret"])
        }
        #expect(throws: (any Error).self) {
            try MatchAndroidCommand.parse(["-g", "https://github.com/example/certs.git"])
        }

        #expect(throws: (any Error).self) {
            try FlowIOSCommand.parse(["--git-url", "https://github.com/example/certs.git"])
        }
        #expect(throws: (any Error).self) {
            try FlowAndroidCommand.parse(["--password", "secret"])
        }
        #expect(throws: (any Error).self) {
            try BuildAndroidCommand.parse(["--git-token", "tok_123"])
        }
    }

    @Test("Android commands reject iOS-only Match options")
    func androidCommandsRejectIOSOnlyMatchOptions() {
        for flag in [["--keychain-name", "ci.keychain"], ["--team-id", "TEAM123456"], ["--readonly"]] {
            #expect(throws: (any Error).self) {
                try FlowAndroidCommand.parse(flag)
            }
            #expect(throws: (any Error).self) {
                try BuildAndroidCommand.parse(flag)
            }
            #expect(throws: (any Error).self) {
                try MatchAndroidCommand.parse(flag)
            }
        }
    }

    @Test("MatchStorageOptions.require throws ValidationError when URL or password is missing and succeeds when provided")
    func matchStorageOptionsRequire() throws {
        let missingUrl = try MatchStorageOptions.parse([
            "--match-git-url", "",
            "--match-password", "secret",
        ])
        #expect(throws: ValidationError.self) {
            _ = try missingUrl.require()
        }

        let missingPassword = try MatchStorageOptions.parse([
            "--match-git-url", "https://github.com/example/certs.git",
            "--match-password", "",
        ])
        #expect(throws: ValidationError.self) {
            _ = try missingPassword.require()
        }

        let valid = try MatchStorageOptions.parse([
            "--match-git-url", "https://github.com/example/certs.git",
            "--match-git-branch", "main",
            "--match-git-token", "tok",
            "--match-password", "secret",
        ])
        let required = try valid.require()
        #expect(required.gitUrl == "https://github.com/example/certs.git")
        #expect(required.gitBranch == "main")
        #expect(required.gitToken == "tok")
        #expect(required.password == "secret")
    }

    @Test("MatchStorageOptions.resolve follows token fallback precedence: CLI > MATCH_GIT_TOKEN > GITHUB_TOKEN > GH_TOKEN")
    func matchStorageTokenFallbackPrecedence() throws {
        let keys = ["MATCH_GIT_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, EnvLoader.value(for: $0) ?? "") })
        defer {
            for (key, value) in originals {
                EnvLoader.setEnvironmentVariable(key: key, value: value, overwrite: true)
            }
        }

        for key in keys {
            EnvLoader.setEnvironmentVariable(key: key, value: "", overwrite: true)
        }

        let noCliOption = try MatchStorageOptions.parse([])
        #expect(noCliOption.resolve().gitToken == nil)

        EnvLoader.setEnvironmentVariable(key: "GH_TOKEN", value: "gh_tok", overwrite: true)
        #expect(noCliOption.resolve().gitToken == "gh_tok")

        EnvLoader.setEnvironmentVariable(key: "GITHUB_TOKEN", value: "github_tok", overwrite: true)
        #expect(noCliOption.resolve().gitToken == "github_tok")

        EnvLoader.setEnvironmentVariable(key: "MATCH_GIT_TOKEN", value: "match_tok", overwrite: true)
        #expect(noCliOption.resolve().gitToken == "match_tok")

        let withCliOption = try MatchStorageOptions.parse(["--match-git-token", "cli_tok"])
        #expect(withCliOption.resolve().gitToken == "cli_tok")
    }
}
