import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

private let bundleJSON = #"{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","verificationMaterial":{},"dsseEnvelope":{"payload":"e30=","payloadType":"application/vnd.in-toto+json","signatures":[]}}"#
private let twoAttestations = #"{"attestations":[{"bundle":\#(bundleJSON),"repository_id":1},{"bundle":\#(bundleJSON),"repository_id":1}]}"#

@Suite("ReleaseAttestationVerifier", .serialized)
struct ReleaseAttestationVerifierTests {
    private let digest = "DB4B4D0D1CB480BF9AEEA253771C00FEBE627F236765FA37D6A5614F079A3AA0"

    @Test("Skips without gh and makes no requests")
    func skipsWithoutGH() async throws {
        let router = StubRouter()
        let outcome = try await HTTPStub.withSession(router) { session in
            try await ReleaseAttestationVerifier(ghPath: nil, urlSession: session)
                .verify(artifact: URL(fileURLWithPath: "/nonexistent"), sha256: digest, workDirectory: FileManager.default.temporaryDirectory)
        }
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(router.log.requests.isEmpty)
    }

    @Test("Fetches bundles from the public API and runs gh attestation verify with the signer workflow")
    func verifiesWithGH() async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let artifact = gh.dir.appendingPathComponent("appitool.tar.gz")
        try Data("tarball".utf8).write(to: artifact)
        let router = StubRouter().on("GET", "/attestations/", .ok(twoAttestations))

        let outcome = try await HTTPStub.withSession(router) { session in
            try await ReleaseAttestationVerifier(ghPath: gh.path, token: "tok", urlSession: session)
                .verify(artifact: artifact, sha256: digest, workDirectory: gh.dir)
        }

        #expect(outcome == .verified)
        let request = try #require(router.log.requests.first)
        #expect(request.url.absoluteString == "https://api.github.com/repos/appibara-ltd/appitool/attestations/sha256:\(digest.lowercased())")
        #expect(request.headers["Authorization"] == "Bearer tok")

        let args = recordedArgs(gh.dir)
        #expect(Array(args.prefix(3)) == ["attestation", "verify", artifact.path])
        let bundleIndex = try #require(args.firstIndex(of: "--bundle"))
        let bundlePath = args[bundleIndex + 1]
        #expect(bundlePath.hasSuffix(".jsonl"))
        #expect(args.contains("--repo") && args[args.firstIndex(of: "--repo")! + 1] == "appibara-ltd/appitool")
        #expect(args[args.firstIndex(of: "--signer-workflow")! + 1] == "appibara-ltd/appitool/.github/workflows/release.yml")

        // One bundle per line, each a standalone JSON object.
        let lines = try String(contentsOfFile: bundlePath, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["mediaType"] as? String == "application/vnd.dev.sigstore.bundle.v0.3+json")
        }
    }

    @Test("A failing gh verification throws with gh's output")
    func ghFailureThrows() async throws {
        let gh = try makeFakeGH(exitCode: 1)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        let router = StubRouter().on("GET", "/attestations/", .ok(twoAttestations))
        do {
            _ = try await HTTPStub.withSession(router) { session in
                try await ReleaseAttestationVerifier(ghPath: gh.path, urlSession: session)
                    .verify(artifact: gh.dir.appendingPathComponent("a.tar.gz"), sha256: digest, workDirectory: gh.dir)
            }
            Issue.record("expected verificationFailed")
        } catch ReleaseAttestationVerifier.VerificationError.verificationFailed(let output) {
            #expect(output.contains("fake gh output"))
        }
    }

    @Test("Missing, failed, malformed, and bundle-less API responses throw before running gh")
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
                    try await ReleaseAttestationVerifier(ghPath: gh.path, urlSession: session)
                        .verify(artifact: gh.dir.appendingPathComponent("a.tar.gz"), sha256: digest, workDirectory: gh.dir)
                }
                Issue.record("expected an error for HTTP \(response.status)")
            } catch let error as ReleaseAttestationVerifier.VerificationError {
                #expect(matches(error), "unexpected \(error)")
                #expect(error.errorDescription?.isEmpty == false)
            }
        }
        #expect(recordedArgs(gh.dir).isEmpty)
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

    /// A release whose tarball ("tarball") passes the checksum, so the update reaches the provenance check.
    private func router(attestations: StubResponse = .ok(twoAttestations)) -> StubRouter {
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
        let saved = SelfUpdateCommand.locateGH
        SelfUpdateCommand.locateGH = { gh }
        defer { SelfUpdateCommand.locateGH = saved }
        let cmd: SelfUpdateCommand = try CmdStub.parse(["self-update"] + args)
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    @Test("A failed attestation check aborts the update before unpacking")
    func failedCheckAborts() async throws {
        let gh = try makeFakeGH(exitCode: 1)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        await #expect(throws: CommandError.self) { try await run(router(), gh: gh.path) }
        await #expect(throws: CommandError.self) { try await run(router(attestations: .status(404)), gh: gh.path) }
    }

    @Test("Passing, skipped (no gh), and --skip-attestation checks continue to unpacking")
    func continuesToUnpack() async throws {
        let gh = try makeFakeGH(exitCode: 0)
        defer { try? FileManager.default.removeItem(at: gh.dir) }
        // The fake tarball is not a real archive, so reaching `tar` fails with a ValidationError (never a CommandError).
        await #expect(throws: ValidationError.self) { try await run(router(), gh: gh.path) }
        await #expect(throws: ValidationError.self) { try await run(router(), gh: nil) }

        let skipped = router(attestations: .status(500))
        await #expect(throws: ValidationError.self) { try await run(skipped, gh: gh.path, ["--skip-attestation"]) }
        #expect(!skipped.log.requests.contains { $0.url.path.contains("/attestations/") })
    }
}
