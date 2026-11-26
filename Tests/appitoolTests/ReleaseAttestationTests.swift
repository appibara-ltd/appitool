import ArgumentParser
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
