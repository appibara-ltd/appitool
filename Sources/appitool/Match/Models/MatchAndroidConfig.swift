import Foundation

/// Configuration for Android keystore operations in Match.
public struct MatchAndroidConfig: Sendable {
    public enum Action: String, Sendable, CaseIterable {
        case sync
        case add
    }

    public enum BuildType: String, Sendable, CaseIterable {
        case release
        case debug
    }

    /// Git URL of the certificates/keystores repository.
    public let gitUrl: String

    /// Git branch name (defaults to "master").
    public let gitBranch: String

    /// Optional Git authentication credential: HTTPS Personal Access Token or SSH private/deploy key (file path, raw PEM, or Base64).
    public let gitToken: String?

    /// Passphrase used to decrypt and encrypt repository assets (AES-256).
    public let password: String

    /// Action to perform: `.sync` or `.add`. Defaults to `.sync`.
    public let action: Action

    /// Target application package name (e.g. `com.example.app`).
    public let packageName: String

    /// Target build type (`release` or `debug`).
    public let buildType: BuildType

    /// Path to local keystore file (required for `.add` action).
    public let keystorePath: String?

    /// Key alias (e.g. `upload`).
    public let alias: String?

    /// Keystore password.
    public let storePassword: String?

    /// Key password.
    public let keyPassword: String?

    /// If true, suppress verbose output.
    public let silent: Bool

    public init(
        gitUrl: String,
        gitBranch: String = "master",
        gitToken: String? = nil,
        password: String,
        action: Action = .sync,
        packageName: String,
        buildType: BuildType = .release,
        keystorePath: String? = nil,
        alias: String? = nil,
        storePassword: String? = nil,
        keyPassword: String? = nil,
        silent: Bool = false
    ) {
        self.gitUrl = gitUrl
        self.gitBranch = gitBranch
        self.gitToken = gitToken
        self.password = password
        self.action = action
        self.packageName = packageName
        self.buildType = buildType
        self.keystorePath = keystorePath
        self.alias = alias
        self.storePassword = storePassword
        self.keyPassword = keyPassword
        self.silent = silent
    }
}

/// Metadata stored in Match Git repository alongside the keystore file.
public struct AndroidKeystoreMetadata: Codable, Sendable, Equatable {
    public let packageName: String
    public let buildType: String
    public let alias: String
    public let storePassword: String
    public let keyPassword: String

    public enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case buildType = "build_type"
        case alias
        case storePassword = "store_password"
        case keyPassword = "key_password"
    }

    public init(
        packageName: String,
        buildType: String,
        alias: String,
        storePassword: String,
        keyPassword: String
    ) {
        self.packageName = packageName
        self.buildType = buildType
        self.alias = alias
        self.storePassword = storePassword
        self.keyPassword = keyPassword
    }
}

/// Result of resolving an Android keystore from Match Git repository.
public struct MatchAndroidResult: Sendable {
    /// Absolute path to the resolved keystore file.
    public let keystorePath: String

    /// Key alias.
    public let alias: String

    /// Keystore password.
    public let storePassword: String

    /// Key password.
    public let keyPassword: String

    /// Temporary URL reference (if cloned/copied to a temp location) for cleanup.
    public let tempUrl: URL?

    public init(
        keystorePath: String,
        alias: String,
        storePassword: String,
        keyPassword: String,
        tempUrl: URL? = nil
    ) {
        self.keystorePath = keystorePath
        self.alias = alias
        self.storePassword = storePassword
        self.keyPassword = keyPassword
        self.tempUrl = tempUrl
    }
}

extension MatchAndroidResult {
    /// Generates a `GradleTask.SigningConfig` instance ready for build injection.
    public var signingConfig: GradleTask.SigningConfig {
        GradleTask.SigningConfig(
            storeFile: keystorePath,
            storePassword: storePassword,
            keyAlias: alias,
            keyPassword: keyPassword
        )
    }
}
