import AppleServices
import Foundation
import GoogleServices
import Rainbow

/// Preconfigured preset for building and distributing iOS Ad-Hoc releases.
struct IOSAdHocPreset: FlowPreset {
    let name: String = "iOS AdHoc"
    let description: String = "Automated iOS release flow configured for Ad-Hoc distribution."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("MATCH_GIT_URL", context.matchGitUrl, "Match Git repository URL"),
                ("MATCH_PASSWORD", context.matchPassword, "Match encryption password"),
                ("FIREBASE_IOS_APP_ID", context.firebaseAppId, "Firebase iOS App ID"),
                ("GOOGLE_KEY", context.googleKey, "Google Service Account key for Firebase"),
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 Validating iOS environment, signing identities, and Ad-Hoc profiles...".dim)

        let appIdentifiers = try await IOSPresetHelpers.setupIOSProject(context: &context)

        guard context.matchGitUrl != nil, context.matchPassword != nil else {
            return
        }

        try await IOSPresetHelpers.syncMatch(
            context: &context,
            appIdentifiers: appIdentifiers,
            type: .adhoc,
            label: "Ad-Hoc"
        )

        try await FirebasePresetHelpers.fetchLatestBuild(context: &context, presetName: name, appIdKey: "FIREBASE_IOS_APP_ID")
    }

    func prebuild(context: inout FlowContext) async throws {
        // Next build number = max(latest Firebase build, project build number) + 1.
        try IOSPresetHelpers.prepareSigningAndBuildNumber(
            context: &context,
            remoteBuildNumber: context.metadata["firebase_build_number"],
            sourceLabel: "Firebase"
        )
    }

    func build(context: inout FlowContext) async throws {
        try await IOSPresetHelpers.build(context: &context, exportMethod: .adHoc, label: "Ad-Hoc")
    }

    func release(context: inout FlowContext) async throws {
        try await FirebasePresetHelpers.distribute(
            context: &context,
            presetName: name,
            artifactExtension: "ipa",
            artifactLabel: "Ad-Hoc IPA",
            appIdKey: "FIREBASE_IOS_APP_ID"
        )
    }
}
