import Foundation

/// Resolves app identifiers with one consistent precedence for every command:
/// explicit CLI option → `.env` variable → local project detection (when enabled).
///
/// Flow commands pass `detectFromProject: false` because their presets detect identifiers from the
/// project themselves (scheme- and flavor-aware) and must know whether the value was supplied explicitly.
enum AppIdentifierResolver {
    /// Target platform for Firebase App ID resolution.
    typealias FirebasePlatform = FirebaseCredentialsOptions.Platform

    /// Android package name: `--package-name` → `GOOGLE_PACKAGE_NAME` → `applicationId`/`namespace` from the Android project.
    static func androidPackageName(
        explicit: String?,
        projectRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        detectFromProject: Bool = true
    ) -> String? {
        if let value = CLIValues.trimmedNonEmpty(explicit) { return value }
        if let value = CLIValues.trimmedNonEmpty(EnvLoader.value(for: "GOOGLE_PACKAGE_NAME")) { return value }
        guard detectFromProject else { return nil }
        return CLIValues.trimmedNonEmpty(AndroidTasks.resolvePackageName(in: projectRoot))
    }

    /// iOS bundle identifier: `-b, --bundle-id` → `APPLE_BUNDLE_ID` → main target bundle ID from the local Xcode project.
    static func iosBundleId(explicit: String?, detectFromProject: Bool = true) async -> String? {
        if let value = CLIValues.trimmedNonEmpty(explicit) { return value }
        if let value = CLIValues.trimmedNonEmpty(EnvLoader.value(for: "APPLE_BUNDLE_ID")) { return value }
        guard detectFromProject, XCodeTasks.hasIosProject() else { return nil }
        return CLIValues.trimmedNonEmpty(try? await XCodeTasks.getIosIdentifiers().bundleId)
    }

    /// Firebase App ID: `--firebase-app-id` → `FIREBASE_IOS_APP_ID` / `FIREBASE_ANDROID_APP_ID`
    /// (both, iOS first, when `platform` is `nil`).
    static func firebaseAppId(explicit: String?, platform: FirebasePlatform?) -> String? {
        if let value = CLIValues.trimmedNonEmpty(explicit) { return value }
        let iosAppId = { CLIValues.trimmedNonEmpty(EnvLoader.value(for: "FIREBASE_IOS_APP_ID")) }
        let androidAppId = { CLIValues.trimmedNonEmpty(EnvLoader.value(for: "FIREBASE_ANDROID_APP_ID")) }
        switch platform {
        case .ios: return iosAppId()
        case .android: return androidAppId()
        case nil: return iosAppId() ?? androidAppId()
        }
    }
}
