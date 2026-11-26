import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Sigstore
import Testing
@testable import appitool

/// Fake `gh` executable: records its arguments next to itself, prints a line, and exits with `exitCode`.
private func makeFakeGH(exitCode: Int32) throws -> (dir: URL, path: String) {
    let dir = try TestFiles.makeTempDir("appitool-fake-gh")
    let path = dir.appendingPathComponent("gh").path
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$(dirname "$0")/args.txt"
    echo "fake gh output"
    exit \(exitCode)
    """
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return (dir, path)
}

private func recordedArgs(_ dir: URL) -> [String] {
    let text = (try? String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
}

/// Real attestations of appitool v0.11.0 (`appitool-darwin-arm64.tar.gz`) and the trusted roots they
/// chain to, copied from sigstore-swift's test fixtures:
/// - `provenance.sigstore.json`: SLSA v1 provenance, public-good Sigstore (Fulcio, Rekor v1).
/// - `release.sigstore.json`: release attestation, GitHub's Sigstore instance (TSA only).
private enum AttestationFixtures {
    static let digest = "b5eeec2e36db5cfbdda72707ac80b3c807cab76631a35cf618739e29d331f0ce"

    static func data(_ name: String) throws -> Data {
        guard let url = Foundation.Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// An attestations API response carrying the given fixture bundles.
    static func apiResponse(_ names: [String]) throws -> StubResponse {
        let attestations = try names.map { name -> [String: Any] in
            ["bundle": try JSONSerialization.jsonObject(with: data(name)), "repository_id": 1]
        }
        return StubResponse(200, try JSONSerialization.data(withJSONObject: ["attestations": attestations]), headers: [:])
    }

    static let loader: ReleaseAttestationVerifier.TrustedRootLoader = { instance in
        switch instance {
        case .publicGood: try TrustedRoot(json: try data("trusted_root"))
        case .github: try TrustedRoot(json: try data("github_trusted_root"))
        }
    }
}

@Suite("ReleaseAttestationVerifier", .serialized)
struct ReleaseAttestationVerifierTests {
    private let artifact = URL(fileURLWithPath: "/nonexistent/appitool.tar.gz")

    private func verifier(gh: String?, repo: String = ReleaseAttestationVerifier.defaultRepo,
                          loader: ReleaseAttestationVerifier.TrustedRootLoader? = AttestationFixtures.loader,
                          session: URLSession) -> ReleaseAttestationVerifier {
        ReleaseAttestationVerifier(repo: repo, ghPath: gh, token: "tok", urlSession: session, loadTrustedRoot: loader)
    }

    @Test("Verifies with sigstore-swift alone when gh is not installed")
    func verifiesWithoutGH() async throws {
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(["provenance.sigstore", "release.sigstore"]))
        let outcome = try await HTTPStub.withSession(router) { session in
            try await verifier(gh: nil, session: session)
                .verify(artifact: artifact, sha256: AttestationFixtures.digest.uppercased(), workDirectory: FileManager.default.temporaryDirectory)
        }
        #expect(outcome == .verified(gh: .unavailable))
        let request = try #require(router.log.requests.first)
        #expect(request.url.absoluteString == "https://api.github.com/repos/appibara-ltd/appitool/attestations/sha256:\(AttestationFixtures.digest)")
        #expect(request.headers["Authorization"] == "Bearer tok")
    }

    @Test("gh agreeing confirms the sigstore-swift verdict")
    func ghAgrees() async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(["provenance.sigstore", "release.sigstore"]))

        let outcome = try await HTTPStub.withSession(router) { session in
            try await verifier(gh: gh.path, session: session)
                .verify(artifact: artifact, sha256: AttestationFixtures.digest, workDirectory: gh.dir)
        }

        #expect(outcome == .verified(gh: .agreed))
        let args = recordedArgs(gh.dir)
        #expect(Array(args.prefix(3)) == ["attestation", "verify", artifact.path])
        let bundlePath = args[try #require(args.firstIndex(of: "--bundle")) + 1]
        #expect(bundlePath.hasSuffix(".jsonl"))
        #expect(args[try #require(args.firstIndex(of: "--repo")) + 1] == "appibara-ltd/appitool")
        #expect(args[try #require(args.firstIndex(of: "--signer-workflow")) + 1] == "appibara-ltd/appitool/.github/workflows/release.yml")

        // One bundle per line, each a standalone JSON object.
        let lines = try String(contentsOfFile: bundlePath, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["mediaType"] as? String == "application/vnd.dev.sigstore.bundle.v0.3+json")
        }
    }

    @Test("gh disagreeing with a sigstore-swift pass aborts with gh's output")
    func ghDisagrees() async throws {
        let gh = try makeFakeGH(exitCode: 1)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(["provenance.sigstore"]))
        do {
            _ = try await HTTPStub.withSession(router) { session in
                try await verifier(gh: gh.path, session: session)
                    .verify(artifact: artifact, sha256: AttestationFixtures.digest, workDirectory: gh.dir)
            }
            Issue.record("expected ghDisagreed")
        } catch ReleaseAttestationVerifier.VerificationError.ghDisagreed(let output) {
            #expect(output.contains("fake gh output"))
        }
    }

    /// sigstore-swift decides first: a rejection never reaches gh.
    @Test("sigstore-swift rejections abort before gh runs", arguments: [
        ("wrong digest", "db4b4d0d1cb480bf9aeea253771c00febe627f236765fa37d6a5614f079a3aa0", "appibara-ltd/appitool", ["provenance.sigstore"]),
        ("wrong repository", AttestationFixtures.digest, "appibara-ltd/other", ["provenance.sigstore"]),
        ("release attestation only", AttestationFixtures.digest, "appibara-ltd/appitool", ["release.sigstore"]),
    ])
    func sigstoreRejects(_ name: String, _ digest: String, _ repo: String, _ bundles: [String]) async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(bundles))
        do {
            _ = try await HTTPStub.withSession(router) { session in
                try await verifier(gh: gh.path, repo: repo, session: session)
                    .verify(artifact: artifact, sha256: digest, workDirectory: gh.dir)
            }
            Issue.record("\(name): expected sigstoreRejected")
        } catch ReleaseAttestationVerifier.VerificationError.sigstoreRejected(let reasons) {
            #expect(!reasons.isEmpty, "\(name)")
        }
        #expect(recordedArgs(gh.dir).isEmpty, "\(name): gh must not run")
    }

    @Test("Unavailable trusted roots fail closed")
    func trustedRootUnavailable() async throws {
        struct Offline: Error {}
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(["provenance.sigstore"]))
        do {
            _ = try await HTTPStub.withSession(router) { session in
                try await verifier(gh: nil, loader: { _ in throw Offline() }, session: session)
                    .verify(artifact: artifact, sha256: AttestationFixtures.digest, workDirectory: FileManager.default.temporaryDirectory)
            }
            Issue.record("expected sigstoreRejected")
        } catch ReleaseAttestationVerifier.VerificationError.sigstoreRejected(let reasons) {
            #expect(reasons.contains { $0.contains("trusted root unavailable") })
        }
    }

    @Test("Missing, failed, malformed, and bundle-less API responses throw before verifying")
    func apiFailures() async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let cases: [(StubResponse, (ReleaseAttestationVerifier.VerificationError) -> Bool)] = [
            (.status(404), { if case .noAttestations = $0 { true } else { false } }),
            (.status(500), { if case .lookupFailed(500) = $0 { true } else { false } }),
            (StubResponse(200, Data("not json".utf8)), { if case .invalidResponse = $0 { true } else { false } }),
            (.ok(#"{"attestations":[{"bundle_url":"https://x"}]}"#), { if case .noAttestations = $0 { true } else { false } }),
        ]
        for (response, matches) in cases {
            let router = StubRouter().on("GET", "/attestations/", response)
            do {
                _ = try await HTTPStub.withSession(router) { session in
                    try await verifier(gh: gh.path, session: session)
                        .verify(artifact: artifact, sha256: AttestationFixtures.digest, workDirectory: gh.dir)
                }
                Issue.record("expected an error for HTTP \(response.status)")
            } catch let error as ReleaseAttestationVerifier.VerificationError {
                #expect(matches(error), "unexpected \(error)")
                #expect(error.errorDescription?.isEmpty == false)
            }
        }
        #expect(recordedArgs(gh.dir).isEmpty)
    }

    @Test("Local bundles are verified without calling the attestations API")
    func verifiesLocalBundles() async throws {
        let router = StubRouter()
        let outcome = try await HTTPStub.withSession(router) { session in
            try await verifier(gh: nil, session: session)
                .verify(artifact: artifact, sha256: AttestationFixtures.digest, workDirectory: FileManager.default.temporaryDirectory,
                        bundles: [try AttestationFixtures.data("provenance.sigstore")])
        }
        #expect(outcome == .verified(gh: .unavailable))
        #expect(router.log.requests.isEmpty)
    }

    @Test("An explicit signer workflow and predicate type equal to the defaults verify, and reach gh")
    func explicitPolicy() async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let verifier = ReleaseAttestationVerifier(
            signerWorkflow: "appibara-ltd/appitool/.github/workflows/release.yml",
            predicateType: "https://slsa.dev/provenance/v1",
            ghPath: gh.path, loadTrustedRoot: AttestationFixtures.loader
        )
        let outcome = try await verifier.verify(artifact: artifact, sha256: AttestationFixtures.digest, workDirectory: gh.dir,
                                                bundles: [try AttestationFixtures.data("provenance.sigstore")])
        #expect(outcome == .verified(gh: .agreed))
        let args = recordedArgs(gh.dir)
        #expect(args[try #require(args.firstIndex(of: "--predicate-type")) + 1] == "https://slsa.dev/provenance/v1")
    }

    /// The fixture provenance was signed by appibara-ltd/appitool's release.yml.
    @Test("Another signer workflow or predicate type rejects the attestation", arguments: [
        ("other workflow", "appibara-ltd/appitool/.github/workflows/tests.yml", ReleaseAttestationVerifier.slsaProvenanceV1),
        ("workflow in another repo", "appibara-ltd/other/.github/workflows/release.yml", ReleaseAttestationVerifier.slsaProvenanceV1),
        ("workflow name prefix", "appibara-ltd/appitool/.github/workflows/release.y", ReleaseAttestationVerifier.slsaProvenanceV1),
        ("release predicate", "appibara-ltd/appitool/.github/workflows/release.yml", "https://in-toto.io/attestation/release/v0.2"),
    ])
    func policyRejects(_ name: String, _ workflow: String, _ predicateType: String) async throws {
        let verifier = ReleaseAttestationVerifier(signerWorkflow: workflow, predicateType: predicateType,
                                                  ghPath: nil, loadTrustedRoot: AttestationFixtures.loader)
        do {
            _ = try await verifier.verify(artifact: artifact, sha256: AttestationFixtures.digest,
                                          workDirectory: FileManager.default.temporaryDirectory,
                                          bundles: [try AttestationFixtures.data("provenance.sigstore")])
            Issue.record("\(name): expected sigstoreRejected")
        } catch ReleaseAttestationVerifier.VerificationError.sigstoreRejected(let reasons) {
            #expect(!reasons.isEmpty, "\(name)")
        }
    }

    @Test("Repositories and signer workflows are validated and normalized")
    func validatesPolicyInputs() {
        for valid in ["appibara-ltd/appitool", "o/r", "my.org/my_repo-2"] {
            #expect(ReleaseAttestationVerifier.isValidRepo(valid), "\(valid)")
        }
        for invalid in ["", "appitool", "a/b/c", "/r", "o/", "o/..", "o/r?x=1", "o/r#x", "o/r%2f", "ö/r", "o r/x"] {
            #expect(!ReleaseAttestationVerifier.isValidRepo(invalid), "\(invalid)")
        }

        let expected = "appibara-ltd/appitool/.github/workflows/release.yml"
        for form in [expected, "github.com/\(expected)", "https://github.com/\(expected)", "https://github.com/\(expected)@refs/tags/v1.0.0"] {
            #expect(ReleaseAttestationVerifier.normalizeSignerWorkflow(form) == expected, "\(form)")
        }
        #expect(ReleaseAttestationVerifier.normalizeSignerWorkflow("o/r/.github/workflows/ci.yaml") == "o/r/.github/workflows/ci.yaml")
        for invalid in ["appibara-ltd/appitool", "o/r/.github/workflows/", "o/r/.github/workflows/.yml", "o/r/.github/workflows/sub/x.yml",
                        "o/r/workflows/x.yml", "o/r/.github/workflows/x.sh", "https://gitlab.com/o/r/.github/workflows/x.yml", "o/../.github/workflows/x.yml"] {
            #expect(ReleaseAttestationVerifier.normalizeSignerWorkflow(invalid) == nil, "\(invalid)")
        }
        #expect(ReleaseAttestationVerifier(repo: "o/r", ghPath: nil).signerWorkflow == "o/r/.github/workflows/release.yml")
    }

    @Test("Bundle files are read as one JSON document or as JSON Lines")
    func readsBundleFiles() throws {
        let dir = try TestFiles.makeTempDir("appitool-bundles")
        defer { try? FileManager.default.removeItem(at: dir) }
        let provenance = try AttestationFixtures.data("provenance.sigstore")
        let release = try AttestationFixtures.data("release.sigstore")

        let single = dir.appendingPathComponent("single.json")
        try provenance.write(to: single)  // pretty-printed, spans many lines
        #expect(try ReleaseAttestationVerifier.bundles(fromFile: single) == [provenance])

        let compact = try [provenance, release].map {
            try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: $0))
        }
        let lines = dir.appendingPathComponent("bundles.jsonl")
        try (ReleaseAttestationVerifier.jsonLines(compact) + Data("\n".utf8)).write(to: lines)
        #expect(try ReleaseAttestationVerifier.bundles(fromFile: lines) == compact)

        let empty = dir.appendingPathComponent("empty.jsonl")
        try Data(" \n\n".utf8).write(to: empty)
        #expect(throws: ReleaseAttestationVerifier.VerificationError.self) {
            try ReleaseAttestationVerifier.bundles(fromFile: empty)
        }
    }

    @Test("The embedded GitHub TUF root is gh's self-signed root v3")
    func embeddedGitHubRoot() throws {
        let trusted = try TrustedMetadata(rootData: GitHubTUFRoot.data)
        #expect(trusted.root.signed.version == 3)
        #expect(GitHubTUFRoot.repositoryURL == "https://tuf-repo.github.com")
    }

    @Test("locateGH finds gh on PATH")
    func locatesOnPath() throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        #expect(ReleaseAttestationVerifier.locateGH(environment: ["PATH": "/nonexistent:\(gh.dir.path)"]) == gh.path)
    }
}

@Suite("SelfUpdate Build Provenance", .serialized)
struct SelfUpdateProvenanceTests {
    private var tarballName: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        #if os(macOS)
        return "appitool-darwin-\(arch).tar.gz"
        #else
        return "appitool-linux-\(arch).tar.gz"
        #endif
    }

    /// A release whose tarball ("tarball") passes the checksum, so the update reaches the provenance
    /// check. The fixture attestation is for a different digest, so sigstore-swift rejects it.
    private func router(attestations: StubResponse) -> StubRouter {
        let assets = [tarballName, "checksums.txt"].map {
            #"{"name":"\#($0)","url":"https://downloads.test/api/\#($0)","browser_download_url":"https://downloads.test/dl/\#($0)"}"#
        }
        let release = #"{"tag_name":"v999.0.0","name":"r","body":"b","assets":[\#(assets.joined(separator: ","))]}"#
        let sha = "db4b4d0d1cb480bf9aeea253771c00febe627f236765fa37d6a5614f079a3aa0"
        return StubRouter()
            .on("GET", "/attestations/", attestations)
            .on("GET", "releases/latest", .ok(release))
            .on("GET", "checksums.txt", StubResponse(200, Data("\(sha)  \(tarballName)\n".utf8), headers: [:]))
            .on("GET", tarballName, StubResponse(200, Data("tarball".utf8), headers: [:]))
    }

    private func run(_ router: StubRouter, gh: String?, _ args: [String] = []) async throws {
        let savedGH = SelfUpdateCommand.locateGH
        let savedLoader = ReleaseAttestationVerifier.defaultTrustedRootLoader
        SelfUpdateCommand.locateGH = { gh }
        ReleaseAttestationVerifier.defaultTrustedRootLoader = AttestationFixtures.loader
        defer {
            SelfUpdateCommand.locateGH = savedGH
            ReleaseAttestationVerifier.defaultTrustedRootLoader = savedLoader
        }
        let cmd: SelfUpdateCommand = try CmdStub.parse(["self-update"] + args)
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    @Test("A failed provenance check aborts the update before unpacking, with or without gh")
    func failedCheckAborts() async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let attestations = try AttestationFixtures.apiResponse(["provenance.sigstore"])
        await #expect(throws: CommandError.self) { try await run(router(attestations: attestations), gh: gh.path) }
        await #expect(throws: CommandError.self) { try await run(router(attestations: attestations), gh: nil) }
        await #expect(throws: CommandError.self) { try await run(router(attestations: .status(404)), gh: nil) }
        #expect(recordedArgs(gh.dir).isEmpty)  // sigstore-swift rejected first
    }

    @Test("--skip-attestation continues to unpacking without fetching attestations")
    func skipContinuesToUnpack() async throws {
        // The fake tarball is not a real archive, so reaching `tar` fails with a ValidationError (never a CommandError).
        let skipped = router(attestations: .status(500))
        await #expect(throws: ValidationError.self) { try await run(skipped, gh: nil, ["--skip-attestation"]) }
        #expect(!skipped.log.requests.contains { $0.url.path.contains("/attestations/") })
    }
}

/// The fixture attestations are for the real v0.11.0 archive, which is not checked in, so every local
/// file here has a different digest and must be rejected. The accepting path is covered by
/// `ReleaseAttestationVerifierTests`.
@Suite("Verify Command", .serialized)
struct VerifyCommandTests {
    private func run(_ router: StubRouter, gh: String?, _ args: [String]) async throws {
        let savedGH = VerifyCommand.locateGH
        let savedLoader = ReleaseAttestationVerifier.defaultTrustedRootLoader
        VerifyCommand.locateGH = { gh }
        ReleaseAttestationVerifier.defaultTrustedRootLoader = AttestationFixtures.loader
        defer {
            VerifyCommand.locateGH = savedGH
            ReleaseAttestationVerifier.defaultTrustedRootLoader = savedLoader
        }
        let cmd: VerifyCommand = try CmdStub.parse(["verify"] + args)
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    private func makeArchive() throws -> (dir: URL, path: String) {
        let dir = try TestFiles.makeTempDir("appitool-verify")
        let path = dir.appendingPathComponent("appitool-darwin-arm64.tar.gz").path
        try Data("not the release archive".utf8).write(to: URL(fileURLWithPath: path))
        return (dir, path)
    }

    @Test("Parses -f/--file, --bundle, and --skip-gh")
    func parsesOptions() throws {
        let cmd: VerifyCommand = try CmdStub.parse(["verify", "-f", "a.tar.gz", "--bundle", "b.jsonl", "--skip-gh"])
        #expect(cmd.file == "a.tar.gz")
        #expect(cmd.bundle == "b.jsonl")
        #expect(cmd.skipGh)
        let long: VerifyCommand = try CmdStub.parse(["verify", "--file", "a.tar.gz"])
        #expect(long.bundle == nil)
        #expect(!long.skipGh)
        #expect(throws: (any Error).self) { try CmdStub.parse(["verify"], as: VerifyCommand.self) }
        #expect(long.repo == "appibara-ltd/appitool")
        #expect(long.signerWorkflow == nil)
        #expect(long.predicateType == "https://slsa.dev/provenance/v1")
    }

    @Test("Rejects malformed --repo, --signer-workflow, and --predicate-type values")
    func rejectsBadPolicyOptions() {
        for args in [["--repo", "appitool"], ["--repo", "o/r/../x"], ["--signer-workflow", "o/r"], ["--predicate-type", " "]] {
            #expect(throws: (any Error).self, "\(args)") { try CmdStub.parse(["verify", "-f", "a.tar.gz"] + args, as: VerifyCommand.self) }
        }
        let cmd: VerifyCommand = try! CmdStub.parse([
            "verify", "-f", "a.tar.gz", "--repo", "o/r",
            "--signer-workflow", "https://github.com/o/r/.github/workflows/build.yml@refs/heads/main",
            "--predicate-type", "https://example.com/predicate/v1",
        ])
        #expect(cmd.repo == "o/r")
        #expect(cmd.predicateType == "https://example.com/predicate/v1")
    }

    @Test("--repo fetches attestations from that repository and enforces its signer")
    func otherRepository() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.dir) }
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(["provenance.sigstore"]))

        await #expect(throws: CommandError.self) { try await run(router, gh: nil, ["-f", archive.path, "--repo", "octo-org/octo-repo"]) }

        let request = try #require(router.log.requests.first)
        #expect(request.url.absoluteString.hasPrefix("https://api.github.com/repos/octo-org/octo-repo/attestations/sha256:"))
    }

    @Test("A missing file fails before any network access")
    func missingFile() async throws {
        let router = StubRouter()
        await #expect(throws: CommandError.self) { try await run(router, gh: nil, ["-f", "/nonexistent/appitool.tar.gz"]) }
        #expect(router.log.requests.isEmpty)
    }

    @Test("Fetches the file's attestations by its SHA256 and rejects a digest mismatch before gh runs")
    func fetchesAndRejects() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.dir) }
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let router = StubRouter().on("GET", "/attestations/", try AttestationFixtures.apiResponse(["provenance.sigstore"]))

        await #expect(throws: CommandError.self) { try await run(router, gh: gh.path, ["-f", archive.path]) }

        let digest = SHA256Hex.of(Data("not the release archive".utf8))
        let request = try #require(router.log.requests.first)
        #expect(request.url.absoluteString.hasSuffix("/attestations/sha256:\(digest)"))
        #expect(recordedArgs(gh.dir).isEmpty)
    }

    @Test("--bundle verifies a local bundle file without calling the attestations API")
    func localBundle() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.dir) }
        let bundleURL = try #require(Foundation.Bundle.module.url(forResource: "provenance.sigstore", withExtension: "json", subdirectory: "Fixtures"))
        let router = StubRouter()

        await #expect(throws: CommandError.self) {
            try await run(router, gh: nil, ["-f", archive.path, "--bundle", bundleURL.path, "--skip-gh"])
        }
        #expect(router.log.requests.isEmpty)
    }

    @Test("Unreadable or empty bundle files fail")
    func badBundleFiles() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.dir) }
        let empty = archive.dir.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        for bundle in [empty.path, "/nonexistent/bundle.jsonl"] {
            await #expect(throws: CommandError.self) { try await run(StubRouter(), gh: nil, ["-f", archive.path, "--bundle", bundle]) }
        }
    }
}

private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
