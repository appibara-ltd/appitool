import ArgumentParser
import Foundation
import Testing
@testable import appitool

@Suite("CI Guard Tests")
struct CIGuardTests {

    // MARK: - CIEnvironment Resolution Tests

    @Test("CIEnvironment defaults to non-CI when flag is nil and environment is empty")
    func defaultNonCI() {
        let res = CIEnvironment.resolve(flag: nil, environment: [:])
        #expect(res.isCI == false)
        #expect(res.source == nil)
    }

    @Test("Explicit --ci and --no-ci flags override all CI environment variables")
    func flagOverridesEnvironment() {
        let enableOverride = CIEnvironment.resolve(flag: true, environment: ["CI": "false"])
        #expect(enableOverride.isCI == true)
        #expect(enableOverride.source == "--ci flag")

        let disableOverride = CIEnvironment.resolve(
            flag: false,
            environment: ["CI": "true", "GITHUB_ACTIONS": "true", "GITLAB_CI": "true"]
        )
        #expect(disableOverride.isCI == false)
        #expect(disableOverride.source == "--no-ci flag")
    }

    @Test("CI environment variable handles truthy and falsy values and suppresses provider fallback when explicitly false")
    func genericCIEnvVarTruthiness() {
        for truthy in ["true", "1", "yes", "TRUE", "on", "anything"] {
            let res = CIEnvironment.resolve(flag: nil, environment: ["CI": truthy])
            #expect(res.isCI == true)
            #expect(res.source == "CI environment variable")
        }

        for falsy in ["false", "0", "no", "off", "FALSE", "Off"] {
            let res = CIEnvironment.resolve(
                flag: nil,
                environment: ["CI": falsy, "GITHUB_ACTIONS": "true"]
            )
            #expect(res.isCI == false)
            #expect(res.source == "CI environment variable")
        }

        // Blank CI falls through to known provider env vars
        let fallback = CIEnvironment.resolve(
            flag: nil,
            environment: ["CI": "   ", "GITHUB_ACTIONS": "true"]
        )
        #expect(fallback.isCI == true)
        #expect(fallback.source == "GITHUB_ACTIONS environment variable")
    }

    @Test("All known CI provider environment variables are detected when truthy and ignored when falsy or blank")
    func knownCIProviderVariables() {
        for key in CIEnvironment.knownCIEnvVars {
            let sampleValue = key == "JENKINS_URL" ? "https://jenkins.example.com/" : "true"
            let truthy = CIEnvironment.resolve(flag: nil, environment: [key: sampleValue])
            #expect(truthy.isCI == true)
            #expect(truthy.source == "\(key) environment variable")

            for falsyVal in ["false", "0", "no", "off", ""] {
                let falsy = CIEnvironment.resolve(flag: nil, environment: [key: falsyVal])
                #expect(falsy.isCI == false)
                #expect(falsy.source == nil)
            }
        }
    }

    // MARK: - CLI Parsing & OptionGroup Inheritance Tests

    @Test("Root and subcommand --ci / --no-ci flags parse cleanly in any position with last-wins exclusivity")
    func cliFlagPositionAndPrecedence() throws {
        let prefix = try #require(
            try appitool.parseAsRoot(["--ci", "apple", "delete-user", "-u", "a@b.com"]) as? AppleDeleteUserCommand
        )
        #expect(prefix.ciFlagOverride == true)
        #expect(prefix.isDestructive == true)
        #expect(prefix.destructiveCommandDescription == "apple delete-user")

        let suffix = try #require(
            try appitool.parseAsRoot(["apple", "delete-user", "-u", "a@b.com", "--ci"]) as? AppleDeleteUserCommand
        )
        #expect(suffix.ciFlagOverride == true)

        let overridden = try #require(
            try appitool.parseAsRoot(["--ci", "apple", "delete-user", "-u", "a@b.com", "--no-ci"]) as? AppleDeleteUserCommand
        )
        #expect(overridden.ciFlagOverride == false)

        let directSubcommand = try #require(
            try AppleCommand.parseAsRoot(["delete-user", "-u", "a@b.com", "--ci"]) as? AppleDeleteUserCommand
        )
        #expect(directSubcommand.ciFlagOverride == true)
    }

    @Test("All 12 always-destructive commands respect --ci and --no-ci flags")
    func allAlwaysDestructiveCommandsRespectCIGuard() throws {
        let cases: [([String], String)] = [
            (["apple", "delete-identifier", "-a", "com.example.app"], "apple delete-identifier"),
            (["apple", "delete-profile", "-n", "TestProfile"], "apple delete-profile"),
            (["apple", "prune-profiles"], "apple prune-profiles"),
            (["apple", "delete-certificate", "-n", "TestCert"], "apple delete-certificate"),
            (["apple", "prune-certificates"], "apple prune-certificates"),
            (["apple", "disable-device", "--udid", "00008020-000000000000002E"], "apple disable-device"),
            (["apple", "delete-user", "-u", "a@b.com"], "apple delete-user"),
            (["apple", "cancel-invitation", "-i", "inv-1"], "apple cancel-invitation"),
            (["apple", "screenshots", "delete", "-i", "ss-1"], "apple screenshots delete"),
            (["google", "screenshots", "delete", "-l", "en-US", "-t", "phone", "-a"], "google screenshots delete"),
            (["firebase", "delete-user", "-u", "uid-1"], "firebase delete-user"),
            (["firebase", "firestore", "delete", "users/alice"], "firebase firestore delete"),
        ]

        let ciEnv = ["CI": "true", "GITHUB_ACTIONS": "true"]

        for (args, expectedDescription) in cases {
            let parsedDefault = try #require(try appitool.parseAsRoot(args) as? any BaseCommand)
            #expect(parsedDefault.isDestructive == true)
            #expect(parsedDefault.destructiveCommandDescription == expectedDescription)
            #expect(parsedDefault.ciFlagOverride == nil)
            #expect(parsedDefault.ciSkipResolution(environment: [:]) == nil)
            #expect(parsedDefault.ciSkipResolution(environment: ciEnv)?.isCI == true)

            let parsedCI = try #require(try appitool.parseAsRoot(["--ci"] + args) as? any BaseCommand)
            #expect(parsedCI.ciFlagOverride == true)
            let skipCI = parsedCI.ciSkipResolution(environment: [:])
            #expect(skipCI?.isCI == true)
            #expect(skipCI?.source == "--ci flag")

            let parsedNoCI = try #require(try appitool.parseAsRoot(args + ["--no-ci"]) as? any BaseCommand)
            #expect(parsedNoCI.ciFlagOverride == false)
            #expect(parsedNoCI.ciSkipResolution(environment: ciEnv) == nil)
        }
    }

    @Test("MatchIOSCommand guards nuke and prune as destructive while allowing sync in CI")
    func matchIOSConditionalGuard() throws {
        let nukeDefault = try #require(try appitool.parseAsRoot(["--ci", "match", "nuke"]) as? MatchIOSCommand)
        #expect(nukeDefault.resolvedMatchAction == .nuke)
        #expect(nukeDefault.isDestructive == true)
        #expect(nukeDefault.destructiveCommandDescription == "match ios nuke")
        #expect(nukeDefault.ciSkipResolution(environment: [:])?.isCI == true)

        let nukeFlag = try #require(try appitool.parseAsRoot(["match", "ios", "--nuke", "--ci"]) as? MatchIOSCommand)
        #expect(nukeFlag.resolvedMatchAction == .nuke)
        #expect(nukeFlag.isDestructive == true)
        #expect(nukeFlag.ciSkipResolution(environment: [:])?.isCI == true)

        let pruneExplicit = try #require(try appitool.parseAsRoot(["match", "ios", "prune", "--ci"]) as? MatchIOSCommand)
        #expect(pruneExplicit.resolvedMatchAction == .prune)
        #expect(pruneExplicit.isDestructive == true)
        #expect(pruneExplicit.destructiveCommandDescription == "match ios prune")
        #expect(pruneExplicit.ciSkipResolution(environment: [:])?.isCI == true)

        let pruneFlag = try #require(try appitool.parseAsRoot(["match", "--prune", "--ci"]) as? MatchIOSCommand)
        #expect(pruneFlag.resolvedMatchAction == .prune)
        #expect(pruneFlag.isDestructive == true)
        #expect(pruneFlag.ciSkipResolution(environment: [:])?.isCI == true)

        let syncExplicit = try #require(try appitool.parseAsRoot(["--ci", "match", "ios", "appstore"]) as? MatchIOSCommand)
        #expect(syncExplicit.resolvedMatchAction == .sync)
        #expect(syncExplicit.isDestructive == false)
        #expect(syncExplicit.ciSkipResolution(environment: ["CI": "true"]) == nil)

        let syncDefaultSub = try #require(try appitool.parseAsRoot(["--ci", "match", "appstore"]) as? MatchIOSCommand)
        #expect(syncDefaultSub.resolvedMatchAction == .sync)
        #expect(syncDefaultSub.isDestructive == false)
        #expect(syncDefaultSub.ciSkipResolution(environment: ["CI": "true"]) == nil)
    }

    @Test("Non-destructive commands accept --ci without skipping and -c short flags remain intact")
    func nonDestructiveAndShortFlagNonCollision() throws {
        _ = try appitool.parseAsRoot(["--ci", "status"])
        _ = try appitool.parseAsRoot(["status", "--ci"])
        _ = try appitool.parseAsRoot(["--ci", "clean", "--dry-run"])

        let listUsers = try #require(try appitool.parseAsRoot(["--ci", "apple", "list-users"]) as? AppleListUsersCommand)
        #expect(listUsers.isDestructive == false)
        #expect(listUsers.ciSkipResolution(environment: ["CI": "true"]) == nil)

        let selfUpdateCheck = try #require(try appitool.parseAsRoot(["--ci", "self-update", "--check"]) as? SelfUpdateCommand)
        #expect(selfUpdateCheck.check == true)
        #expect(selfUpdateCheck.isDestructive == false)

        let selfUpdateShort = try #require(try appitool.parseAsRoot(["self-update", "-c"]) as? SelfUpdateCommand)
        #expect(selfUpdateShort.check == true)

        let buildIOSShort = try #require(try appitool.parseAsRoot(["build", "ios", "-c", "Debug"]) as? BuildIOSCommand)
        #expect(buildIOSShort.configuration == "Debug")
    }

    // MARK: - Runtime No-Op Execution Tests

    @Test("Destructive commands return cleanly without credentials when --ci is active")
    func destructiveCommandsSkipCleanlyAtRuntime() async throws {
        let commands: [[String]] = [
            ["--ci", "apple", "delete-user", "-u", "a@b.com"],
            ["--ci", "apple", "delete-identifier", "-a", "com.example.app"],
            ["--ci", "apple", "screenshots", "delete", "-i", "ss-1"],
            ["--ci", "google", "screenshots", "delete", "-l", "en-US", "-t", "phone", "-a"],
            ["--ci", "match", "nuke"],
            ["--ci", "match", "ios", "prune"],
            ["--ci", "firebase", "delete-user", "-u", "uid-1"],
            ["--ci", "firebase", "firestore", "delete", "users/alice"],
        ]

        for args in commands {
            var parsed = try #require(try appitool.parseAsRoot(args) as? AsyncParsableCommand)
            try await parsed.run()
        }
    }
}
