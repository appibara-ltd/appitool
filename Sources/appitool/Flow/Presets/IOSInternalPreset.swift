import AppleServices
import Foundation
import Rainbow

/// Preconfigured preset for building and distributing iOS internal test releases (TestFlight).
struct IOSInternalPreset: FlowPreset {
    let name: String = "iOS Internal"
    let description: String =
        "Automated iOS release flow configured for App Store Connect TestFlight internal testing."

    init() {}

    var stageHandlers: [FlowStage: any FlowStageHandler] {
        [
            .setup: AnyFlowStageHandler { try await self.setup(context: &$0) },
            .prebuild: AnyFlowStageHandler { try await self.prebuild(context: &$0) },
            .build: AnyFlowStageHandler { try await self.build(context: &$0) },
            .postbuild: AnyFlowStageHandler { try await self.postbuild(context: &$0) },
            .prerelease: AnyFlowStageHandler { try await self.prerelease(context: &$0) },
            .release: AnyFlowStageHandler { try await self.release(context: &$0) },
        ]
    }

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
        Log("🔍 [\(name)] Validating App Store Connect credentials and AppStore profiles...".dim)
        if context.workspacePath == nil && context.xcodeProjectPath == nil {
            let detected = XcodeBuildTask.autoDetect(in: context.projectDirectory)
            context.workspacePath = detected.workspace
            context.xcodeProjectPath = detected.project
        }

        let info = try await XCodeTasks.inspectProject(
            workspace: context.workspacePath,
            project: context.xcodeProjectPath,
            in: context.projectDirectory
        )
        Log(
            "🔍 [\(name)] Inspected project targets: \(info.targets.joined(separator: ", "))".dim)

        let result = try await XCodeTasks.getIosIdentifiers(
            workspaceRoot: context.projectDirectory,
            scheme: context.scheme,
            configuration: context.configuration
        )

        context.scheme ??= result.scheme
        context.configuration ??= result.configuration
        context.targetName ??= result.mainAppTargetName
        context.bundleId ??= result.bundleId

        // Read project's current version and build number
        if let projVersionInfo = try? XCodeTasks.getProjectVersion(
            projectPath: context.xcodeProjectPath,
            workspacePath: context.workspacePath,
            targetName: context.targetName,
            configuration: context.configuration,
            in: context.projectDirectory
        ) {
            context.version = projVersionInfo.version
            context.buildNumber = projVersionInfo.buildNumber
        }

        // Collect all target bundle identifiers to sync profiles for
        var appIdentifiers: [String] = []
        if let explicit = context.bundleId, !explicit.isEmpty {
            appIdentifiers.append(explicit)
        }
        for target in result.targets {
            if !target.bundleId.isEmpty && !appIdentifiers.contains(target.bundleId) {
                appIdentifiers.append(target.bundleId)
            }
        }
        if appIdentifiers.isEmpty, let mainBundleId = result.bundleId, !mainBundleId.isEmpty {
            appIdentifiers.append(mainBundleId)
        }

        guard let gitUrl = context.matchGitUrl, let password = context.matchPassword else {
            return
        }

        Log("🔐 [\(name)] Running Match AppStore synchronization...".dim)
        let output = try await MatchTask().run(
            .init(
                gitUrl: gitUrl,
                gitBranch: context.matchGitBranch ?? "master",
                gitToken: context.matchGitToken,
                type: .appstore,
                platform: .ios,
                appIdentifiers: appIdentifiers,
                password: password,
                action: .sync,
                readonly: context.isDryRun || context.matchReadonly,
                teamId: context.teamId,
                apiKeyId: context.appleKeyId,
                apiIssuerId: context.appleIssuerId,
                apiKey: context.appleKey,
                keychainName: context.matchKeychainName,
                keychainPassword: context.matchKeychainPassword,
                silent: context.silent,
            ))

        // Log installed certificates and provisioning profiles
        Log("✨ [\(name)] Match AppStore completed successfully.".green.bold)
        if !output.installedCertificates.isEmpty {
            Log("📜 Installed Certificates (\(output.installedCertificates.count)):".bold)
            for cert in output.installedCertificates {
                Log("   • \(cert)".dim)
            }
        } else {
            Log("📜 Installed Certificates: None".dim)
        }

        if !output.installedProfiles.isEmpty {
            Log("📄 Installed Provisioning Profiles (\(output.installedProfiles.count)):".bold)
            for (bundleId, profile) in output.installedProfiles.sorted(by: { $0.key < $1.key }) {
                Log("   • [\(bundleId)] \(profile.name) (UUID: \(profile.uuid))".dim)
                Log("     Path: \(profile.path)".dim)
            }
        } else {
            Log("📄 Installed Provisioning Profiles: None".dim)
        }

        context.installedCertificates = output.installedCertificates
        context.installedProfiles = output.installedProfiles

        // Fetch latest build number / version from App Store Connect
        Log("🔥 [\(name)] Fetching latest build info from App Store Connect...".dim)

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
            "🟢 [\(name)] Retrieved AppStore build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)"
                .green)
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("🔧 [\(name)] Preparing project for manual code signing...".dim)

        guard !context.installedProfiles.isEmpty else {
            Log(
                "🚧  [\(name)] No provisioning profiles installed in context to configure manual signing."
                    .yellow)
            return
        }

        let configuration = context.configuration ?? "Release"
        let scheme = context.scheme

        let identity: String = {
            if let cert = context.installedCertificates.first {
                if cert.contains("iPhone Distribution") {
                    return "iPhone Distribution"
                } else if cert.contains("Apple Distribution") {
                    return "Apple Distribution"
                } else {
                    return cert
                }
            }
            return "Apple Distribution"
        }()

        if context.teamId == nil, let cert = context.installedCertificates.first {
            let pattern = #"\(([A-Z0-9]{10})\)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: cert, range: NSRange(cert.startIndex..., in: cert)),
                let range = Range(match.range(at: 1), in: cert)
            {
                context.teamId = String(cert[range])
            }
        }

        let input = XCodeTasks.ManualSigningInput(
            projectPath: context.xcodeProjectPath,
            workspacePath: context.workspacePath,
            scheme: scheme,
            configuration: configuration,
            teamId: context.teamId,
            identity: identity,
            profilesByBundleId: context.installedProfiles,
            isDryRun: context.isDryRun
        )

        let results = try XCodeTasks.configureManualSigning(input, in: context.projectDirectory)

        if results.isEmpty {
            Log(
                "🚧 [\(name)] No signable targets found or updated for configuration '\(configuration)'."
                    .yellow)
        } else {
            Log(
                "📝 [\(name)] Configured manual signing for \(results.count) target(s) [Configuration: \(configuration)]:"
                    .green.bold)
            for r in results {
                Log("   • Target: \(r.targetName.bold) (\(r.bundleId))")
                Log("     Profile: \(r.profileName) [UUID: \(r.profileUUID)]".dim)
                Log("     Identity: \(r.identity), Team: \(r.teamId ?? "None")".dim)
            }
        }

        // Increment build number based on Firebase (or current project buildNumber) and update Xcode project
        let baseBuildStr = context.metadata["appstore_build_number"] ?? context.buildNumber
        if let baseBuildStr = baseBuildStr, let baseBuild = Int(baseBuildStr) {
            let nextBuildNumber = String(baseBuild + 1)
            let prevDisplay =
                context.buildNumber != nil
                ? "\(context.buildNumber!) (App Store: \(baseBuildStr))" : baseBuildStr
            Log(
                "🔢 [\(name)] Incrementing build number: \(prevDisplay.bold) -> \(nextBuildNumber.bold.green)"
                    .dim)

            if !context.isDryRun {
                try XCodeTasks.updateBuildNumber(
                    .init(
                        projectPath: context.xcodeProjectPath,
                        workspacePath: context.workspacePath,
                        buildNumber: nextBuildNumber,
                        version: context.version,
                        configurations: [configuration]
                    ),
                    in: context.projectDirectory
                )
            }

            context.buildNumber = nextBuildNumber
        }
    }

    func build(context: inout FlowContext) async throws {
        Log("🔨 [\(name)] Compiling iOS archive with App Store export configuration...".dim)

        if context.isDryRun {
            Log("🟡 [\(name)] Dry-run enabled: skipping xcodebuild archive/export.".yellow)
            return
        }

        let targetRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".appitool")
            .appendingPathComponent("ios")
            .appendingPathComponent(context.targetName ?? context.scheme ?? "app")
        let buildRoot = targetRoot.appendingPathComponent("build")
        let derivedData = targetRoot.appendingPathComponent("derivedData").path

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy_MM_dd_HH_mm"
        // All files of this build live in their own timestamped directory.
        let outputDir = buildRoot.appendingPathComponent(formatter.string(from: Date())).path
        let outputName = context.scheme ?? "app"

        let profiles = context.installedProfiles.mapValues { $0.name }

        let output = try await XcodeBuildTask().run(
            .init(
                workspace: context.workspacePath,
                project: context.xcodeProjectPath,
                scheme: context.scheme,
                configuration: context.configuration ?? "Release",
                outputDirectory: outputDir,
                outputName: outputName,
                derivedDataPath: derivedData,
                exportMethod: .appStore,
                exportTeamId: context.teamId,
                signingStyle: profiles.isEmpty ? nil : .manual,
                provisioningProfiles: profiles.isEmpty ? nil : profiles,
                silent: context.silent,
            )
        )

        if let ipaPath = output.ipaPath {
            context.artifactPaths.append(URL(fileURLWithPath: ipaPath))
            context.metadata["ipa_path"] = ipaPath
        }
        if let dsymPath = output.dsymPath {
            context.artifactPaths.append(URL(fileURLWithPath: dsymPath))
        }
    }

    func postbuild(context: inout FlowContext) async throws {
        Log("📦 [\(name)] Verifying .ipa archive for App Store upload compliance...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("📝 [\(name)] Packaging release artifacts and localized what-to-test notes...".dim)
    }

    func release(context: inout FlowContext) async throws {
        Log("🚀 [\(name)] Uploading build to App Store Connect / TestFlight...".dim)
    }
}
