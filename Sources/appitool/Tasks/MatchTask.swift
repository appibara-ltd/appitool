import Foundation

/// A task that handles certificate and provisioning profile management compatible with Fastlane `match`,
/// supporting GitHub repository synchronization.
public struct MatchTask: Task {
    /// Supported provisioning profile and certificate types.
    public enum ProfileType: String, Sendable, CaseIterable {
        case development
        case adhoc
        case appstore
        case enterprise
    }

    /// Action mode for match operations.
    public enum Action: String, Sendable, CaseIterable {
        case sync
        case nuke
    }

    /// Configuration input for `MatchTask`.
    public struct Input: Sendable {
        /// Git URL of the certificates repository on GitHub (HTTPS or SSH format).
        public let gitUrl: String

        /// Git branch name (defaults to "master").
        public let gitBranch: String

        /// GitHub Personal Access Token or App Token for authenticated HTTPS git operations.
        public let gitToken: String?

        /// Provisioning profile distribution type.
        public let type: ProfileType

        /// List of bundle identifiers to sync profiles for.
        public let appIdentifiers: [String]

        /// Password used to decrypt and encrypt repository files (AES-256-CBC).
        public let password: String

        /// Action to perform: `.sync` or `.nuke`. Defaults to `.sync`.
        public let action: Action

        /// Whether to only fetch existing certificates/profiles without creating new ones on the Developer portal.
        public let readonly: Bool

        /// Apple Developer Team ID.
        public let teamId: String?

        /// Apple Developer Team Name.
        public let teamName: String?

        /// Optional custom keychain name to import certificates into.
        public let keychainName: String?

        /// Password for unlocking custom keychain.
        public let keychainPassword: String?

        /// Force renewal of provisioning profiles even if still valid.
        public let force: Bool

        public init(
            gitUrl: String,
            gitBranch: String = "master",
            gitToken: String? = nil,
            type: ProfileType = .appstore,
            appIdentifiers: [String],
            password: String,
            action: Action = .sync,
            readonly: Bool = true,
            teamId: String? = nil,
            teamName: String? = nil,
            keychainName: String? = nil,
            keychainPassword: String? = nil,
            force: Bool = false
        ) {
            self.gitUrl = gitUrl
            self.gitBranch = gitBranch
            self.gitToken = gitToken
            self.type = type
            self.appIdentifiers = appIdentifiers
            self.password = password
            self.action = action
            self.readonly = readonly
            self.teamId = teamId
            self.teamName = teamName
            self.keychainName = keychainName
            self.keychainPassword = keychainPassword
            self.force = force
        }
    }

    /// Information about a synchronized provisioning profile.
    public struct ProfileInfo: Sendable, Equatable {
        public let name: String
        public let uuid: String
        public let path: String
        public let bundleId: String

        public init(name: String, uuid: String, path: String, bundleId: String) {
            self.name = name
            self.uuid = uuid
            self.path = path
            self.bundleId = bundleId
        }
    }

    /// Result containing synchronized certificates and provisioning profiles.
    public struct Output: Sendable {
        /// Names or SHA-1 fingerprints of certificates installed into the keychain.
        public let installedCertificates: [String]

        /// Provisioning profiles installed, indexed by bundle identifier.
        public let installedProfiles: [String: ProfileInfo]

        public init(
            installedCertificates: [String] = [],
            installedProfiles: [String: ProfileInfo] = [:]
        ) {
            self.installedCertificates = installedCertificates
            self.installedProfiles = installedProfiles
        }
    }

    /// Errors thrown during `MatchTask` execution.
    public enum MatchError: LocalizedError, Sendable {
        case invalidGitHubUrl(String)
        case gitAuthenticationFailed(String)
        case gitCloneFailed(String)
        case decryptionFailed(String)
        case certificateNotFound(type: ProfileType)
        case profileNotFound(bundleId: String, type: ProfileType)
        case keychainError(String)
        case notImplemented

        public var errorDescription: String? {
            switch self {
            case .invalidGitHubUrl(let url):
                return "Invalid GitHub repository URL: \(url)"
            case .gitAuthenticationFailed(let message):
                return "GitHub authentication failed: \(message)"
            case .gitCloneFailed(let message):
                return "Failed to clone match repository: \(message)"
            case .decryptionFailed(let message):
                return "Failed to decrypt match repository with provided password: \(message)"
            case .certificateNotFound(let type):
                return "No valid certificate found in repository for type: \(type.rawValue)"
            case .profileNotFound(let bundleId, let type):
                return "No valid profile found for '\(bundleId)' of type: \(type.rawValue)"
            case .keychainError(let message):
                return "Keychain operation failed: \(message)"
            case .notImplemented:
                return "MatchTask execution logic is not yet implemented."
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        // Boilerplate placeholder
        return Output()
    }
}
