import Foundation
import GoogleServices
import Rainbow

/// Preconfigured preset for building and distributing Android App Bundles (AAB) to Google Play Internal track.
struct AndroidInternalPreset: FlowPreset {
    let name: String = "Android Internal"
    let description: String =
        "Automated Android release flow configured for Google Play Console internal testing."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("GOOGLE_KEY", context.googleKey, "Google Service Account JSON key")
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 Validating Google Play API service account and project setup...".dim)

        try await AndroidPresetHelpers.setupAndroidProject(context: &context)

        // Resolve the release keystore via Match when configured (fails loudly on errors)
        try await AndroidPresetHelpers.resolveMatchKeystore(context: &context)

        guard let googleKey = context.googleKey, !googleKey.isEmpty else { return }
        guard let packageName = context.bundleId, !packageName.isEmpty else { return }

        if let service = try? GooglePlayService(key: googleKey) {
            if let buildInfo = try? await GetLatestBuildNumberTask().run(
                .init(
                    target: .android(
                        packageName: packageName,
                        service: service,
                        track: "internal"
                    ),
                    distribution: .appstore
                )
            ) {
                context.metadata["googleplay_version"] = buildInfo.version
                context.metadata["googleplay_version_code"] = buildInfo.buildNumber
                Log("🟢 Retrieved Google Play build info: Version: \(buildInfo.version.bold), VersionCode: \(buildInfo.buildNumber.bold)".green)
            }
        }
    }

    func prebuild(context: inout FlowContext) async throws {
        AndroidPresetHelpers.bumpVersionCode(
            context: &context,
            remoteVersionCode: context.metadata["googleplay_version_code"],
            sourceLabel: "Google Play"
        )
    }

    func build(context: inout FlowContext) async throws {
        // Google Play requires an App Bundle (`flow android -d appstore --format apk` is rejected up front).
        try await AndroidPresetHelpers.build(context: &context, format: .aab)
    }

    func release(context: inout FlowContext) async throws {
        Log("🚀 Publishing AAB to Google Play Internal track...".dim)

        guard let aabUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == "aab" })
            ?? context.metadata["aab_path"].map({ URL(fileURLWithPath: $0) }) else {
            Log("🚧 No .aab package found in context artifacts to upload.".yellow)
            return
        }

        if context.isDryRun {
            Log("🟡 Dry-run enabled: would upload \(aabUrl.lastPathComponent) to Google Play Console (internal track).".yellow)
            return
        }

        guard let googleKey = context.googleKey, !googleKey.isEmpty else {
            throw FlowRequirementError(presetName: name, missing: ["GOOGLE_KEY"])
        }

        let service = try GooglePlayService(key: googleKey)

        let releaseName: String? = {
            if let version = context.version {
                return "\(version)"
            }
            return nil
        }()

        let result = try await UploadToGooglePlayConsoleTask().run(
            .init(
                binaryPath: aabUrl.path,
                service: service,
                packageName: context.bundleId,
                track: "internal",
                releaseStatus: .completed,
                releaseName: releaseName,
                releaseNotes: context.changelog,
                releaseNotesLanguage: context.releaseNotesLocale
            )
        )

        context.buildNumber = String(result.versionCode)
        context.metadata["googleplay_edit_id"] = result.editId
        context.metadata["googleplay_version_code"] = String(result.versionCode)
        context.metadata["googleplay_track"] = result.track

        Log("✅ Uploaded \(aabUrl.lastPathComponent) to Google Play Console (Track: \(result.track.bold), VersionCode: \(String(result.versionCode).bold))".green.bold)
    }
}
