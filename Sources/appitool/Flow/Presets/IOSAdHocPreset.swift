import Foundation
import GoogleServices
import Rainbow

/// Preconfigured preset for building and distributing iOS Ad-Hoc releases.
struct IOSAdHocPreset: FlowPreset {
    let name: String = "iOS AdHoc"
    let description: String = "Automated iOS release flow configured for Ad-Hoc distribution."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements([
            ("MATCH_GIT_URL", context.matchGitUrl, "Match Git repository URL"),
            ("MATCH_PASSWORD", context.matchPassword, "Match encryption password"),
            ("FIREBASE_IOS_APP_ID", context.firebaseAppId, "Firebase iOS App ID"),
            ("GOOGLE_KEY", context.googleKey, "Google Service Account key for Firebase"),
        ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log(
            "   🔍 [\(name)] Validating iOS environment, signing identities, and Match Ad-Hoc profiles..."
                .dim)

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
            "   🔍 [\(name)] Inspected project targets: \(info.targets.joined(separator: ", "))".dim)

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

        Log("   🔐 [\(name)] Running Match Ad-Hoc synchronization...".dim)
        Log.depth += 3
        let task = MatchTask()
        let output = try await task.run(
            MatchTask.Input(
                gitUrl: gitUrl,
                gitBranch: context.matchGitBranch ?? "master",
                gitToken: context.matchGitToken,
                type: .adhoc,
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
                keychainPassword: context.matchKeychainPassword
            ))
        Log.depth -= 3

        // Log installed certificates and provisioning profiles
        Log("   ✨ [\(name)] Match Ad-Hoc completed successfully.".green.bold)
        if !output.installedCertificates.isEmpty {
            Log("   📜 Installed Certificates (\(output.installedCertificates.count)):".bold)
            for cert in output.installedCertificates {
                Log("      • \(cert)".dim)
            }
        } else {
            Log("   📜 Installed Certificates: None".dim)
        }

        if !output.installedProfiles.isEmpty {
            Log("   📄 Installed Provisioning Profiles (\(output.installedProfiles.count)):".bold)
            for (bundleId, profile) in output.installedProfiles.sorted(by: { $0.key < $1.key }) {
                Log("      • [\(bundleId)] \(profile.name) (UUID: \(profile.uuid))".dim)
                Log("        Path: \(profile.path)".dim)
            }
        } else {
            Log("   📄 Installed Provisioning Profiles: None".dim)
        }

        context.installedCertificates = output.installedCertificates
        context.installedProfiles = output.installedProfiles

        // Fetch latest build number / version from Firebase App Distribution
        Log("   🔥 [\(name)] Fetching latest build info from Firebase App Distribution...".dim)
        guard let firebaseAppId = context.firebaseAppId,
              let googleKey = context.googleKey,
              let firebaseService = try FirebaseService.makeService(googleKey: googleKey) else {
            return
        }

        Log.depth += 3
        let buildTask = GetLatestBuildNumberTask()
        let buildInfo = try await buildTask.run(
            GetLatestBuildNumberTask.Input(
                target: .ios(
                    bundleId: context.bundleId,
                    firebaseAppId: firebaseAppId,
                    firebaseService: firebaseService
                ),
                distribution: .adhoc
            )
        )
        Log.depth -= 3

        context.metadata["firebase_version"] = buildInfo.version
        context.metadata["firebase_build_number"] = buildInfo.buildNumber

        Log("   ✓ [\(name)] Retrieved Firebase build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)".green)
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("   🔧 [\(name)] Preparing project for manual code signing...".dim)

        guard !context.installedProfiles.isEmpty else {
            Log("   ⚠️  [\(name)] No provisioning profiles installed in context to configure manual signing.".yellow)
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
               let match = regex.firstMatch(in: cert, range: NSRange(cert.startIndex..., in: cert)),
               let range = Range(match.range(at: 1), in: cert) {
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
            Log("   ⚠️  [\(name)] No signable targets found or updated for configuration '\(configuration)'.".yellow)
        } else {
            Log("   ✍️  [\(name)] Configured manual signing for \(results.count) target(s) [Configuration: \(configuration)]:".green.bold)
            for r in results {
                Log("      • Target: \(r.targetName.bold) (\(r.bundleId))")
                Log("        Profile: \(r.profileName) [UUID: \(r.profileUUID)]".dim)
                Log("        Identity: \(r.identity), Team: \(r.teamId ?? "None")".dim)
            }
        }

        // Increment build number based on Firebase (or current project buildNumber) and update Xcode project
        let baseBuildStr = context.metadata["firebase_build_number"] ?? context.buildNumber
        if let baseBuildStr = baseBuildStr, let baseBuild = Int(baseBuildStr) {
            let nextBuildNumber = String(baseBuild + 1)
            let prevDisplay = context.buildNumber != nil ? "\(context.buildNumber!) (Firebase: \(baseBuildStr))" : baseBuildStr
            Log("   🔢 [\(name)] Incrementing build number: \(prevDisplay.bold) -> \(nextBuildNumber.bold.green)".dim)

            if !context.isDryRun {
                try XCodeTasks.updateBuildNumber(
                    XCodeTasks.UpdateBuildNumberInput(
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
        Log("   🔨 [\(name)] Compiling iOS application with Ad-Hoc export configuration...".dim)
    }

    func postbuild(context: inout FlowContext) async throws {
        Log("   📦 [\(name)] Verifying generated .ipa package and signature...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("   📝 [\(name)] Preparing release packaging and tester release notes...".dim)
    }

    func release(context: inout FlowContext) async throws {
        Log("   🚀 [\(name)] Distributing Ad-Hoc build to testers...".dim)
    }
}
