import ArgumentParser
import Foundation
import AppleServices
import GoogleServices

/// Reusable CLI options and environment resolution for App Store Connect credentials.
struct AppleCredentialsOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "App Store Connect Key ID (defaults to APPLE_KEY_ID in .env).")
    var appleKeyId: String?

    @Option(name: .long, help: "App Store Connect Issuer ID (defaults to APPLE_ISSUER_ID in .env).")
    var appleIssuerId: String?

    @Option(name: .long, help: "App Store Connect Key (file path, raw PEM, or Base64 string; defaults to APPLE_KEY in .env).")
    var appleKey: String?

    /// Resolves the credentials by checking CLI flags first, falling back to environment variables.
    func resolve() -> (keyId: String, issuerId: String, key: String)? {
        guard let resolvedKeyId = appleKeyId ?? EnvLoader.value(for: "APPLE_KEY_ID"),
              let resolvedIssuerId = appleIssuerId ?? EnvLoader.value(for: "APPLE_ISSUER_ID"),
              let resolvedKey = appleKey ?? EnvLoader.value(for: "APPLE_KEY"),
              !resolvedKeyId.isEmpty, !resolvedIssuerId.isEmpty, !resolvedKey.isEmpty else {
            return nil
        }
        return (resolvedKeyId, resolvedIssuerId, resolvedKey)
    }

    /// Initializes and returns an `AppStoreService` if credentials are available.
    func makeService() throws -> AppStoreService? {
        guard let creds = resolve() else { return nil }
        return try AppStoreService(keyId: creds.keyId, issuerId: creds.issuerId, key: creds.key)
    }

    /// Returns an `AppStoreService` or throws a descriptive `ValidationError`.
    func requireService() throws -> AppStoreService {
        guard let service = try makeService() else {
            throw ValidationError("Missing App Store Connect credentials. Provide flags or set APPLE_KEY, APPLE_KEY_ID, and APPLE_ISSUER_ID in .env.")
        }
        return service
    }
}

/// Reusable CLI options and environment resolution for Google Play credentials.
struct GoogleCredentialsOptions: ParsableArguments, Sendable {
    @Option(name: .shortAndLong, help: "Google Service Account Key (file path, raw JSON, or Base64 string; defaults to GOOGLE_KEY in .env).")
    var googleKey: String?

    /// Resolves the credentials by checking CLI flags first, falling back to environment variables.
    func resolveKey() -> String? {
        guard let resolvedKey = googleKey ?? EnvLoader.value(for: "GOOGLE_KEY"), !resolvedKey.isEmpty else {
            return nil
        }
        return resolvedKey
    }

    /// Initializes and returns a `GooglePlayService` if credentials are available.
    func makeService() throws -> GooglePlayService? {
        guard let key = resolveKey() else { return nil }
        return try GooglePlayService(key: key)
    }

    /// Returns a `GooglePlayService` or throws a descriptive `ValidationError`.
    func requireService() throws -> GooglePlayService {
        guard let service = try makeService() else {
            throw ValidationError("Missing Google Play Service Account key. Provide -g, --google-key or set GOOGLE_KEY in .env.")
        }
        return service
    }
}

/// Reusable CLI options and environment resolution for Firebase project-level operations (e.g. tester groups).
struct FirebaseProjectOptions: ParsableArguments, Sendable {
    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    @Option(name: .shortAndLong, help: "Firebase/Google Cloud project number or project ID (defaults to FIREBASE_PROJECT_ID in .env).")
    var project: String?

    var googleKey: String? {
        googleCredentials.googleKey
    }

    /// Resolves the Google Key from option or environment.
    func resolveKey() -> String? {
        googleCredentials.resolveKey()
    }

    /// Resolves the Firebase project identifier (project number or project ID).
    func resolveProject(fallbackAppId: String? = nil) -> String? {
        if let project, !project.isEmpty {
            return project
        }
        if let envProj = EnvLoader.value(for: "FIREBASE_PROJECT_ID") ?? EnvLoader.value(for: "GOOGLE_PROJECT_ID"), !envProj.isEmpty {
            return envProj
        }
        if let appId = fallbackAppId ?? EnvLoader.value(for: "FIREBASE_IOS_APP_ID") ?? EnvLoader.value(for: "FIREBASE_ANDROID_APP_ID"), appId.contains(":") {
            let segments = appId.split(separator: ":")
            if segments.count >= 2 {
                return String(segments[1])
            }
        }
        return nil
    }

    /// Resolves credentials from CLI options or environment and creates a `FirebaseService`.
    func makeService() throws -> FirebaseService? {
        guard let key = resolveKey() else { return nil }
        return try FirebaseService(key: key)
    }

    /// Returns a `FirebaseService` or throws a descriptive `ValidationError`.
    func requireService() throws -> FirebaseService {
        guard let service = try makeService() else {
            throw ValidationError("Missing Google Service Account key for Firebase. Provide --google-key or set GOOGLE_KEY in .env.")
        }
        return service
    }

    /// Returns the Firebase project identifier or throws a descriptive `ValidationError`.
    func requireProject(fallbackAppId: String? = nil) throws -> String {
        guard let project = resolveProject(fallbackAppId: fallbackAppId) else {
            throw ValidationError("Missing project identifier (configure FIREBASE_PROJECT_ID in .env, or provide -p, --project).")
        }
        return project
    }
}

/// Reusable CLI options and environment resolution for Firebase application-level operations (e.g. releases).
struct FirebaseCredentialsOptions: ParsableArguments, Sendable {
    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .customLong("firebase-app-id"), help: "Firebase App ID (defaults to FIREBASE_IOS_APP_ID or FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    var googleKey: String? {
        projectOptions.googleKey
    }

    var project: String? {
        projectOptions.project
    }

    enum Platform: String, ExpressibleByArgument, CaseIterable, Sendable {
        case ios
        case android
    }

    @Option(name: .customLong("platform"), help: "Target platform for Firebase App ID resolution (ios, android).")
    var platform: Platform?

    /// Resolves the Google Key from option or environment.
    func resolveKey() -> String? {
        projectOptions.resolveKey()
    }

    /// Resolves the Firebase App ID from option or environment, targeting iOS or Android.
    func resolveAppId(for platform: Platform? = nil) -> String? {
        if let firebaseAppId, !firebaseAppId.isEmpty {
            return firebaseAppId
        }
        let targetPlatform = platform ?? self.platform

        switch targetPlatform {
        case .ios:
            return EnvLoader.value(for: "FIREBASE_IOS_APP_ID")
        case .android:
            return EnvLoader.value(for: "FIREBASE_ANDROID_APP_ID")
        case nil:
            return EnvLoader.value(for: "FIREBASE_IOS_APP_ID") ?? EnvLoader.value(for: "FIREBASE_ANDROID_APP_ID")
        }
    }

    /// Resolves the Firebase project identifier (project number or project ID).
    func resolveProject() -> String? {
        projectOptions.resolveProject(fallbackAppId: resolveAppId())
    }

    /// Resolves credentials from CLI options or environment and creates a `FirebaseService`.
    func makeService() throws -> FirebaseService? {
        try projectOptions.makeService()
    }

    /// Returns a `FirebaseService` or throws a descriptive `ValidationError`.
    func requireService() throws -> FirebaseService {
        try projectOptions.requireService()
    }

    /// Returns the Firebase App ID or throws a descriptive `ValidationError`.
    func requireAppId(for platform: Platform? = nil) throws -> String {
        guard let appId = resolveAppId(for: platform) else {
            throw ValidationError("Missing Firebase App ID (configure FIREBASE_IOS_APP_ID / FIREBASE_ANDROID_APP_ID in .env or via --firebase-app-id).")
        }
        return appId
    }
}

/// Reusable CLI options and environment resolution for Webhook notifications.
struct NotificationOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "Slack incoming webhook URL (defaults to SLACK_URL in .env).")
    var slackUrl: String?

    @Option(name: .long, help: "KokoNo notification URL (defaults to KOKONO_URL in .env).")
    var kokonoUrl: String?

    @Option(name: .long, help: "Optional KokoNo public key for end-to-end (E2E) encryption (defaults to KOKONO_E2E_PUBLIC_KEY in .env).")
    var kokonoPublicKey: String?

    /// Resolves notification URLs and keys by checking CLI flags first, falling back to environment variables.
    func resolve() -> (slackUrl: String?, kokonoUrl: String?, kokonoPublicKey: String?) {
        let resolvedSlack = slackUrl ?? EnvLoader.value(for: "SLACK_URL")
        let resolvedKokono = kokonoUrl ?? EnvLoader.value(for: "KOKONO_URL")
        let resolvedKey: String?
        if kokonoUrl != nil {
            resolvedKey = kokonoPublicKey
        } else {
            resolvedKey = kokonoPublicKey ?? EnvLoader.value(for: "KOKONO_E2E_PUBLIC_KEY")
        }
        return (
            resolvedSlack?.isEmpty == false ? resolvedSlack : nil,
            resolvedKokono?.isEmpty == false ? resolvedKokono : nil,
            resolvedKey?.isEmpty == false ? resolvedKey : nil
        )
    }
}

/// Reusable CLI options and environment resolution for Match Git storage.
struct MatchStorageOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "Git repository URL for Match storage (defaults to MATCH_GIT_URL in .env).")
    var matchGitUrl: String?

    @Option(name: .long, help: "Git branch name for Match storage (defaults to MATCH_GIT_BRANCH in .env or 'master').")
    var matchGitBranch: String?

    @Option(name: .long, help: "Git authentication token for Match storage (defaults to MATCH_GIT_TOKEN or GITHUB_TOKEN in .env).")
    var matchGitToken: String?

    @Option(name: .long, help: "Passphrase for Match AES encryption/decryption (defaults to MATCH_PASSWORD in .env).")
    var matchPassword: String?

    /// Resolves Match storage options by checking CLI flags first, falling back to environment variables.
    func resolve() -> (
        gitUrl: String?,
        gitBranch: String,
        gitToken: String?,
        password: String?
    ) {
        let resolvedGitUrl = matchGitUrl ?? EnvLoader.value(for: "MATCH_GIT_URL")
        let resolvedGitBranch = matchGitBranch ?? EnvLoader.value(for: "MATCH_GIT_BRANCH") ?? "master"
        let resolvedGitToken = matchGitToken ?? EnvLoader.value(for: "MATCH_GIT_TOKEN") ?? EnvLoader.value(for: "GITHUB_TOKEN")
        let resolvedPassword = matchPassword ?? EnvLoader.value(for: "MATCH_PASSWORD")
        return (
            gitUrl: resolvedGitUrl?.isEmpty == false ? resolvedGitUrl : nil,
            gitBranch: resolvedGitBranch,
            gitToken: resolvedGitToken?.isEmpty == false ? resolvedGitToken : nil,
            password: resolvedPassword?.isEmpty == false ? resolvedPassword : nil
        )
    }

    /// Returns resolved Match storage options or throws a descriptive `ValidationError` when URL or password is missing.
    func require() throws -> (
        gitUrl: String,
        gitBranch: String,
        gitToken: String?,
        password: String
    ) {
        let resolved = resolve()
        guard let gitUrl = resolved.gitUrl, !gitUrl.isEmpty else {
            throw ValidationError("Missing Git repository URL. Provide --match-git-url or configure MATCH_GIT_URL in .env.")
        }
        guard let password = resolved.password, !password.isEmpty else {
            throw ValidationError("Missing encryption password. Provide --match-password or configure MATCH_PASSWORD in .env.")
        }
        return (
            gitUrl: gitUrl,
            gitBranch: resolved.gitBranch,
            gitToken: resolved.gitToken,
            password: password
        )
    }
}

/// Reusable CLI options and environment resolution for Apple/iOS Fastlane Match.
struct MatchOptions: ParsableArguments, Sendable {
    @OptionGroup var storage: MatchStorageOptions

    @Option(name: .long, help: "Custom keychain name or path (defaults to MATCH_KEYCHAIN_NAME in .env).")
    var keychainName: String?

    @Option(name: .long, help: "Password for unlocking custom keychain (defaults to MATCH_KEYCHAIN_PASSWORD in .env).")
    var keychainPassword: String?

    @Option(name: .long, help: "Apple Developer Portal Team ID (defaults to APPLE_TEAM_ID in .env).")
    var teamId: String?

    @Flag(name: .long, help: "Only fetch existing certificates and profiles without creating new ones.")
    var readonly: Bool = false

    /// Resolves Match options by checking CLI flags first, falling back to environment variables.
    func resolve(defaultReadonly: Bool = true) -> (
        gitUrl: String?,
        gitBranch: String,
        gitToken: String?,
        password: String?,
        keychainName: String?,
        keychainPassword: String?,
        teamId: String?,
        readonly: Bool
    ) {
        let resolvedStorage = storage.resolve()
        let resolvedKeychainName = keychainName ?? EnvLoader.value(for: "MATCH_KEYCHAIN_NAME") ?? "appitool"
        let resolvedKeychainPassword = keychainPassword ?? EnvLoader.value(for: "MATCH_KEYCHAIN_PASSWORD") ?? "appipass"
        let resolvedTeamId = teamId ?? EnvLoader.value(for: "APPLE_TEAM_ID")
        let isReadonly = defaultReadonly
            ? (readonly || (EnvLoader.value(for: "MATCH_READONLY") != "false"))
            : readonly
        return (
            gitUrl: resolvedStorage.gitUrl,
            gitBranch: resolvedStorage.gitBranch,
            gitToken: resolvedStorage.gitToken,
            password: resolvedStorage.password,
            keychainName: resolvedKeychainName.isEmpty ? "appitool" : resolvedKeychainName,
            keychainPassword: resolvedKeychainPassword.isEmpty ? "appipass" : resolvedKeychainPassword,
            teamId: resolvedTeamId?.isEmpty == false ? resolvedTeamId : nil,
            readonly: isReadonly
        )
    }
}
