import AppleServices
import Foundation
import Rainbow

/// Shared stage logic for iOS presets (Ad-Hoc and App Store). Each preset only supplies what differs:
/// the Match profile type, the remote build-number source, and the export method.
enum IOSPresetHelpers {
    // MARK: - Setup: Project detection

    /// Detects Xcode project/workspace and populates target, scheme, version, and bundle ID into `context`.
    /// Returns every target bundle identifier to sync provisioning profiles for.
    static func setupIOSProject(context: inout FlowContext) async throws -> [String] {
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
        Log("🔍 Inspected project targets: \(info.targets.joined(separator: ", "))".dim)

        let result = try await XCodeTasks.getIosIdentifiers(
            workspaceRoot: context.projectDirectory,
            scheme: context.scheme,
            configuration: context.configuration
        )

        context.scheme ??= result.scheme
        context.configuration ??= result.configuration
        context.targetName ??= result.mainAppTargetName
        context.bundleId ??= result.bundleId

        // Read project's current version and build number (reusing getIosIdentifiers result when complete)
        if let version = result.version, let buildNumber = result.buildNumber {
            context.version = version
            context.buildNumber = buildNumber
        } else {
            let projVersionInfo = await XCodeTasks.resolveProjectVersion(
                projectPath: context.xcodeProjectPath,
                workspacePath: context.workspacePath,
                scheme: context.scheme,
                targetName: context.targetName,
                configuration: context.configuration,
                in: context.projectDirectory
            )
            context.version = projVersionInfo.version ?? result.version
            context.buildNumber = projVersionInfo.buildNumber ?? result.buildNumber
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

        return appIdentifiers
    }

    // MARK: - Setup: Match sync

    /// Syncs certificates and provisioning profiles via Match for `type` and stores them in `context`.
    /// No-op when `MATCH_GIT_URL` / `MATCH_PASSWORD` are not configured.
    static func syncMatch(
        context: inout FlowContext,
        appIdentifiers: [String],
        type: MatchTask.ProfileType,
        label: String
    ) async throws {
        guard let gitUrl = context.matchGitUrl, let password = context.matchPassword else {
            return
        }

        Log("🔐 Running Match \(label) synchronization...".dim)
        let output = try await MatchTask().run(
            .init(
                gitUrl: gitUrl,
                gitBranch: context.matchGitBranch ?? "master",
                gitToken: context.matchGitToken,
                type: type,
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

        Log("✨ Match \(label) completed successfully.".green.bold)
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
    }

    // MARK: - Prebuild: manual signing + build number

    /// Applies manual code signing from Match-installed profiles, then bumps the build number to
    /// `max(remoteBuildNumber, project build number) + 1` (see `BuildNumberPolicy`).
    /// Skips everything when no provisioning profiles were installed.
    static func prepareSigningAndBuildNumber(
        context: inout FlowContext,
        remoteBuildNumber: String?,
        sourceLabel: String,
        isDevelopment: Bool = false
    ) throws {
        Log("🔧 Preparing project for manual code signing...".dim)

        guard !context.installedProfiles.isEmpty else {
            Log("🚧  No provisioning profiles installed in context to configure manual signing.".yellow)
            return
        }

        let configuration = context.configuration ?? "Release"

        let identity = signingIdentity(from: context.installedCertificates.first, isDevelopment: isDevelopment)

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
            scheme: context.scheme,
            configuration: configuration,
            teamId: context.teamId,
            identity: identity,
            profilesByBundleId: context.installedProfiles,
            isDryRun: context.isDryRun
        )

        try backupProjectPbxproj(context: context)

        let results = try XCodeTasks.configureManualSigning(input, in: context.projectDirectory)

        if results.isEmpty {
            Log("🚧 No signable targets found or updated for configuration '\(configuration)'.".yellow)
        } else {
            Log("📝 Configured manual signing for \(results.count) target(s) [Configuration: \(configuration)]:".green.bold)
            for r in results {
                Log("   • Target: \(r.targetName.bold) (\(r.bundleId))")
                Log("     Profile: \(r.profileName) [UUID: \(r.profileUUID)]".dim)
                Log("     Identity: \(r.identity), Team: \(r.teamId ?? "None")".dim)
            }
        }

        try prepareIOSBuildNumber(
            context: &context,
            remoteBuildNumber: remoteBuildNumber,
            sourceLabel: sourceLabel,
            configuration: configuration
        )
    }

    /// Maps an installed certificate name to the code signing identity used for manual signing.
    /// Recognizes distribution (`Apple Distribution` / `iPhone Distribution`) and development
    /// (`Apple Development` / `iPhone Developer`) certificates; otherwise uses the certificate name as-is.
    /// Without a certificate, falls back to `Apple Development` for development builds or `Apple Distribution`.
    static func signingIdentity(from certificate: String?, isDevelopment: Bool) -> String {
        guard let cert = certificate else {
            return isDevelopment ? "Apple Development" : "Apple Distribution"
        }
        for known in ["iPhone Distribution", "Apple Distribution", "iPhone Developer", "Apple Development"]
        where cert.contains(known) {
            return known
        }
        return cert
    }

    /// Snapshots `project.pbxproj` before prebuild mutates code signing settings so it can be restored after building.
    static func backupProjectPbxproj(context: FlowContext) throws {
        guard !context.isDryRun else { return }
        let projectPath = try XCodeTasks.resolveProjectPath(
            projectPath: context.xcodeProjectPath,
            workspacePath: context.workspacePath,
            in: context.projectDirectory
        )
        let pbxprojUrl = URL(fileURLWithPath: projectPath).appendingPathComponent("project.pbxproj")
        try context.fileRestorer.backup(pbxprojUrl)
    }

    /// Computes the next build number (`max(remote, local) + 1`), normalizes literal `Info.plist` `CFBundleVersion`
    /// entries to `$(CURRENT_PROJECT_VERSION)`, and registers temporary `Info.plist` backups when
    /// `CURRENT_PROJECT_VERSION` is missing in the original project.
    static func prepareIOSBuildNumber(
        context: inout FlowContext,
        remoteBuildNumber: String?,
        sourceLabel: String,
        configuration: String
    ) throws {
        guard let next = BuildNumberPolicy.next(remote: remoteBuildNumber, local: context.buildNumber) else { return }

        let nextBuildNumber = next.value
        Log("🔢 Incrementing build number (local: \(context.buildNumber ?? "-"), \(sourceLabel): \(remoteBuildNumber ?? "-")): \(String(next.base).bold) -> \(nextBuildNumber.bold.green)".dim)

        if !context.isDryRun {
            let result = try XCodeTasks.updateBuildNumber(
                .init(
                    projectPath: context.xcodeProjectPath,
                    workspacePath: context.workspacePath,
                    buildNumber: nextBuildNumber,
                    version: context.version,
                    configurations: [configuration]
                ),
                in: context.projectDirectory
            )

            for (url, originalData) in result.temporaryBackups {
                context.fileRestorer.registerBackup(originalData, for: url)
            }

            if !result.normalizedInfoPlists.isEmpty {
                let names = result.normalizedInfoPlists.map(\.lastPathComponent).joined(separator: ", ")
                Log("📝 Updated Info.plist CFBundleVersion to $(CURRENT_PROJECT_VERSION): \(names)".dim)
            }
            if !result.temporaryBackups.isEmpty {
                Log(
                    "📝 Temporarily updated Info.plist CFBundleVersion to $(CURRENT_PROJECT_VERSION) (will be restored after build because CURRENT_PROJECT_VERSION is not defined in project.pbxproj)."
                        .dim)
            }
        }

        context.buildNumber = nextBuildNumber
    }

    // MARK: - Build: archive + export

    /// Archives and exports the IPA with `exportMethod`, restoring temporary project edits afterwards,
    /// and records the IPA (`ipa_path`) and dSYM in `context`. Honors `--dry-run`.
    static func build(
        context: inout FlowContext,
        exportMethod: XcodeBuildTask.ExportMethod,
        label: String
    ) async throws {
        Log("🔨 Compiling iOS archive with \(label) export configuration...".dim)

        if context.isDryRun {
            Log("🟡 Dry-run enabled: skipping xcodebuild archive/export.".yellow)
            return
        }

        defer {
            restoreTemporaryFiles(context: context)
        }

        let target = context.targetName ?? context.scheme ?? "app"
        let outputDir = AppitoolPaths.buildDirectory(platform: "ios", target: target, name: context.buildDirectoryName).path
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
                exportMethod: exportMethod,
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

    /// Restores any temporary `project.pbxproj` or `Info.plist` snapshots registered during prebuild.
    static func restoreTemporaryFiles(context: FlowContext) {
        let restored = context.fileRestorer.restoreAll()
        if !restored.isEmpty {
            let names = restored.map(\.lastPathComponent).sorted().joined(separator: ", ")
            Log("↩️ Restored temporary workspace file(s): \(names)".dim)
        }
    }
}
