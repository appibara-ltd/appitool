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

        // 1. Initial fast regex inspection
        if let identifiers = try? AndroidTasks.getAndroidIdentifiers(workspaceRoot: context.projectDirectory) {
            context.bundleId ??= identifiers.packageName
            if let versionName = identifiers.versionName {
                context.version ??= versionName
                // Log("   • Detected project versionName: \(versionName.bold)".dim)
            }
            if let versionCode = identifiers.versionCode {
                context.buildNumber ??= versionCode
                // Log("   • Detected project versionCode: \(versionCode.bold)".dim)
            }
            if let ns = identifiers.namespace {
                context.metadata["android_namespace"] = ns
            }
            if let appId = identifiers.applicationId {
                context.metadata["android_application_id"] = appId
            }
            if !identifiers.flavors.isEmpty {
                context.androidFlavors = identifiers.flavors
                context.metadata["android_flavors"] = identifiers.flavors.map(\.name).joined(separator: ", ")
            }
        }

        // 2. Evaluate dynamically via Gradle for exact runtime values (package, namespace, version, flavors)
        if let evaluated = try? await AndroidTasks.evaluateAppInfoViaGradle(workspaceRoot: context.projectDirectory, offline: true) {
            context.bundleId ??= evaluated.packageName ?? evaluated.applicationId
            context.version ??= evaluated.versionName
            context.buildNumber ??= evaluated.versionCode

            if let pkg = evaluated.packageName {
                context.metadata["android_package_name"] = pkg
            }
            if let appId = evaluated.applicationId {
                context.metadata["android_application_id"] = appId
            }
            if let ns = evaluated.namespace {
                context.metadata["android_namespace"] = ns
            }
            if let vn = evaluated.versionName {
                context.metadata["android_version_name"] = vn
                Log("   • Evaluated Gradle versionName: \(vn.bold)".dim)
            }
            if let vc = evaluated.versionCode {
                context.metadata["android_version_code"] = vc
                Log("   • Evaluated Gradle versionCode: \(vc.bold)".dim)
            }
            if !evaluated.flavors.isEmpty {
                context.androidFlavors = evaluated.flavors
                let flavorsList = evaluated.flavors.map(\.name).joined(separator: ", ")
                context.metadata["android_flavors"] = flavorsList
                Log("   • Evaluated Gradle flavors: \(flavorsList.bold)".dim)
            }
        }

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
        Log("🔨 Running Gradle bundleRelease to produce Android App Bundle (AAB)...".dim)

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
        let targetRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".appitool")
            .appendingPathComponent("android")
            .appendingPathComponent(targetName)
        let buildRoot = targetRoot.appendingPathComponent("build")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy_MM_dd_HH_mm"
        let timestamp = formatter.string(from: Date())
        let outputDir = buildRoot.appendingPathComponent(timestamp).path
        let artifactName = "\(targetName)_release"

        let output = try await GradleTask().run(
            .init(
                projectDirectory: projectDir,
                buildType: "release",
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

    func postbuild(context: inout FlowContext) async throws {
        Log("📦 Verifying generated .aab bundle integrity...".dim)
        guard let aabUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == "aab" })
            ?? context.metadata["aab_path"].map({ URL(fileURLWithPath: $0) }) else {
            return
        }
        if FileManager.default.fileExists(atPath: aabUrl.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: aabUrl.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            Log("   ✓ Verified AAB artifact: \(aabUrl.lastPathComponent) (\(formattedSize))".dim)
        }
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("📝 Preparing internal track release notes...".dim)
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
                releaseNotes: context.changelog
            )
        )

        context.metadata["googleplay_edit_id"] = result.editId
        context.metadata["googleplay_version_code"] = String(result.versionCode)
        context.metadata["googleplay_track"] = result.track

        Log("✅ Uploaded \(aabUrl.lastPathComponent) to Google Play Console (Track: \(result.track.bold), VersionCode: \(String(result.versionCode).bold))".green.bold)
    }
}
