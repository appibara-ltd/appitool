import Foundation
import Rainbow

/// Shared stage logic for Android presets (Ad-Hoc and Google Play). Each preset only supplies what differs:
/// the remote build-number source, the packaging format, and the release destination.
enum AndroidPresetHelpers {
    // MARK: - Setup: Project detection

    /// Inspects and evaluates Android app info, storing results in `context`.
    static func setupAndroidProject(context: inout FlowContext) async throws {
        let flavor = context.androidFlavor
        let hasExplicitPackageName = (context.bundleId?.isEmpty == false)
        if let flavor {
            Log("   • Selected product flavor: \(flavor.bold)".dim)
        }

        // 1. Fast regex inspection
        if let identifiers = try? AndroidTasks.getAndroidIdentifiers(workspaceRoot: context.projectDirectory) {
            let selected = selectedFlavorDetails(
                flavors: identifiers.flavors,
                flavor: flavor,
                defaultApplicationId: identifiers.packageName,
                defaultVersionName: identifiers.versionName,
                defaultVersionCode: identifiers.versionCode
            )
            context.bundleId ??= selected?.applicationId ?? identifiers.packageName
            context.version ??= selected?.versionName ?? identifiers.versionName
            context.buildNumber ??= selected?.versionCode ?? identifiers.versionCode
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
        var evaluated: AndroidTasks.GradleAppInfo?
        do {
            evaluated = try await AndroidTasks.evaluateAppInfoViaGradle(
                workspaceRoot: context.projectDirectory,
                offline: true,
                flavor: flavor
            )
        } catch {
            if context.version == nil || context.buildNumber == nil || context.bundleId == nil {
                evaluated = try? await AndroidTasks.evaluateAppInfoViaGradle(
                    workspaceRoot: context.projectDirectory,
                    offline: false,
                    flavor: flavor
                )
            }
        }

        if let evaluated {
            // `versionName` / `versionCode` are already flavor-resolved by `evaluateAppInfoViaGradle(flavor:)`.
            let selected = selectedFlavorDetails(
                flavors: evaluated.flavors,
                flavor: flavor,
                defaultApplicationId: evaluated.applicationId,
                defaultVersionName: evaluated.versionName,
                defaultVersionCode: evaluated.versionCode
            )
            if !hasExplicitPackageName, let flavorAppId = selected?.applicationId, !flavorAppId.isEmpty {
                context.bundleId = flavorAppId
            }
            context.bundleId ??= evaluated.packageName ?? evaluated.applicationId
            if let vn = evaluated.versionName, !vn.isEmpty {
                context.version = vn
            }
            if let vc = evaluated.versionCode, !vc.isEmpty {
                context.buildNumber = vc
            }

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

        if let flavor {
            let known = context.androidFlavors
            if known.isEmpty {
                Log("🟡 Product flavor '\(flavor)' was requested but no productFlavors were detected.".yellow)
            } else if !known.contains(where: { $0.name.caseInsensitiveCompare(flavor) == .orderedSame }) {
                let list = known.map(\.name).joined(separator: ", ")
                Log("🟡 Product flavor '\(flavor)' was not found in productFlavors (\(list)).".yellow)
            }
        }
    }

    /// Returns the effective `applicationId`, `versionName`, and `versionCode` for `flavor`, or `nil` when no flavor is selected or matched.
    private static func selectedFlavorDetails(
        flavors: [AndroidTasks.AndroidFlavor],
        flavor: String?,
        defaultApplicationId: String?,
        defaultVersionName: String?,
        defaultVersionCode: String?
    ) -> AndroidTasks.AndroidFlavor? {
        guard let flavor, !flavor.isEmpty else { return nil }
        return AndroidTasks.resolveFlavorDetails(
            flavors: flavors,
            defaultApplicationId: defaultApplicationId,
            defaultVersionName: defaultVersionName,
            defaultVersionCode: defaultVersionCode,
            selectedFlavor: flavor
        ).first
    }

    // MARK: - Setup: Match keystore

    /// Resolves the `release` signing keystore from Match storage into `context.androidSigningConfig`.
    ///
    /// - No-op when a signing config is already set or Match is not configured (`MATCH_GIT_URL` / `MATCH_PASSWORD`).
    /// - Throws when Match is configured but the package name is unknown or the lookup fails, so a flow never
    ///   silently continues to build an unsigned release.
    static func resolveMatchKeystore(context: inout FlowContext) async throws {
        guard context.androidSigningConfig == nil,
              let gitUrl = CLIValues.trimmedNonEmpty(context.matchGitUrl),
              let password = CLIValues.trimmedNonEmpty(context.matchPassword)
        else { return }

        guard let packageName = CLIValues.trimmedNonEmpty(context.bundleId) else {
            throw MatchKeystoreError(
                message: "Match is configured (MATCH_GIT_URL / MATCH_PASSWORD) but the Android package name could not be resolved. Provide --package-name or set GOOGLE_PACKAGE_NAME in .env."
            )
        }

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

        let result: MatchAndroidResult
        do {
            result = try await MatchRunner().runAndroid(matchConfig)
        } catch {
            throw MatchKeystoreError(
                message: "Failed to resolve the release keystore for '\(packageName)' from Match: \(error.localizedDescription)"
            )
        }

        context.androidSigningConfig = result.signingConfig
        context.androidSigningTempUrl = result.tempUrl
        Log("   ✓ Resolved signing keystore for '\(packageName)' from Match".green)
    }

    /// Error raised when a configured Match keystore lookup cannot complete.
    struct MatchKeystoreError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Prebuild: versionCode

    /// Bumps `context.buildNumber` (Android `versionCode`) to `max(remoteVersionCode, project versionCode) + 1`
    /// (see `BuildNumberPolicy`). Leaves it unchanged when neither value is a valid integer.
    static func bumpVersionCode(context: inout FlowContext, remoteVersionCode: String?, sourceLabel: String) {
        Log("🔧 Resolving latest \(sourceLabel) versionCode and bumping build...".dim)
        guard let next = BuildNumberPolicy.next(remote: remoteVersionCode, local: context.buildNumber) else {
            Log("🟡 No valid local or \(sourceLabel) versionCode found; keeping the project versionCode.".yellow)
            return
        }
        Log("🔢 Incrementing versionCode (local: \(context.buildNumber ?? "-"), \(sourceLabel): \(remoteVersionCode ?? "-")): \(String(next.base).bold) -> \(next.value.bold.green)".dim)
        context.buildNumber = next.value
    }

    // MARK: - Build: Gradle

    /// Builds a signed `release` artifact with Gradle, injecting the resolved `versionCode`/`versionName`,
    /// and records it in `context.artifactPaths` and `context.metadata["<format>_path"]`.
    /// Honors `--dry-run` (skips Gradle) and the selected product flavor.
    static func build(context: inout FlowContext, format: GradleTask.BuildFormat) async throws {
        let buildType = "release"
        let label = format.rawValue.uppercased()
        let taskName = GradleTask.resolveTaskName(format: format, buildType: buildType, flavor: context.androidFlavor)
        Log("🔨 Running Gradle \(taskName) to produce \(label)...".dim)

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
        let artifactName = AppitoolPaths.androidArtifactName(target: targetName, flavor: context.androidFlavor, buildType: buildType)

        let output = try await GradleTask().run(
            .init(
                projectDirectory: projectDir,
                buildType: buildType,
                flavor: context.androidFlavor,
                format: format,
                outputDirectory: outputDir,
                artifactName: artifactName,
                signing: context.androidSigningConfig,
                properties: properties,
                silent: context.silent
            )
        )

        if let artifactPath = (format == .aab) ? output.aabPath : output.apkPath {
            let artifactUrl = URL(fileURLWithPath: artifactPath)
            context.artifactPaths.append(artifactUrl)
            context.metadata["\(format.rawValue)_path"] = artifactPath
            Log("📦 Produced Android \(label): \(artifactUrl.lastPathComponent)".green.bold)
        }
    }
}
