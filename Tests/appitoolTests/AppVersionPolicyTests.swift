import ArgumentParser
import Foundation
import Testing
@testable import appitool
import AppleServices

@Suite("App Version Policy Tests")
struct AppVersionPolicyTests {
    @Test("Versions compare numerically and patch bumps keep the shape")
    func compareAndBump() {
        #expect(AppVersionPolicy.compare("1.10", "1.9") == .orderedDescending)
        #expect(AppVersionPolicy.compare("1.0", "1.0.0") == .orderedSame)
        #expect(AppVersionPolicy.compare("1.0.8", "1.0.9") == .orderedAscending)
        #expect(AppVersionPolicy.highest(["1.0.8", "1.0.10", "1.0.9"]) == "1.0.10")
        #expect(AppVersionPolicy.bumpPatch("1.0.8") == "1.0.9")
        #expect(AppVersionPolicy.bumpPatch("1.2") == "1.2.1")
        #expect(AppVersionPolicy.bumpPatch("2") == "2.0.1")
        #expect(AppVersionPolicy.isValid("1.2.3"))
        #expect(!AppVersionPolicy.isValid("1.2.3.4"))
        #expect(!AppVersionPolicy.isValid("1.2-beta"))
    }

    @Test("Default version: project when higher, otherwise bumped latest with project update")
    func defaultDecision() throws {
        let higher = try AppVersionPolicy.resolveDefault(projectVersion: "1.1.0", existingVersions: ["1.0.8", "1.0.7"])
        #expect(higher == .init(version: "1.1.0", updatesProject: false, reason: higher.reason))

        let lower = try AppVersionPolicy.resolveDefault(projectVersion: "1.0.5", existingVersions: ["1.0.8"])
        #expect(lower.version == "1.0.9")
        #expect(lower.updatesProject == true)

        // Equal to the latest version cannot be created again → bump.
        let equal = try AppVersionPolicy.resolveDefault(projectVersion: "1.0.8", existingVersions: ["1.0.8"])
        #expect(equal.version == "1.0.9")
        #expect(equal.updatesProject == true)

        let noProject = try AppVersionPolicy.resolveDefault(projectVersion: nil, existingVersions: ["1.0.8"])
        #expect(noProject.version == "1.0.9")
        #expect(noProject.updatesProject == false)

        let firstRelease = try AppVersionPolicy.resolveDefault(projectVersion: "1.0.0", existingVersions: [])
        #expect(firstRelease.version == "1.0.0")
        #expect(firstRelease.updatesProject == false)

        #expect(throws: CommandError.self) {
            _ = try AppVersionPolicy.resolveDefault(projectVersion: nil, existingVersions: [])
        }
    }

    @Test("delete-version targets only editable versions and is CI-guarded")
    func deleteVersionSelection() throws {
        let versions: [AppleDeleteVersionCommand.Candidate] = [
            .init(id: "v9", versionString: "1.0.9", state: "PREPARE_FOR_SUBMISSION"),
            .init(id: "v8", versionString: "1.0.8", state: "READY_FOR_DISTRIBUTION"),
        ]
        #expect(try AppleDeleteVersionCommand.selectTarget(versions: versions, explicit: nil)?.id == "v9")
        #expect(try AppleDeleteVersionCommand.selectTarget(versions: versions, explicit: "1.0.9")?.id == "v9")
        #expect(try AppleDeleteVersionCommand.selectTarget(versions: [versions[1]], explicit: nil) == nil)
        #expect(throws: CommandError.self) {
            _ = try AppleDeleteVersionCommand.selectTarget(versions: versions, explicit: "1.0.8")
        }
        #expect(throws: CommandError.self) {
            _ = try AppleDeleteVersionCommand.selectTarget(versions: versions, explicit: "2.0.0")
        }

        let cmd = try #require(try appitool.parseAsRoot(["apple", "delete-version", "--dry-run", "--ci"]) as? AppleDeleteVersionCommand)
        #expect(cmd.isDestructive == true)
        #expect(cmd.destructiveCommandDescription == "apple delete-version")
        #expect(cmd.ciSkipResolution(environment: [:])?.isCI == true)
        #expect(AppleDeleteVersionCommand.hint(for: .apiError(status: 409, message: "x"))?.contains("never submitted") == true)
    }

    @Test("create-version validates release options and explains App Store Connect errors")
    func commandValidation() throws {
        let cmd = try #require(
            try appitool.parseAsRoot(["apple", "create-version", "--app-version", "1.2.0", "--release-type", "after-approval", "--dry-run"]) as? AppleCreateVersionCommand
        )
        #expect(cmd.app.appVersion == "1.2.0")
        #expect(try AppleCreateVersionCommand.releaseTypeValue("after-approval") == "AFTER_APPROVAL")
        _ = try appitool.parseAsRoot(["apple", "create-version", "--release-type", "scheduled", "--release-date", "2026-12-01T09:00:00Z"])

        for args in [
            ["apple", "create-version", "--release-type", "scheduled"],
            ["apple", "create-version", "--release-date", "2026-12-01T09:00:00Z"],
            ["apple", "create-version", "--release-type", "scheduled", "--release-date", "next week"],
            ["apple", "create-version", "--release-type", "soon"],
        ] {
            #expect(throws: (any Error).self) {
                _ = try appitool.parseAsRoot(args)
            }
        }

        #expect(AppleCreateVersionCommand.hint(for: .apiError(status: 409, message: "x"))?.contains("editable") == true)
        #expect(AppleCreateVersionCommand.hint(for: .apiError(status: 422, message: "x"))?.contains("version string") == true)
        #expect(AppleCreateVersionCommand.hint(for: .notFound("x")) == nil)
    }
}
