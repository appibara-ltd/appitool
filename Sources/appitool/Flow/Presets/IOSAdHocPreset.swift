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
        Log(
            "🔍 Validating iOS environment, signing identities, and Ad-Hoc profiles...".dim
        )

        let appIdentifiers = try await IOSPresetHelpers.setupIOSProject(context: &context)

        guard let gitUrl = context.matchGitUrl, let password = context.matchPassword else {
            return
        }

        Log("🔐 Running Match Ad-Hoc synchronization...".dim)
        let task = MatchTask()
        let output = try await task.run(
            .init(
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
                keychainPassword: context.matchKeychainPassword,
                silent: context.silent,
            ))

        // Log installed certificates and provisioning profiles
        Log("✨ Match Ad-Hoc completed successfully.".green.bold)
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

        // Fetch latest build number / version from Firebase App Distribution
        Log("🔥 Fetching latest build info from Firebase App Distribution...".dim)
        let firebaseAppId = context.firebaseAppId!
        let firebaseService = try FirebaseService(key: context.googleKey!)

        let buildInfo = try await GetLatestBuildNumberTask().run(
            .init(
                target: .ios(
                    bundleId: context.bundleId,
                    firebaseAppId: firebaseAppId,
                    firebaseService: firebaseService
                ),
                distribution: .adhoc
            )
        )

        context.metadata["firebase_version"] = buildInfo.version
        context.metadata["firebase_build_number"] = buildInfo.buildNumber

        Log(
            "🟢 Retrieved Firebase build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)"
                .green)
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("🔧 Preparing project for manual code signing...".dim)

        guard !context.installedProfiles.isEmpty else {
            Log(
                "🚧  No provisioning profiles installed in context to configure manual signing."
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
                "🚧 No signable targets found or updated for configuration '\(configuration)'."
                    .yellow)
        } else {
            Log(
                "📝 Configured manual signing for \(results.count) target(s) [Configuration: \(configuration)]:"
                    .green.bold)
            for r in results {
                Log("   • Target: \(r.targetName.bold) (\(r.bundleId))")
                Log("     Profile: \(r.profileName) [UUID: \(r.profileUUID)]".dim)
                Log("     Identity: \(r.identity), Team: \(r.teamId ?? "None")".dim)
            }
        }

        // Increment build number based on Firebase (or current project buildNumber) and update Xcode project
        let baseBuildStr = context.metadata["firebase_build_number"] ?? context.buildNumber
        if let baseBuildStr = baseBuildStr, let baseBuild = Int(baseBuildStr) {
            let nextBuildNumber = String(baseBuild + 1)
            let prevDisplay =
                context.buildNumber != nil
                ? "\(context.buildNumber!) (Firebase: \(baseBuildStr))" : baseBuildStr
            Log(
                "🔢 Incrementing build number: \(prevDisplay.bold) -> \(nextBuildNumber.bold.green)"
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
        Log("🔨 Compiling iOS application with Ad-Hoc export configuration...".dim)

        if context.isDryRun {
            Log("🟡 Dry-run enabled: skipping xcodebuild archive/export.".yellow)
            return
        }

        let target = context.targetName ?? context.scheme ?? "app"
        let outputDir = AppitoolPaths.buildDirectory(platform: "ios", target: target).path
        let derivedData = AppitoolPaths.iosDerivedDataDirectory(target: target).path
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
                exportMethod: .adHoc,
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
        Log("📦 Verifying generated .ipa package and signature...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("📝 Preparing release packaging and tester release notes...".dim)
    }

    func release(context: inout FlowContext) async throws {
        Log("🚀 Distributing Ad-Hoc build to testers via Firebase App Distribution...".dim)

        context.metadata["firebase_test_groups"] = "internal"
        context.changelog = "APPITOOL TEST"

        let firebaseAppId = context.firebaseAppId!
        let firebaseService = try FirebaseService(key: context.googleKey!)

        // Read .ipa binary directly from context
        guard
            let ipaUrl = context.artifactPaths.first(where: {
                $0.pathExtension.lowercased() == "ipa"
            })
                ?? context.metadata["ipa_path"].map({ URL(fileURLWithPath: $0) })
        else {
            Log("🚧 No .ipa package found in context artifacts to upload.".yellow)
            return
        }

        if context.isDryRun {
            Log(
                "🟡 Dry-run enabled: would upload \(ipaUrl.lastPathComponent) to Firebase App Distribution (\(firebaseAppId))."
                    .yellow)
            return
        }

        let releaseNotes = context.changelog ?? context.metadata["release_notes"]
        let testGroups: [String]? = {
            if let groupsStr = context.metadata["firebase_test_groups"]
                ?? context.metadata["test_groups"]
            {
                return groupsStr.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            return nil
        }()

        let testerEmails: [String]? = {
            if let emailsStr = context.metadata["firebase_tester_emails"]
                ?? context.metadata["tester_emails"]
            {
                return emailsStr.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            return nil
        }()

        // Ensure configured test groups exist before upload and resolve their actual aliases
        var resolvedTestGroups: [String] = []
        if let testGroups, !testGroups.isEmpty {
            for group in testGroups {
                let g = try await firebaseService.createOrGetGroup(
                    project: firebaseAppId,
                    groupAlias: group
                )
                // Use the group's actual alias from its resource name (projects/.../groups/{alias}) or fallback to group
                let alias = g.name?.components(separatedBy: "/").last ?? group
                resolvedTestGroups.append(alias)
            }
        }

        let result = try await UploadToFirebaseTask().run(
            .init(
                binaryPath: ipaUrl.path,
                firebaseAppId: firebaseAppId,
                service: firebaseService,
                releaseNotes: releaseNotes,
                testGroups: resolvedTestGroups.isEmpty ? testGroups : resolvedTestGroups,
                testerEmails: testerEmails
            )
        )

        context.metadata["firebase_release_name"] = result.releaseName
        if let consoleUri = result.firebaseConsoleUri {
            context.metadata["firebase_console_uri"] = consoleUri
            Log("🔗 Firebase Console: \(consoleUri)".cyan)
        }
        if let downloadUri = result.binaryDownloadUri {
            context.metadata["firebase_download_uri"] = downloadUri
        }
        if let testingUri = result.testingUri {
            context.metadata["firebase_testing_uri"] = testingUri
        }

        Log("🟢 Successfully distributed build to Firebase App Distribution!".green.bold)
    }
}
