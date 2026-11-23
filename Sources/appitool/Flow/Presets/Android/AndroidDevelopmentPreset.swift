import Foundation
import GoogleServices
import Rainbow

/// Preconfigured preset for building Android `debug` builds (APK by default) and distributing them via Firebase App Distribution.
///
/// Differs from `AndroidAdHocPreset` in the Gradle build type (`debug` instead of `release`) and signing: the
/// project's own Gradle debug signing config is used, so no Match release keystore is resolved.
struct AndroidDevelopmentPreset: FlowPreset {
    let name: String = "Android Development"
    let description: String =
        "Automated Android flow configured for debug builds distributed via Firebase App Distribution."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("FIREBASE_ANDROID_APP_ID", context.firebaseAppId, "Firebase Android App ID"),
                ("GOOGLE_KEY", context.googleKey, "Google Service Account key for Firebase"),
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 Validating Firebase App Distribution and Android project setup (debug build)...".dim)

        try await AndroidPresetHelpers.setupAndroidProject(context: &context)

        // Debug builds are signed by Gradle's debug signing config; the Match release keystore is not used.
        Log("🔐 Using the project's Gradle debug signing config (Match release keystore is not used for debug builds).".dim)

        try await FirebasePresetHelpers.fetchLatestBuild(context: &context, presetName: name, appIdKey: "FIREBASE_ANDROID_APP_ID")
    }

    func prebuild(context: inout FlowContext) async throws {
        AndroidPresetHelpers.bumpVersionCode(
            context: &context,
            remoteVersionCode: context.metadata["firebase_build_number"],
            sourceLabel: "Firebase"
        )
    }

    func build(context: inout FlowContext) async throws {
        try await AndroidPresetHelpers.build(context: &context, format: context.androidFormat ?? .apk, buildType: "debug")
    }

    func release(context: inout FlowContext) async throws {
        let format = context.androidFormat ?? .apk
        try await FirebasePresetHelpers.distribute(
            context: &context,
            presetName: name,
            artifactExtension: format.rawValue,
            artifactLabel: "debug \(format.rawValue.uppercased())",
            appIdKey: "FIREBASE_ANDROID_APP_ID"
        )
    }
}
