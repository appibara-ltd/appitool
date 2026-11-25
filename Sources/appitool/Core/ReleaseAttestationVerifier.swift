import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Verifies a release archive's GitHub build provenance attestation using the `gh` CLI, when it is installed.
///
/// The Sigstore bundles are fetched from the public attestations API
/// (`GET /repos/{repo}/attestations/sha256:{digest}`) and passed to `gh attestation verify --bundle`,
/// so verification works without a `gh auth login`. The cryptographic checks (signature, Fulcio
/// certificate chain, transparency log, signer workflow identity) are performed by `gh` (sigstore-go).
struct ReleaseAttestationVerifier: Sendable {
    enum Outcome: Equatable, Sendable {
        case verified
        case skipped(reason: String)
    }

    enum VerificationError: LocalizedError, Sendable {
        case noAttestations(digest: String)
        case lookupFailed(statusCode: Int)
        case invalidResponse
        case verificationFailed(output: String)

        var errorDescription: String? {
            switch self {
            case .noAttestations(let digest):
                return "No build provenance attestation found for sha256:\(digest)."
            case .lookupFailed(let statusCode):
                return "Failed to fetch build provenance attestations (HTTP \(statusCode))."
            case .invalidResponse:
                return "Unexpected response from the GitHub attestations API."
            case .verificationFailed(let output):
                return "Build provenance verification failed: \(output)"
            }
        }
    }

    static let defaultRepo = "appibara-ltd/appitool"

    /// The workflow that must have signed the attestation.
    var signerWorkflow: String { "\(repo)/.github/workflows/release.yml" }

    let repo: String
    /// Absolute path to `gh`, or `nil` when it is not installed.
    let ghPath: String?
    let token: String?
    let urlSession: URLSession

    init(
        repo: String = Self.defaultRepo,
        ghPath: String?,
        token: String? = nil,
        urlSession: URLSession = HTTPDefaults.urlSession
    ) {
        self.repo = repo
        self.ghPath = ghPath
        self.token = token
        self.urlSession = urlSession
    }

    /// Verifies `artifact` (whose SHA256 is `sha256`). Throws when an attestation is missing or invalid;
    /// returns `.skipped` only when `gh` is unavailable.
    func verify(artifact: URL, sha256: String, workDirectory: URL) async throws -> Outcome {
        guard let ghPath else {
            return .skipped(reason: "install the GitHub CLI 'gh' to enable it")
        }

        let digest = sha256.lowercased()
        let bundles = try await fetchBundles(digest: digest)
        let bundlePath = workDirectory.appendingPathComponent("attestations-\(digest.prefix(12)).jsonl")
        try bundles.write(to: bundlePath)

        let result = try await ProcessRunner.run(
            ghPath,
            arguments: [
                "attestation", "verify", artifact.path,
                "--bundle", bundlePath.path,
                "--repo", repo,
                "--signer-workflow", signerWorkflow,
            ],
            combineOutput: true
        )
        guard result.isSuccess else {
            throw VerificationError.verificationFailed(output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .verified
    }

    /// Returns the attestation bundles for `digest` as JSON Lines (one Sigstore bundle per line).
    func fetchBundles(digest: String) async throws -> Data {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/attestations/sha256:\(digest)") else {
            throw VerificationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("appitool-self-update", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode == 404 {
            throw VerificationError.noAttestations(digest: digest)
        }
        guard (200...299).contains(statusCode) else {
            throw VerificationError.lookupFailed(statusCode: statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attestations = root["attestations"] as? [[String: Any]] else {
            throw VerificationError.invalidResponse
        }
        let lines = try attestations.compactMap { $0["bundle"] as? [String: Any] }
            .map { try JSONSerialization.data(withJSONObject: $0) }
        guard !lines.isEmpty else {
            throw VerificationError.noAttestations(digest: digest)
        }
        return Data(lines.joined(separator: Data("\n".utf8))) + Data("\n".utf8)
    }

    /// Finds `gh` on `PATH`, falling back to the standard Homebrew / system directories.
    static func locateGH(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in candidates where !directory.isEmpty {
            let path = (directory as NSString).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
