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
            try appitool.parseAsRoot(["--ci", "apple", "users", "delete", "--username", "a@b.com"]) as? AppleDeleteUserCommand
        )
        #expect(prefix.ciFlagOverride == true)
        #expect(prefix.isDestructive == true)
        #expect(prefix.destructiveCommandDescription == "apple users delete")

        let suffix = try #require(
            try appitool.parseAsRoot(["apple", "users", "delete", "--username", "a@b.com", "--ci"]) as? AppleDeleteUserCommand
        )
        #expect(suffix.ciFlagOverride == true)

        let overridden = try #require(
            try appitool.parseAsRoot(["--ci", "apple", "users", "delete", "--username", "a@b.com", "--no-ci"]) as? AppleDeleteUserCommand
        )
        #expect(overridden.ciFlagOverride == false)

        let directSubcommand = try #require(
            try AppleCommand.parseAsRoot(["users", "delete", "--username", "a@b.com", "--ci"]) as? AppleDeleteUserCommand
        )
        #expect(directSubcommand.ciFlagOverride == true)
    }

    @Test("All 12 always-destructive commands respect --ci and --no-ci flags")
    func allAlwaysDestructiveCommandsRespectCIGuard() throws {
        let cases: [([String], String)] = [
            (["apple", "identifiers", "delete", "-b", "com.example.app"], "apple identifiers delete"),
            (["apple", "profiles", "delete", "-n", "TestProfile"], "apple profiles delete"),
            (["apple", "profiles", "prune"], "apple profiles prune"),
            (["apple", "certificates", "delete", "-n", "TestCert"], "apple certificates delete"),
            (["apple", "certificates", "prune"], "apple certificates prune"),
            (["apple", "devices", "disable", "--udid", "00008020-000000000000002E"], "apple devices disable"),
            (["apple", "users", "delete", "--username", "a@b.com"], "apple users delete"),
            (["apple", "invitations", "cancel", "--id", "inv-1"], "apple invitations cancel"),
            (["apple", "assets", "delete", "--id", "ss-1"], "apple assets delete"),
            (["google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--all"], "google assets delete"),
            (["firebase", "users", "delete", "--uid", "uid-1"], "firebase users delete"),
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

    @Test("match ios nuke and prune subcommands are destructive while sync runs in CI")
    func matchIOSConditionalGuard() throws {
        let nuke = try #require(try appitool.parseAsRoot(["match", "ios", "nuke", "-t", "development", "--ci"]) as? MatchIOSNukeCommand)
        #expect(nuke.type == "development")
        #expect(nuke.isDestructive == true)
        #expect(nuke.destructiveCommandDescription == "match ios nuke")
        #expect(nuke.ciSkipResolution(environment: [:])?.isCI == true)

        let nukeRootCI = try #require(try appitool.parseAsRoot(["--ci", "match", "ios", "nuke"]) as? MatchIOSNukeCommand)
        #expect(nukeRootCI.isDestructive == true)

        let pruneAll = try #require(try appitool.parseAsRoot(["match", "ios", "prune", "--all", "--ci"]) as? MatchIOSPruneCommand)
        #expect(pruneAll.all == true)
        #expect(pruneAll.isDestructive == true)
        #expect(pruneAll.destructiveCommandDescription == "match ios prune")
        #expect(pruneAll.ciSkipResolution(environment: [:])?.isCI == true)

        let pruneType = try #require(try appitool.parseAsRoot(["match", "ios", "prune", "-t", "adhoc"]) as? MatchIOSPruneCommand)
        #expect(pruneType.type == "adhoc")
        #expect(pruneType.ciSkipResolution(environment: ["CI": "true"])?.isCI == true)
        #expect(pruneType.ciSkipResolution(environment: [:]) == nil)

        let syncExplicit = try #require(try appitool.parseAsRoot(["--ci", "match", "ios", "sync", "-t", "appstore"]) as? MatchIOSSyncCommand)
        #expect(syncExplicit.isDestructive == false)
        #expect(syncExplicit.ciSkipResolution(environment: ["CI": "true"]) == nil)

        let syncDefaultIOS = try #require(try appitool.parseAsRoot(["match", "ios", "-t", "adhoc", "--ci"]) as? MatchIOSSyncCommand)
        #expect(syncDefaultIOS.type == "adhoc")
        #expect(syncDefaultIOS.isDestructive == false)

        let syncDefaultMatch = try #require(try appitool.parseAsRoot(["--ci", "match", "--type", "appstore"]) as? MatchIOSSyncCommand)
        #expect(syncDefaultMatch.isDestructive == false)
        #expect(syncDefaultMatch.ciSkipResolution(environment: ["CI": "true"]) == nil)

        // Removed action flags, positional types, and options belonging to other actions are rejected.
        for args in [
            ["match", "ios", "--nuke"],
            ["match", "ios", "--prune"],
            ["match", "ios", "--all"],
            ["match", "ios", "adhoc"],
            ["match", "ios", "nuke", "development"],
            ["match", "ios", "prune", "all"],
            ["match", "ios", "prune", "--all", "-t", "adhoc"],
            ["match", "ios", "nuke", "--all"],
            ["match", "ios", "nuke", "--force"],
            ["match", "ios", "prune", "--identifiers", "com.example.app"],
            ["match", "ios", "nuke", "--readonly"],
        ] {
            #expect(throws: (any Error).self) {
                _ = try appitool.parseAsRoot(args)
            }
        }
    }

    @Test("Non-destructive commands accept --ci without skipping and -c short flags remain intact")
    func nonDestructiveAndShortFlagNonCollision() throws {
        _ = try appitool.parseAsRoot(["--ci", "status"])
        _ = try appitool.parseAsRoot(["status", "--ci"])
        _ = try appitool.parseAsRoot(["--ci", "clean", "--dry-run"])

        let listUsers = try #require(try appitool.parseAsRoot(["--ci", "apple", "users", "list"]) as? AppleListUsersCommand)
        #expect(listUsers.isDestructive == false)
        #expect(listUsers.ciSkipResolution(environment: ["CI": "true"]) == nil)

        let selfUpdateCheck = try #require(try appitool.parseAsRoot(["--ci", "self-update", "--check"]) as? SelfUpdateCommand)
        #expect(selfUpdateCheck.check == true)
        #expect(selfUpdateCheck.isDestructive == false)

        #expect(throws: (any Error).self) {
            _ = try appitool.parseAsRoot(["self-update", "-c"])
        }

        let buildIOSShort = try #require(try appitool.parseAsRoot(["build", "ios", "-c", "Debug"]) as? BuildIOSCommand)
        #expect(buildIOSShort.configuration == "Debug")
    }

    // MARK: - Runtime No-Op Execution Tests

    @Test("Destructive commands return cleanly without credentials when --ci is active")
    func destructiveCommandsSkipCleanlyAtRuntime() async throws {
        let commands: [[String]] = [
            ["--ci", "apple", "users", "delete", "--username", "a@b.com"],
            ["--ci", "apple", "identifiers", "delete", "--bundle-id", "com.example.app"],
            ["--ci", "apple", "assets", "delete", "--id", "ss-1"],
            ["--ci", "google", "assets", "delete", "--locale", "en-US", "-t", "phone", "--all"],
            ["--ci", "match", "ios", "nuke"],
            ["--ci", "match", "ios", "prune", "--all"],
            ["--ci", "firebase", "users", "delete", "--uid", "uid-1"],
            ["--ci", "firebase", "firestore", "delete", "users/alice"],
        ]

        for args in commands {
            var parsed = try #require(try appitool.parseAsRoot(args) as? AsyncParsableCommand)
            try await parsed.run()
        }
    }
}
