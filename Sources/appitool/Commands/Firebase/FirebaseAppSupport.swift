import ArgumentParser
import Foundation
import GoogleServices

/// `-p, --platform` values for Firebase App commands.
enum FirebaseAppPlatformOption: String, ExpressibleByArgument, CaseIterable, Sendable {
    case ios
    case android
    case web

    var apiPlatform: FirebaseAppPlatform {
        switch self {
        case .ios: return .ios
        case .android: return .android
        case .web: return .web
        }
    }
}

enum FirebaseAppSupport {
    /// `.env` variable that stores the Firebase App ID of a platform, if appitool uses one.
    static func appIdEnvVar(for platform: String?) -> String? {
        switch platform {
        case FirebaseAppPlatform.ios.rawValue: return "FIREBASE_IOS_APP_ID"
        case FirebaseAppPlatform.android.rawValue: return "FIREBASE_ANDROID_APP_ID"
        default: return nil
        }
    }

    /// Validates `--sha1` (40 hex digits) and `--sha256` (64 hex digits) values; colons are optional.
    static func validateFingerprints(sha1: [String], sha256: [String]) throws {
        for (label, values, length) in [("--sha1", sha1, 40), ("--sha256", sha256, 64)] {
            for value in values where FirebaseShaCertificate.normalize(value).count != length || value.contains(where: { !$0.isHexDigit && $0 != ":" }) {
                throw ValidationError("Invalid \(label) fingerprint '\(value)' (expected \(length) hex digits, colons optional).")
            }
        }
    }

    /// Firebase Android App ID: explicit / `FIREBASE_ANDROID_APP_ID` value, else the active Android app registered for the package name.
    static func resolveAndroidAppId(explicit: String?, packageName: String?, project: String, service: FirebaseService) async throws -> String {
        if let explicit { return explicit }
        guard let packageName else {
            throw ValidationError("Missing Firebase app. Provide --firebase-app-id, set FIREBASE_ANDROID_APP_ID in .env, or provide --package-name.")
        }
        let apps: [FirebaseAppSummary]
        do {
            apps = try await service.listApps(project: project)
        } catch let error as FirebaseAppsError {
            throw CommandError(error.localizedDescription, hint: hint(for: error))
        }
        guard let app = apps.first(where: { $0.platform == FirebaseAppPlatform.android.rawValue && $0.namespace == packageName && $0.state != "DELETED" }) else {
            throw CommandError(
                "No Firebase Android app for \(packageName) in project [\(project)].",
                hint: "Register it with 'appitool firebase apps create -p android --package-name \(packageName)'."
            )
        }
        return app.appId
    }

    /// `SHA-1  ` / `SHA-256` label padded for aligned output.
    static func label(_ type: FirebaseShaCertificate.CertType) -> String {
        switch type {
        case .sha1: return "SHA-1  "
        case .sha256: return "SHA-256"
        case .unspecified: return "SHA    "
        }
    }

    /// Hint for common Firebase Management API failures.
    static func hint(for error: FirebaseAppsError) -> String? {
        switch error.status {
        case 403:
            return "The service account needs a Firebase role that can manage apps in this project (e.g. Firebase Admin), and the Firebase Management API must be enabled."
        case 404:
            return "Check --project (project ID or number) and that the project has Firebase enabled."
        case 409:
            return "An app with this identifier already exists in a Firebase project (possibly a deleted one awaiting removal)."
        default:
            return nil
        }
    }
}
