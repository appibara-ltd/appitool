import ArgumentParser
import Foundation

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

    /// Applies any provided CLI flags over environment variables.
    func applyEnvironmentOverrides() {
        if let appleKeyId, !appleKeyId.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "APPLE_KEY_ID", value: appleKeyId)
        }
        if let appleIssuerId, !appleIssuerId.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "APPLE_ISSUER_ID", value: appleIssuerId)
        }
        if let appleKey, !appleKey.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "APPLE_KEY", value: appleKey)
        }
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

    /// Applies any provided CLI flags over environment variables.
    func applyEnvironmentOverrides() {
        if let googleKey, !googleKey.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "GOOGLE_KEY", value: googleKey)
        }
    }
}

/// Reusable CLI options and environment resolution for Firebase credentials.
struct FirebaseCredentialsOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "Firebase App ID (defaults to FIREBASE_IOS_APP_ID or FIREBASE_ANDROID_APP_ID in .env).")
    var firebaseAppId: String?

    @Option(name: .long, help: "Firebase CI token (defaults to FIREBASE_TOKEN in .env).")
    var firebaseToken: String?

    /// Applies any provided CLI flags over environment variables.
    func applyEnvironmentOverrides(platformAppIdKey: String) {
        if let firebaseAppId, !firebaseAppId.isEmpty {
            EnvLoader.setEnvironmentVariable(key: platformAppIdKey, value: firebaseAppId)
        }
        if let firebaseToken, !firebaseToken.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "FIREBASE_TOKEN", value: firebaseToken)
        }
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

    /// Applies any provided CLI flags over environment variables.
    func applyEnvironmentOverrides() {
        if let slackUrl, !slackUrl.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "SLACK_URL", value: slackUrl)
        }
        if let kokonoUrl, !kokonoUrl.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "KOKONO_URL", value: kokonoUrl)
            // Per-URL Keypair Isolation:
            // When kokonoUrl is overridden, public key must also be provided via CLI;
            // otherwise clear KOKONO_E2E_PUBLIC_KEY so the .env key is not used for a different URL.
            if let kokonoPublicKey, !kokonoPublicKey.isEmpty {
                EnvLoader.setEnvironmentVariable(key: "KOKONO_E2E_PUBLIC_KEY", value: kokonoPublicKey)
            } else {
                EnvLoader.setEnvironmentVariable(key: "KOKONO_E2E_PUBLIC_KEY", value: "")
            }
        } else if let kokonoPublicKey, !kokonoPublicKey.isEmpty {
            EnvLoader.setEnvironmentVariable(key: "KOKONO_E2E_PUBLIC_KEY", value: kokonoPublicKey)
        }
    }
}
