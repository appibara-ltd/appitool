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

        guard let googleKey = context.googleKey, !googleKey.isEmpty else { return }
        guard let packageName = context.bundleId, !packageName.isEmpty else { return }

        // 3. Resolve signing keystore via Match if available
        if context.androidSigningConfig == nil,
           let gitUrl = context.matchGitUrl,
           let password = context.matchPassword {
            Log("🔐 Resolving Android release keystore from Match storage...".dim)
            let matchConfig = MatchAndroidConfig(
                gitUrl: gitUrl,
                gitBranch: context.matchGitBranch ?? "master",
                gitToken: context.matchGitToken,
                password: password,
                action: .sync,
                packageName: packageName,
                buildType: .release,
                silent: context.silent
            )
            if let result = try? await MatchRunner().runAndroid(matchConfig) {
                context.androidSigningConfig = result.signingConfig
                context.androidSigningTempUrl = result.tempUrl
                Log("   ✓ Resolved signing keystore for '\(packageName)' from Match".green)
            }
        }

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
        Log("🔧 Resolving latest Google Play versionCode and bumping build...".dim)
        let baseCodeStr = context.metadata["googleplay_version_code"] ?? context.buildNumber
        if let baseCodeStr, let baseCode = Int(baseCodeStr) {
            let nextCode = String(baseCode + 1)
            Log("🔢 Incrementing versionCode: \(baseCodeStr.bold) -> \(nextCode.bold.green)".dim)
            context.buildNumber = nextCode
        }
    }

    func build(context: inout FlowContext) async throws {
        let taskName = GradleTask.resolveTaskName(format: .aab, buildType: "release", flavor: context.androidFlavor)
        Log("🔨 Running Gradle \(taskName) to produce Android App Bundle (AAB)...".dim)

        if context.isDryRun {
            Log("🟡 Dry-run enabled: skipping Gradle build.".yellow)
            return
        }

        let projectDir = AndroidTasks.findAndroidRoot(in: context.projectDirectory)?.path ?? context.projectDirectory.path

        var properties: [String: String] = [:]
        if let versionCode = context.buildNumber {
            properties["versionCode"] = versionCode
        }
        if let versionName = context.version {
            properties["versionName"] = versionName
        }

        let targetName = context.targetName ?? context.bundleId ?? "AndroidApp"
        let outputDir = AppitoolPaths.buildDirectory(platform: "android", target: targetName, name: context.buildDirectoryName).path
        let artifactName = AndroidPresetHelpers.artifactName(targetName: targetName, flavor: context.androidFlavor)

        let output = try await GradleTask().run(
            .init(
                projectDirectory: projectDir,
                buildType: "release",
                flavor: context.androidFlavor,
                format: .aab,
                outputDirectory: outputDir,
                artifactName: artifactName,
                signing: context.androidSigningConfig,
                properties: properties,
                silent: context.silent
            )
        )

        if let aabPath = output.aabPath {
            let aabUrl = URL(fileURLWithPath: aabPath)
            context.artifactPaths.append(aabUrl)
            context.metadata["aab_path"] = aabPath
            Log("📦 Produced Android App Bundle: \(aabUrl.lastPathComponent)".green.bold)
        }
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
