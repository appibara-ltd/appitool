import ArgumentParser
import Crypto
import Foundation
import Rainbow

/// Verifies a file's GitHub artifact attestation with sigstore-swift, using the checks `self-update`
/// runs before installing (`ReleaseAttestationVerifier`) but without its `gh` cross-check. `--repo`,
/// `--signer-workflow`, and `--predicate-type` default to appitool's release attestations.
struct VerifyCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a file's GitHub artifact attestation with sigstore-swift (repository, workflow, and predicate type default to appitool's releases)."
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
            ghPath: nil,
            token: githubToken
        )
        Log("🔄 Verifying \(artifact.lastPathComponent) (sha256:\(sha256))")
        let source = bundle.map { " (bundle: \($0))" } ?? ""
        Log("   Checking the \(verifier.predicateType) attestation from \(verifier.repo) with sigstore-swift\(source)...")

        do {
            // Without gh, `verify` never writes to the work directory.
            _ = try await verifier.verify(artifact: artifact, sha256: sha256, workDirectory: FileManager.default.temporaryDirectory, bundles: bundles)
        } catch {
            throw CommandError(error.localizedDescription)
        }
        Log("🟢 Attestation verified (signed by \(verifier.signerWorkflow)).".green)
    }

    private var githubToken: String? {
        EnvLoader.value(for: "GITHUB_TOKEN") ?? EnvLoader.value(for: "GH_TOKEN")
    }
}
