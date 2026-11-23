import Foundation
import GoogleServices
import Rainbow

/// Preconfigured preset for building and distributing Android Ad-Hoc (APK or AAB) releases via Firebase App Distribution.
struct AndroidAdHocPreset: FlowPreset {
    let name: String = "Android AdHoc"
    let description: String =
        "Automated Android release flow configured for direct APK/AAB distribution via Firebase App Distribution."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("FIREBASE_ANDROID_APP_ID", context.firebaseAppId, "Firebase Android App ID"),
                ("GOOGLE_KEY", context.googleKey, "Google Service Account key for Firebase"),
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 Validating Firebase App Distribution and Android project setup...".dim)

        try await AndroidPresetHelpers.setupAndroidProject(context: &context)

        // Resolve the release keystore via Match when configured (fails loudly on errors)
        try await AndroidPresetHelpers.resolveMatchKeystore(context: &context)

        guard let firebaseAppId = context.firebaseAppId, !firebaseAppId.isEmpty else { return }
        guard let googleKey = context.googleKey, !googleKey.isEmpty else { return }

        if let service = try? FirebaseService(key: googleKey) {
            if let buildInfo = try? await GetLatestBuildNumberTask().run(
                .init(
                    target: .android(
                        packageName: context.bundleId,
                        firebaseAppId: firebaseAppId,
                        firebaseService: service
                    ),
                    distribution: .adhoc
                )
            ) {
                context.metadata["firebase_version"] = buildInfo.version
                context.metadata["firebase_build_number"] = buildInfo.buildNumber
                Log("🟢 Retrieved Firebase build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)".green)
            }
        }
    }

    func prebuild(context: inout FlowContext) async throws {
        AndroidPresetHelpers.bumpVersionCode(
            context: &context,
            remoteVersionCode: context.metadata["firebase_build_number"],
            sourceLabel: "Firebase"
        )
    }

    func build(context: inout FlowContext) async throws {
        try await AndroidPresetHelpers.build(context: &context, format: context.androidFormat ?? .apk)
    }

    func release(context: inout FlowContext) async throws {
        let format = context.androidFormat ?? .apk
        try await FirebasePresetHelpers.distribute(
            context: &context,
            presetName: name,
            artifactExtension: format.rawValue,
            artifactLabel: format.rawValue.uppercased(),
            appIdKey: "FIREBASE_ANDROID_APP_ID"
        )
    }
}
