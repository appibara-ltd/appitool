import ArgumentParser
import Crypto
import Foundation
import Rainbow

/// Verifies a file's GitHub artifact attestation with the checks `self-update` runs before installing
/// (`ReleaseAttestationVerifier`). By default the file must be an appitool release archive; `--repo`,
/// `--signer-workflow`, and `--predicate-type` select another repository, workflow, or statement.
struct VerifyCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a file's GitHub artifact attestation (sigstore-swift, cross-checked with 'gh' when installed); defaults to appitool release archives."
    )

    @Option(name: [.short, .long], help: "Path to the file to verify (e.g. appitool-darwin-arm64.tar.gz).")
    var file: String

    @Option(name: .long, help: "Sigstore bundle file (JSON or JSON Lines) to verify instead of fetching the file's attestations from GitHub.")
    var bundle: String?

    @Option(name: .long, help: "Repository (owner/name) the file must have been built from; attestations are fetched from it.")
    var repo: String = ReleaseAttestationVerifier.defaultRepo

    @Option(name: .long, help: "Workflow that must have signed the attestation (owner/repo/.github/workflows/<file>.yml). Defaults to <repo>/.github/workflows/release.yml.")
    var signerWorkflow: String?

    @Option(name: .long, help: "In-toto predicate type the attestation must have.")
    var predicateType: String = ReleaseAttestationVerifier.slsaProvenanceV1

    @Flag(name: .long, help: "Skip the 'gh attestation verify' cross-check.")
    var skipGh: Bool = false

    func validate() throws {
        guard ReleaseAttestationVerifier.isValidRepo(repo) else {
            throw ValidationError("--repo must be an owner/name repository, got '\(repo)'.")
        }
        if let signerWorkflow, ReleaseAttestationVerifier.normalizeSignerWorkflow(signerWorkflow) == nil {
            throw ValidationError("--signer-workflow must be owner/repo/.github/workflows/<file>.yml, got '\(signerWorkflow)'.")
        }
        guard !predicateType.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--predicate-type must not be empty.")
        }
    }

    /// Resolves the `gh` executable used for the cross-check. Tests replace it to inject a fake `gh`.
    nonisolated(unsafe) static var locateGH: @Sendable () -> String? = { ReleaseAttestationVerifier.locateGH() }

    func execute() async throws {
        let artifact = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: artifact.path) else {
            throw CommandError("File not found: '\(artifact.path)'.")
        }
        let sha256 = SHA256.hash(data: try Data(contentsOf: artifact)).map { String(format: "%02x", $0) }.joined()

        var bundles: [Data]?
        if let bundle {
            let bundleURL = URL(fileURLWithPath: (bundle as NSString).expandingTildeInPath)
            do {
                bundles = try ReleaseAttestationVerifier.bundles(fromFile: bundleURL)
            } catch let error as ReleaseAttestationVerifier.VerificationError {
                throw CommandError(error.localizedDescription)
            } catch {
                throw CommandError("Could not read bundle file '\(bundleURL.path)': \(error.localizedDescription)")
            }
        }

        let verifier = ReleaseAttestationVerifier(
            repo: repo,
            signerWorkflow: signerWorkflow.flatMap(ReleaseAttestationVerifier.normalizeSignerWorkflow),
            predicateType: predicateType,
            ghPath: skipGh ? nil : Self.locateGH(),
            token: githubToken
        )
        Log("🔄 Verifying \(artifact.lastPathComponent) (sha256:\(sha256))")
        let source = bundle.map { " (bundle: \($0))" } ?? ""
        Log("   Checking the \(verifier.predicateType) attestation from \(verifier.repo) with sigstore-swift\(verifier.ghPath != nil ? " and gh" : "")\(source)...")

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let outcome: ReleaseAttestationVerifier.Outcome
        do {
            outcome = try await verifier.verify(artifact: artifact, sha256: sha256, workDirectory: workDirectory, bundles: bundles)
        } catch {
            throw CommandError(error.localizedDescription)
        }
        switch outcome {
        case .verified(gh: .agreed):
            Log("🟢 Attestation verified (signed by \(verifier.signerWorkflow)); gh agrees.".green)
        case .verified(gh: .unavailable):
            Log("🟢 Attestation verified (signed by \(verifier.signerWorkflow)).".green)
            if skipGh {
                Log("🟡 gh cross-check skipped (--skip-gh).".yellow)
            } else {
                Log("🟡 gh not installed: cross-check skipped.".yellow)
            }
        }
    }

    private var githubToken: String? {
        EnvLoader.value(for: "GITHUB_TOKEN") ?? EnvLoader.value(for: "GH_TOKEN")
    }
}
