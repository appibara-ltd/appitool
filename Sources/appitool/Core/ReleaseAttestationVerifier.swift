import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Sigstore

/// Verifies a release archive's GitHub build provenance attestation.
///
/// The Sigstore bundles are fetched from the public attestations API
/// (`GET /repos/{repo}/attestations/sha256:{digest}`), so no `gh auth login` is needed.
///
/// 1. **sigstore-swift** (always): a bundle must verify against Sigstore's trusted root (public-good,
///    or GitHub's instance) fetched over TUF, carry an SLSA v1 provenance statement for the archive's
///    digest, and be signed by the release workflow of `repo` (Fulcio certificate identity). A
///    rejection aborts the update.
/// 2. **`gh` cross-check** (when installed): `gh attestation verify` must agree. If sigstore-swift
///    accepts but `gh` rejects, the update is aborted as a disagreement.
struct ReleaseAttestationVerifier: Sendable {
    /// Whether `gh` confirmed sigstore-swift's verdict.
    enum GHCrossCheck: Equatable, Sendable {
        case agreed
        case unavailable
    }

    enum Outcome: Equatable, Sendable {
        case verified(gh: GHCrossCheck)
    }

    /// A Sigstore instance whose trusted root bundles may chain to.
    enum SigstoreInstance: String, CaseIterable, Sendable {
        case publicGood = "public-good"
        case github = "GitHub"
    }

    typealias TrustedRootLoader = @Sendable (SigstoreInstance) async throws -> TrustedRoot

    /// Loads trusted roots when no loader is passed to `init`. Tests replace it with fixture roots.
    nonisolated(unsafe) static var defaultTrustedRootLoader: TrustedRootLoader = { try await fetchTrustedRootOverTUF($0) }

    enum VerificationError: LocalizedError, Sendable {
        case noAttestations(digest: String)
        case lookupFailed(statusCode: Int)
        case invalidResponse
        case sigstoreRejected(reasons: [String])
        case ghDisagreed(output: String)
        case emptyBundleFile(path: String)

        var errorDescription: String? {
            switch self {
            case .emptyBundleFile(let path):
                return "No Sigstore bundle found in '\(path)'."
            case .noAttestations(let digest):
                return "No build provenance attestation found for sha256:\(digest)."
            case .lookupFailed(let statusCode):
                return "Failed to fetch build provenance attestations (HTTP \(statusCode))."
            case .invalidResponse:
                return "Unexpected response from the GitHub attestations API."
            case .sigstoreRejected(let reasons):
                return "Build provenance verification failed: no attestation verified (\(reasons.joined(separator: "; ")))."
            case .ghDisagreed(let output):
                return "Build provenance verified with sigstore-swift, but 'gh attestation verify' rejected it: \(output)"
            }
        }
    }

    static let defaultRepo = "appibara-ltd/appitool"
    static let slsaProvenanceV1 = "https://slsa.dev/provenance/v1"
    static let githubActionsIssuer = "https://token.actions.githubusercontent.com"

    /// The release workflow of `repo`, the default signer.
    static func defaultSignerWorkflow(repo: String) -> String { "\(repo)/.github/workflows/release.yml" }

    /// The repository (`owner/name`) the attestation's source repository must be. Attestations are
    /// fetched from this repository's attestations API.
    let repo: String
    /// The workflow (`owner/repo/path/to/workflow.yml`) that must have signed the attestation.
    let signerWorkflow: String
    /// The in-toto predicate type the attestation's statement must have.
    let predicateType: String
    /// Absolute path to `gh`, or `nil` when it is not installed.
    let ghPath: String?
    let token: String?
    let urlSession: URLSession
    let loadTrustedRoot: TrustedRootLoader

    init(
        repo: String = Self.defaultRepo,
        signerWorkflow: String? = nil,
        predicateType: String = Self.slsaProvenanceV1,
        ghPath: String?,
        token: String? = nil,
        urlSession: URLSession = HTTPDefaults.urlSession,
        loadTrustedRoot: TrustedRootLoader? = nil
    ) {
        self.repo = repo
        self.signerWorkflow = signerWorkflow ?? Self.defaultSignerWorkflow(repo: repo)
        self.predicateType = predicateType
        self.ghPath = ghPath
        self.token = token
        self.urlSession = urlSession
        self.loadTrustedRoot = loadTrustedRoot ?? Self.defaultTrustedRootLoader
    }

    /// Whether `repo` is an `owner/name` repository (GitHub's allowed characters), safe to put in an
    /// API URL path.
    static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    /// Normalizes a signer workflow given as `owner/repo/path`, `github.com/owner/repo/path`, or
    /// `https://github.com/owner/repo/path` (optionally with `@ref`) to `owner/repo/path`. Returns
    /// `nil` unless it names a workflow file in `.github/workflows/` (GitHub does not run workflows
    /// from subdirectories) of a valid repository.
    static func normalizeSignerWorkflow(_ value: String) -> String? {
        var workflow = value
        for prefix in ["https://", "github.com/"] where workflow.hasPrefix(prefix) {
            workflow.removeFirst(prefix.count)
        }
        if let at = workflow.firstIndex(of: "@") {
            workflow = String(workflow[..<at])
        }
        let parts = workflow.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5,
              isValidRepo("\(parts[0])/\(parts[1])"),
              parts[2] == ".github", parts[3] == "workflows",
              parts[4].hasSuffix(".yml") || parts[4].hasSuffix(".yaml"),
              parts[4] != ".yml", parts[4] != ".yaml" else {
            return nil
        }
        return workflow
    }

    /// Verifies `artifact` (whose SHA256 is `sha256`). Throws when no attestation verifies with
    /// sigstore-swift, or when `gh` (if installed) disagrees.
    ///
    /// `bundles` (Sigstore bundle JSON documents) are verified instead of fetching the artifact's
    /// attestations from the GitHub API when given.
    func verify(artifact: URL, sha256: String, workDirectory: URL, bundles localBundles: [Data]? = nil) async throws -> Outcome {
        let digest = sha256.lowercased()
        let bundles: [Data]
        if let localBundles {
            bundles = localBundles
        } else {
            bundles = try await fetchBundles(digest: digest)
        }

        try await verifyWithSigstore(bundles: bundles, digest: digest)

        guard let ghPath else {
            return .verified(gh: .unavailable)
        }
        let bundlePath = workDirectory.appendingPathComponent("attestations-\(digest.prefix(12)).jsonl")
        try Self.jsonLines(bundles).write(to: bundlePath)
        let result = try await ProcessRunner.run(
            ghPath,
            arguments: [
                "attestation", "verify", artifact.path,
                "--bundle", bundlePath.path,
                "--repo", repo,
                "--signer-workflow", signerWorkflow,
                "--predicate-type", predicateType,
            ],
            combineOutput: true
        )
        guard result.isSuccess else {
            throw VerificationError.ghDisagreed(output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .verified(gh: .agreed)
    }

    // MARK: - sigstore-swift

    /// The certificate identity `gh attestation verify --repo <repo> --signer-workflow <workflow>`
    /// requires: GitHub Actions OIDC issuer, a SAN in the release workflow, and the repository
    /// (and owner) URIs recorded in the Fulcio certificate.
    func certificateIdentity() throws -> CertificateIdentity {
        let owner = repo.split(separator: "/").first.map(String.init) ?? repo
        var extensions = Extensions()
        extensions.sourceRepositoryURI = "https://github.com/\(repo)"
        extensions.sourceRepositoryOwnerURI = "https://github.com/\(owner)"
        let escapedWorkflow = NSRegularExpression.escapedPattern(for: "https://github.com/\(signerWorkflow)@")
        return try CertificateIdentity(
            subjectAlternativeName: SubjectAlternativeNameMatcher("", regexp: "^\(escapedWorkflow)"),
            issuer: IssuerMatcher(Self.githubActionsIssuer),
            extensions: extensions
        )
    }

    /// Succeeds when at least one bundle verifies, trying the public-good trusted root first (public
    /// repositories) and GitHub's (private repositories) only if needed.
    func verifyWithSigstore(bundles: [Data], digest: String) async throws {
        guard let digestBytes = Hex.decode(digest), digestBytes.count == 32 else {
            throw VerificationError.sigstoreRejected(reasons: ["invalid sha256 digest"])
        }
        let policy = PolicyBuilder(
            .withArtifactDigest(algorithm: "sha256", digest: Data(digestBytes)),
            .withCertificateIdentity(try certificateIdentity())
        )
        let parsed = bundles.compactMap { try? SigstoreBundle.Bundle(json: $0) }
        var reasons: [String] = []
        if parsed.count < bundles.count {
            reasons.append("\(bundles.count - parsed.count) bundle(s) could not be parsed")
        }

        for instance in SigstoreInstance.allCases {
            let root: TrustedRoot
            do {
                root = try await loadTrustedRoot(instance)
            } catch {
                reasons.append("\(instance.rawValue) trusted root unavailable: \(error)")
                continue
            }
            // The configurations `gh attestation verify` uses for each instance.
            let options: [VerifierOption] = switch instance {
            case .publicGood:
                [.withSignedCertificateTimestamps(threshold: 1), .withTransparencyLog(threshold: 1), .withObserverTimestamps(threshold: 1)]
            case .github:
                [.withSignedTimestamps(threshold: 1)]
            }
            let verifier = try SigstoreVerify.Verifier(trustedMaterial: root, options: options)
            for bundle in parsed {
                do {
                    let result = try await verifier.verify(bundle, policy: policy)
                    if result.statement?.predicateType == predicateType {
                        return
                    }
                    reasons.append("\(instance.rawValue): predicate type \(result.statement?.predicateType ?? "none") is not \(predicateType)")
                } catch {
                    reasons.append("\(instance.rawValue): \(error)")
                }
            }
        }
        throw VerificationError.sigstoreRejected(reasons: reasons)
    }

    /// Fetches the instance's `trusted_root.json` over TUF, caching metadata in `~/.sigstore/root`
    /// for a day (like `gh`). GitHub's repository is trusted from `GitHubTUFRoot`.
    static func fetchTrustedRootOverTUF(_ instance: SigstoreInstance) async throws -> TrustedRoot {
        var options = SigstoreTUF.Options().withCacheValidity(1)
        if instance == .github {
            options = options.withRoot(GitHubTUFRoot.data).withRepositoryBaseURL(GitHubTUFRoot.repositoryURL)
        }
        return try await fetchTrustedRootWithOptions(options)
    }

    // MARK: - Attestations API

    /// Returns the attestation bundles for `digest`, one Sigstore bundle JSON per element.
    func fetchBundles(digest: String) async throws -> [Data] {
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
        let bundles = try attestations.compactMap { $0["bundle"] as? [String: Any] }
            .map { try JSONSerialization.data(withJSONObject: $0) }
        guard !bundles.isEmpty else {
            throw VerificationError.noAttestations(digest: digest)
        }
        return bundles
    }

    /// Reads a bundle file in either format `gh attestation verify --bundle` accepts: one Sigstore
    /// bundle JSON document, or JSON Lines (one bundle per line).
    static func bundles(fromFile url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return [data]
        }
        let lines = data.split(separator: UInt8(ascii: "\n"))
            .map { Data($0) }
            .filter { !String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else {
            throw VerificationError.emptyBundleFile(path: url.path)
        }
        return lines
    }

    /// JSON Lines (one bundle per line) for `gh attestation verify --bundle`.
    static func jsonLines(_ bundles: [Data]) -> Data {
        Data(bundles.joined(separator: Data("\n".utf8))) + Data("\n".utf8)
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
