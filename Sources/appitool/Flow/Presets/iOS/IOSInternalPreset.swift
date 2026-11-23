import AppleServices
import Foundation
import Rainbow

/// Preconfigured preset for building and distributing iOS internal test releases (TestFlight).
struct IOSInternalPreset: FlowPreset {
    let name: String = "iOS Internal"
    let description: String =
        "Automated iOS release flow configured for App Store Connect TestFlight internal testing."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("APPLE_KEY_ID", context.appleKeyId, "App Store Connect Key ID"),
                ("APPLE_ISSUER_ID", context.appleIssuerId, "App Store Connect Issuer ID"),
                ("APPLE_KEY", context.appleKey, "App Store Connect API key (.p8/base64)"),
                ("MATCH_GIT_URL", context.matchGitUrl, "Match Git repository URL"),
                ("MATCH_PASSWORD", context.matchPassword, "Match encryption password"),
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 Validating App Store Connect credentials and AppStore profiles...".dim)

        let appIdentifiers = try await IOSPresetHelpers.setupIOSProject(context: &context)

        guard context.matchGitUrl != nil, context.matchPassword != nil else {
            return
        }

        try await IOSPresetHelpers.syncMatch(
            context: &context,
            appIdentifiers: appIdentifiers,
            type: .appstore,
            label: "AppStore"
        )

        // Fetch latest build number / version from App Store Connect
        Log("🔥 Fetching latest build info from App Store Connect...".dim)

        guard let appleKeyId = context.appleKeyId, let appleKey = context.appleKey,
            let appleIssuerId = context.appleIssuerId
        else {
            throw FlowRequirementError(
                presetName: name, missing: ["APPLE_KEY_ID", "APPLE_ISSUER_ID", "APPLE_KEY"])
        }
        let service = try AppStoreService(
            keyId: appleKeyId, issuerId: appleIssuerId, key: appleKey)

        let buildInfo = try await GetLatestBuildNumberTask().run(
            .init(
                target: .ios(
                    bundleId: context.bundleId,
                    service: service
                ),
                distribution: .appstore
            )
        )

        context.metadata["appstore_version"] = buildInfo.version
        context.metadata["appstore_build_number"] = buildInfo.buildNumber

        Log(
            "🟢 Retrieved AppStore build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)"
                .green)
    }

    func prebuild(context: inout FlowContext) async throws {
        // Next build number = max(latest App Store Connect build, project build number) + 1.
        try IOSPresetHelpers.prepareSigningAndBuildNumber(
            context: &context,
            remoteBuildNumber: context.metadata["appstore_build_number"],
            sourceLabel: "App Store"
        )
    }

    func build(context: inout FlowContext) async throws {
        try await IOSPresetHelpers.build(context: &context, exportMethod: .appStore, label: "App Store")
    }

    func release(context: inout FlowContext) async throws {
        Log("🚀 Uploading build to App Store Connect / TestFlight...".dim)

        // Use the IPA path tracked from the build stage
        guard
            let ipaUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == "ipa" })
                ?? context.metadata["ipa_path"].map({ URL(fileURLWithPath: $0) })
        else {
            Log("🚧 No .ipa package found in context artifacts to upload.".yellow)
            return
        }

        if context.isDryRun {
            Log("🟡 Dry-run enabled: would upload \(ipaUrl.lastPathComponent) to App Store Connect.".yellow)
            return
        }

        guard let appleKeyId = context.appleKeyId, let appleKey = context.appleKey,
            let appleIssuerId = context.appleIssuerId
        else {
            throw FlowRequirementError(
                presetName: name, missing: ["APPLE_KEY_ID", "APPLE_ISSUER_ID", "APPLE_KEY"])
        }
        let service = try AppStoreService(
            keyId: appleKeyId, issuerId: appleIssuerId, key: appleKey)

        let uploadChangelog: String?
        if context.waitForProcessing {
            uploadChangelog = context.changelog
        } else {
            if context.changelog != nil {
                Log("🟡 Skipping App Store Connect processing wait (--no-wait-processing); TestFlight release notes will not be applied.".yellow)
            }
            uploadChangelog = nil
        }

        // Version and build number are read from the IPA's Info.plist (the values Apple validates).
        let result = try await UploadToAppStoreTask().run(
            .init(
                ipaPath: ipaUrl.path,
                service: service,
                bundleId: context.bundleId,
                changelog: uploadChangelog,
                changelogLocale: context.releaseNotesLocale,
                waitForProcessing: context.waitForProcessing
            )
        )

        context.version = result.version
        context.buildNumber = result.buildNumber
        context.metadata["appstore_build_upload_id"] = result.buildUploadId
        context.metadata["appstore_uploaded_version"] = result.version
        context.metadata["appstore_uploaded_build_number"] = result.buildNumber
        if let buildId = result.buildId {
            context.metadata["appstore_build_id"] = buildId
        }

        Log(
            "✅ Uploaded \(result.version.bold) (\(result.buildNumber.bold)) to App Store Connect. State: \(result.state.rawValue)"
                .green.bold)
    }
}
