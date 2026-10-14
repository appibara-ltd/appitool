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
        let env = ProcessInfo.processInfo.environment
        guard let resolvedKeyId = appleKeyId ?? env["APPLE_KEY_ID"],
              let resolvedIssuerId = appleIssuerId ?? env["APPLE_ISSUER_ID"],
              let resolvedKey = appleKey ?? env["APPLE_KEY"],
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
    @Option(name: .long, help: "Google Service Account Key (file path, raw JSON, or Base64 string; defaults to GOOGLE_KEY in .env).")
    var googleKey: String?

    /// Resolves the credentials by checking CLI flags first, falling back to environment variables.
    func resolveKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let resolvedKey = googleKey ?? env["GOOGLE_KEY"], !resolvedKey.isEmpty else {
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
            throw ValidationError("Missing Google Play Service Account key. Provide --google-key or set GOOGLE_KEY in .env.")
        }
        return service
    }
}

/// Reusable CLI options and environment resolution for Firebase project-level operations (e.g. tester groups).
struct FirebaseProjectOptions: ParsableArguments, Sendable {
    @Option(name: .shortAndLong, help: "Google Service Account Key (file path, raw JSON, or Base64 string; defaults to GOOGLE_KEY in .env).")
    var googleKey: String?

    @Option(name: .shortAndLong, help: "Firebase/Google Cloud project number or project ID (defaults to FIREBASE_PROJECT_ID in .env).")
    var project: String?

    /// Resolves the Google Key from option or environment.
    func resolveKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        let resolved = googleKey ?? env["GOOGLE_KEY"]
        return resolved?.isEmpty == false ? resolved : nil
    }

    /// Resolves the Firebase project identifier (project number or project ID).
    func resolveProject(fallbackAppId: String? = nil) -> String? {
        if let project, !project.isEmpty {
            return project
        }
        let env = ProcessInfo.processInfo.environment
        if let envProj = env["FIREBASE_PROJECT_ID"] ?? env["GOOGLE_PROJECT_ID"], !envProj.isEmpty {
            return envProj
        }
        if let appId = fallbackAppId ?? env["FIREBASE_IOS_APP_ID"] ?? env["FIREBASE_ANDROID_APP_ID"], appId.contains(":") {
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
        let env = ProcessInfo.processInfo.environment
        let targetPlatform = platform ?? self.platform

        switch targetPlatform {
        case .ios:
            return env["FIREBASE_IOS_APP_ID"]
        case .android:
            return env["FIREBASE_ANDROID_APP_ID"]
        case nil:
            return env["FIREBASE_IOS_APP_ID"] ?? env["FIREBASE_ANDROID_APP_ID"]
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
        let env = ProcessInfo.processInfo.environment
        let resolvedSlack = slackUrl ?? env["SLACK_URL"]
        let resolvedKokono = kokonoUrl ?? env["KOKONO_URL"]
        let resolvedKey: String?
        if kokonoUrl != nil {
            resolvedKey = kokonoPublicKey
        } else {
            resolvedKey = kokonoPublicKey ?? env["KOKONO_E2E_PUBLIC_KEY"]
        }
        return (
            resolvedSlack?.isEmpty == false ? resolvedSlack : nil,
            resolvedKokono?.isEmpty == false ? resolvedKokono : nil,
            resolvedKey?.isEmpty == false ? resolvedKey : nil
        )
    }
}

/// Reusable CLI options and environment resolution for Fastlane Match.
struct MatchOptions: ParsableArguments, Sendable {
    @Option(name: [.long, .customLong("match-git-url")], help: "Git repository URL for certificates storage (defaults to MATCH_GIT_URL in .env).")
    var gitUrl: String?

    @Option(name: [.long, .customLong("match-git-branch")], help: "Git branch name (defaults to MATCH_GIT_BRANCH in .env or 'master').")
    var gitBranch: String?

    @Option(name: [.long, .customLong("match-git-token")], help: "Git authentication token (defaults to MATCH_GIT_TOKEN or GITHUB_TOKEN in .env).")
    var gitToken: String?

    @Option(name: [.long, .customLong("match-password")], help: "Passphrase for AES encryption/decryption (defaults to MATCH_PASSWORD in .env).")
    var password: String?

    @Option(name: [.long], help: "Custom keychain name or path (defaults to MATCH_KEYCHAIN_NAME in .env).")
    var keychainName: String?

    @Option(name: [.long], help: "Password for unlocking custom keychain (defaults to MATCH_KEYCHAIN_PASSWORD in .env).")
    var keychainPassword: String?

    @Option(name: [.long], help: "Apple Developer Portal Team ID (defaults to APPLE_TEAM_ID in .env).")
    var teamId: String?

    @Flag(name: [.long], help: "Only fetch existing certificates and profiles without creating new ones.")
    var readonly: Bool = false

    /// Resolves Match options by checking CLI flags first, falling back to environment variables.
    func resolve() -> (
        gitUrl: String?,
        gitBranch: String,
        gitToken: String?,
        password: String?,
        keychainName: String?,
        keychainPassword: String?,
        teamId: String?,
        readonly: Bool
    ) {
        let env = ProcessInfo.processInfo.environment
        let resolvedGitUrl = gitUrl ?? env["MATCH_GIT_URL"]
        let resolvedGitBranch = gitBranch ?? env["MATCH_GIT_BRANCH"] ?? "master"
        let resolvedGitToken = gitToken ?? env["MATCH_GIT_TOKEN"] ?? env["GITHUB_TOKEN"]
        let resolvedPassword = password ?? env["MATCH_PASSWORD"]
        let resolvedKeychainName = keychainName ?? env["MATCH_KEYCHAIN_NAME"] ?? "appitool"
        let resolvedKeychainPassword = keychainPassword ?? env["MATCH_KEYCHAIN_PASSWORD"] ?? "appipass"
        let resolvedTeamId = teamId ?? env["APPLE_TEAM_ID"]
        let isReadonly = readonly || (env["MATCH_READONLY"] != "false")
        return (
            gitUrl: resolvedGitUrl?.isEmpty == false ? resolvedGitUrl : nil,
            gitBranch: resolvedGitBranch,
            gitToken: resolvedGitToken?.isEmpty == false ? resolvedGitToken : nil,
            password: resolvedPassword?.isEmpty == false ? resolvedPassword : nil,
            keychainName: resolvedKeychainName.isEmpty ? "appitool" : resolvedKeychainName,
            keychainPassword: resolvedKeychainPassword.isEmpty ? "appipass" : resolvedKeychainPassword,
            teamId: resolvedTeamId?.isEmpty == false ? resolvedTeamId : nil,
            readonly: isReadonly
        )
    }
}
