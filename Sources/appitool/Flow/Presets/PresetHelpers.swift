import Foundation
import Rainbow

/// Shared setup logic for iOS presets (detecting workspace/project, inspecting targets, versions, and app identifiers).
enum IOSPresetHelpers {
    /// Detects Xcode project/workspace and populates target, scheme, version, and bundle ID into `context`.
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

        return appIdentifiers
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

    /// Computes the next build number, normalizes literal `Info.plist` `CFBundleVersion` entries to `$(CURRENT_PROJECT_VERSION)`,
    /// and registers temporary `Info.plist` backups when `CURRENT_PROJECT_VERSION` is missing in the original project.
    static func prepareIOSBuildNumber(
        context: inout FlowContext,
        baseBuildStr: String?,
        sourceLabel: String,
        configuration: String
    ) throws {
        guard let baseBuildStr, let baseBuild = Int(baseBuildStr) else { return }

        let nextBuildNumber = String(baseBuild + 1)
        let prevDisplay = context.buildNumber != nil
            ? "\(context.buildNumber!) (\(sourceLabel): \(baseBuildStr))"
            : baseBuildStr
        Log("🔢 Incrementing build number: \(prevDisplay.bold) -> \(nextBuildNumber.bold.green)".dim)

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

    /// Restores any temporary `project.pbxproj` or `Info.plist` snapshots registered during prebuild.
    static func restoreTemporaryFiles(context: FlowContext) {
        let restored = context.fileRestorer.restoreAll()
        if !restored.isEmpty {
            let names = restored.map(\.lastPathComponent).sorted().joined(separator: ", ")
            Log("↩️ Restored temporary workspace file(s): \(names)".dim)
        }
    }
}

/// Shared setup logic for Android presets (extracting package name, namespace, version info, and evaluating Gradle).
enum AndroidPresetHelpers {
    /// Inspects and evaluates Android app info, storing results in `context`.
    static func setupAndroidProject(context: inout FlowContext) async throws {
        // 1. Fast regex inspection
        if let identifiers = try? AndroidTasks.getAndroidIdentifiers(workspaceRoot: context.projectDirectory) {
            context.bundleId ??= identifiers.packageName
            if let versionName = identifiers.versionName {
                context.version ??= versionName
            }
            if let versionCode = identifiers.versionCode {
                context.buildNumber ??= versionCode
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
    }
}
