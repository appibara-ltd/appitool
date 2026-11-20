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

        guard let gitUrl = context.matchGitUrl, let password = context.matchPassword else {
            return
        }

        Log("🔐 Running Match AppStore synchronization...".dim)
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
        Log("✨ Match AppStore completed successfully.".green.bold)
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

        try IOSPresetHelpers.backupProjectPbxproj(context: context)

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

        // Compute next build number based on App Store Connect (or current project buildNumber) and normalize Info.plist if needed
        let baseBuildStr = context.metadata["appstore_build_number"] ?? context.buildNumber
        try IOSPresetHelpers.prepareIOSBuildNumber(
            context: &context,
            baseBuildStr: baseBuildStr,
            sourceLabel: "App Store",
            configuration: configuration
        )
    }

    func build(context: inout FlowContext) async throws {
        Log("🔨 Compiling iOS archive with App Store export configuration...".dim)

        if context.isDryRun {
            Log("🟡 Dry-run enabled: skipping xcodebuild archive/export.".yellow)
            return
        }

        defer {
            IOSPresetHelpers.restoreTemporaryFiles(context: context)
        }

        let target = context.targetName ?? context.scheme ?? "app"
        let outputDir = AppitoolPaths.buildDirectory(platform: "ios", target: target).path
        let derivedData = AppitoolPaths.iosDerivedDataDirectory(target: target).path
        let outputName = context.scheme ?? "app"

        let profiles = context.installedProfiles.mapValues { $0.name }

        #if os(macOS)
        let kcName = context.matchKeychainName ?? "appitool"
        let kcPass = context.matchKeychainPassword ?? "appipass"
        let kcManager = AppleServices.KeychainManager(keychainName: kcName, keychainPassword: kcPass)
        try? await kcManager.prepareKeychainIfNeeded()
        #endif

        let output = try await XcodeBuildTask().run(
            .init(
                workspace: context.workspacePath,
                project: context.xcodeProjectPath,
                scheme: context.scheme,
                configuration: context.configuration ?? "Release",
                outputDirectory: outputDir,
                outputName: outputName,
                derivedDataPath: derivedData,
                buildNumber: context.buildNumber,
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
