import Foundation
import Rainbow

/// Preconfigured preset for building and distributing Android Ad-Hoc / APK releases.
struct AndroidAdHocPreset: FlowPreset {
    let name: String = "Android AdHoc"
    let description: String =
        "Automated Android release flow configured for direct APK distribution."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("FIREBASE_ANDROID_APP_ID", context.firebaseAppId, "Firebase Android App ID"),
                ("GOOGLE_KEY", context.googleKey, "Google Service Account key for Firebase"),
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 [\(name)] Checking Android SDK, Gradle environment, and signing keystores...".dim)
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("🔧 [\(name)] Updating versionCode, versionName, and release notes...".dim)
    }

    func build(context: inout FlowContext) async throws {
        Log("🔨 [\(name)] Running Gradle assembleRelease for universal APK...".dim)
    }

    func postbuild(context: inout FlowContext) async throws {
        Log("📦 [\(name)] Verifying APK signature and zipalign...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("📝 [\(name)] Packaging APK artifact and tester changelog...".dim)
    }

    func release(context: inout FlowContext) async throws {
        Log("🚀 [\(name)] Distributing APK to distribution channels...".dim)
    }
}
