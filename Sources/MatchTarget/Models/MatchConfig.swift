import Foundation

/// Supported provisioning profile distribution and certificate types in Match.
public enum MatchProfileType: String, Sendable, CaseIterable {
    case development
    case adhoc
    case appstore
    case enterprise
    case developerId = "developer_id"

    /// Directory name under certs/
    public var certDirectoryName: String {
        switch self {
        case .development: return "development"
        case .adhoc, .appstore: return "distribution"
        case .enterprise: return "enterprise"
        case .developerId: return "developer_id"
        }
    }

    /// Directory name under profiles/
    public var profileDirectoryName: String {
        switch self {
        case .development: return "development"
        case .adhoc: return "adhoc"
        case .appstore: return "appstore"
        case .enterprise: return "enterprise"
        case .developerId: return "developer_id"
        }
    }

    /// File prefix used in Fastlane profile naming: e.g. AppStore_com.example.app.mobileprovision
    public var profilePrefix: String {
        switch self {
        case .development: return "Development"
        case .adhoc: return "AdHoc"
        case .appstore: return "AppStore"
        case .enterprise: return "InHouse"
        case .developerId: return "DeveloperID"
        }
    }

    /// Generates Fastlane-exact provisioning profile filename based on platform and bundleId.
    public func profileFileName(bundleId: String, platform: MatchPlatform = .ios) -> String {
        let suffix = platform.profileFilenameSuffix
        let ext = platform.defaultProfileExtension
        return "\(profilePrefix)_\(bundleId)\(suffix).\(ext)"
    }
}

/// Target platform for code signing and provisioning profiles in Match (Fastlane parity).
public enum MatchPlatform: String, Sendable, CaseIterable {
    case ios
    case macos
    case tvos
    case catalyst

    /// Default file extension for provisioning profiles.
    public var defaultProfileExtension: String {
        switch self {
        case .macos, .catalyst:
            return "provisionprofile"
        case .ios, .tvos:
            return "mobileprovision"
        }
    }

    /// Suffix used in Fastlane profile filenames (e.g. _tvos, _catalyst, or empty for ios/macos).
    public var profileFilenameSuffix: String {
        switch self {
        case .tvos: return "_tvos"
        case .catalyst: return "_catalyst"
        case .ios, .macos: return ""
        }
    }

    /// Profile name suffix on Apple Developer Portal:
    /// Fastlane match: "For ios we do not include the platform for backwards compatibility"
    public var portalNameSuffix: String {
        switch self {
        case .ios: return ""
        case .tvos: return " tvos"
        case .macos: return " macos"
        case .catalyst: return " catalyst"
        }
    }
}

/// Action mode for Match operations.
public enum MatchAction: String, Sendable, CaseIterable {
    case sync
    case nuke
    case prune
}

/// Information about an installed provisioning profile.
public struct MatchProfileInfo: Sendable, Equatable {
    public let name: String
    public let uuid: String
    public let path: String
    public let bundleId: String
    public let teamId: String?

    public init(name: String, uuid: String, path: String, bundleId: String, teamId: String? = nil) {
        self.name = name
        self.uuid = uuid
        self.path = path
        self.bundleId = bundleId
        self.teamId = teamId
    }
}

/// Information about an installed certificate.
public struct MatchCertificateInfo: Sendable, Equatable {
    public let id: String
    public let name: String
    public let sha1: String?
    public let cerPath: String
    public let p12Path: String

    public init(id: String, name: String, sha1: String? = nil, cerPath: String, p12Path: String) {
        self.id = id
        self.name = name
        self.sha1 = sha1
        self.cerPath = cerPath
        self.p12Path = p12Path
    }
}

/// Configuration parameters for `MatchRunner`.
public struct MatchConfig: Sendable {
    /// Git URL of the certificates repository (HTTPS or SSH format).
    public let gitUrl: String

    /// Git branch name (defaults to "master").
    public let gitBranch: String

    /// Optional Git authentication token (Personal Access Token) for HTTPS cloning.
    public let gitToken: String?

    /// Provisioning profile distribution type.
    public let type: MatchProfileType

    /// Target platform (ios, macos, tvos, catalyst). Defaults to .ios.
    public let platform: MatchPlatform

    /// List of application bundle identifiers to sync profiles for.
    public let appIdentifiers: [String]

    /// Passphrase used to decrypt and encrypt repository assets (AES-256-GCM / CBC).
    public let password: String

    /// Action to perform: `.sync` or `.nuke`. Defaults to `.sync`.
    public let action: MatchAction

    /// If true, only read existing repository assets and do not generate new ones.
    public let readonly: Bool

    /// If true, operate across all distribution types (appstore, development, adhoc, enterprise, developer_id).
    public let allTypes: Bool

    /// Optional Apple Developer Team ID.
    public let teamId: String?

    /// Optional Apple Developer Team Name.
    public let teamName: String?

    /// Optional App Store Connect API Key ID (Key ID e.g. D383SF735).
    public let apiKeyId: String?

    /// Optional App Store Connect API Issuer ID (UUID string).
    public let apiIssuerId: String?

    /// Optional App Store Connect API Private Key (content or path to AuthKey_XXX.p8).
    public let apiKey: String?

    /// Optional custom keychain name or path.
    public let keychainName: String?

    /// Optional password for unlocking custom keychain.
    public let keychainPassword: String?

    /// Force renewal of provisioning profiles even if valid.
    public let force: Bool

    /// Whether to perform a shallow clone (--depth 1). Defaults to readonly mode value.
    public let shallowClone: Bool

    /// Suppress verbose logging.
    public let silent: Bool

    public init(
        gitUrl: String,
        gitBranch: String = "master",
        gitToken: String? = nil,
        type: MatchProfileType = .appstore,
        platform: MatchPlatform = .ios,
        appIdentifiers: [String],
        password: String,
        action: MatchAction = .sync,
        readonly: Bool = true,
        allTypes: Bool = false,
        teamId: String? = nil,
        teamName: String? = nil,
        apiKeyId: String? = nil,
        apiIssuerId: String? = nil,
        apiKey: String? = nil,
        keychainName: String? = nil,
        keychainPassword: String? = nil,
        force: Bool = false,
        shallowClone: Bool? = nil,
        silent: Bool = false
    ) {
        self.gitUrl = gitUrl
        self.gitBranch = gitBranch
        self.gitToken = gitToken
        self.type = type
        self.platform = platform
        self.appIdentifiers = appIdentifiers
        self.password = password
        self.action = action
        self.readonly = readonly
        self.allTypes = allTypes
        self.teamId = teamId
        self.teamName = teamName
        self.apiKeyId = apiKeyId
        self.apiIssuerId = apiIssuerId
        self.apiKey = apiKey
        self.keychainName = keychainName
        self.keychainPassword = keychainPassword
        self.force = force
        self.shallowClone = shallowClone ?? readonly
        self.silent = silent
    }
}

/// Result of a completed Match operation.
public struct MatchResult: Sendable {
    /// Certificates installed into the keychain.
    public let installedCertificates: [MatchCertificateInfo]

    /// Provisioning profiles installed locally, keyed by application bundle identifier.
    public let installedProfiles: [String: MatchProfileInfo]

    /// Fastlane-compatible environment variables (e.g. `sigh_<bundle_id>_<type>`).
    public let envVariables: [String: String]

    public init(
        installedCertificates: [MatchCertificateInfo] = [],
        installedProfiles: [String: MatchProfileInfo] = [:],
        envVariables: [String: String] = [:]
    ) {
        self.installedCertificates = installedCertificates
        self.installedProfiles = installedProfiles
        self.envVariables = envVariables
    }
}

/// Error types thrown during Match execution.
public enum MatchError: LocalizedError, Sendable {
    case invalidGitUrl(String)
    case gitCloneFailed(String)
    case gitOperationFailed(String)
    case decryptionFailed(String)
    case encryptionFailed(String)
    case certificateNotFound(type: MatchProfileType, expectedDir: String)
    case profileNotFound(bundleId: String, type: MatchProfileType, expectedPath: String)
    case profileCertificateMismatch(bundleId: String, profileName: String, certificateId: String)
    case profileRevokedOnPortal(bundleId: String, profileName: String)
    case keychainError(String)
    case profileParsingFailed(String)
    case missingPassword
    case portalAuthenticationRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGitUrl(let url):
            return "Invalid Git repository URL for Match: \(url)"
        case .gitCloneFailed(let message):
            return "Failed to clone Match repository: \(message)"
        case .gitOperationFailed(let message):
            return "Git operation failed: \(message)"
        case .decryptionFailed(let message):
            return "Failed to decrypt Match repository: \(message). Check your encryption password."
        case .encryptionFailed(let message):
            return "Failed to encrypt Match repository: \(message)"
        case .certificateNotFound(let type, let dir):
            return "No valid certificate found for '\(type.rawValue)' in repository directory '\(dir)'."
        case .profileNotFound(let bundleId, let type, let path):
            return "No valid profile found for '\(bundleId)' of type '\(type.rawValue)' at '\(path)'."
        case .profileCertificateMismatch(let bundleId, let profileName, let certId):
            return "Provisioning profile '\(profileName)' for '\(bundleId)' is not valid for certificate '\(certId)' and readonly mode is enabled."
        case .profileRevokedOnPortal(let bundleId, let profileName):
            return "Provisioning profile '\(profileName)' for '\(bundleId)' is revoked or invalid on Apple Developer Portal and readonly mode is enabled."
        case .keychainError(let message):
            return "Keychain error: \(message)"
        case .profileParsingFailed(let message):
            return "Provisioning profile parsing error: \(message)"
        case .missingPassword:
            return "Match encryption password is empty. Set MATCH_PASSWORD or pass --password."
        case .portalAuthenticationRequired(let message):
            return "Apple Developer Portal authentication error: \(message)"
        }
    }
}
