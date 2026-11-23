import ArgumentParser
import Foundation
import Rainbow

struct BuildIOSCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Builds and packages iOS application using xcodebuild (comparable to Fastlane build_app)."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Option(name: .shortAndLong, help: "Path to .xcworkspace file (defaults to XCODE_WORKSPACE in .env or auto-discovered).")
    var workspace: String?

    @Option(name: .shortAndLong, help: "Path to .xcodeproj file (defaults to XCODE_PROJECT in .env or auto-discovered).")
    var project: String?

    @Option(name: .shortAndLong, help: "Xcode scheme to build (defaults to XCODE_SCHEME in .env or auto-inferred).")
    var scheme: String?

    @Option(name: .shortAndLong, help: "Build configuration (Debug, Release). Defaults to Release or XCODE_CONFIGURATION in .env.")
    var configuration: String?

    @Option(name: .shortAndLong, help: "Apple Developer Team ID (defaults to APPLE_TEAM_ID in .env).")
    var teamId: String?

    @Option(name: .long, help: "Code signing identity override (e.g. 'Apple Distribution', 'Apple Development').")
    var codesigningIdentity: String?

    @Flag(name: .long, help: "Clean build folder before building.")
    var clean: Bool = false

    @Flag(name: .long, help: "Skip compiling archive (only export IPA from existing archive).")
    var skipBuildArchive: Bool = false

    @Flag(name: .long, help: "Skip packaging IPA (only compile .xcarchive).")
    var skipPackageIpa: Bool = false

    @Flag(name: .long, help: "Allow xcodebuild to automatically communicate with Apple Developer Portal for provisioning updates.")
    var allowProvisioningUpdates: Bool = false

    @Flag(name: .long, help: "Allow App Store Connect to automatically manage and increment version/build number (defaults to false).")
    var manageBuildNumber: Bool = false

    @Flag(name: .long, help: "Suppress xcodebuild standard output and logs.")
    var silent: Bool = false

    @Option(name: .long, help: "Formatter command for xcodebuild output (defaults to 'xcbeautify --renderer github-actions').")
    var xcodebuildFormatter: String?

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    func execute() async throws {
        // 1. Resolve Workspace / Project
        let detected = XCodeTasks.autoDetect()
        let resolvedWorkspace = workspace ?? EnvLoader.value(for: "XCODE_WORKSPACE") ?? detected.workspace
        let resolvedProject = project ?? EnvLoader.value(for: "XCODE_PROJECT") ?? detected.project

        guard skipBuildArchive || resolvedWorkspace != nil || resolvedProject != nil else {
            throw CommandError("Could not find .xcworkspace or .xcodeproj in current directory or ios/ subdirectory. Specify -w, --workspace or -p, --project.")
        }

        // 3. Resolve Scheme via xcodebuild -list -json
        let resolvedScheme: String
        if !skipBuildArchive || resolvedWorkspace != nil || resolvedProject != nil {
            resolvedScheme = try await XcodeBuildTask.resolveScheme(
                requested: scheme ?? EnvLoader.value(for: "XCODE_SCHEME"),
                workspace: resolvedWorkspace,
                project: resolvedProject
            )
        } else if let explicitScheme = scheme ?? EnvLoader.value(for: "XCODE_SCHEME") {
            resolvedScheme = explicitScheme
        } else {
            throw CommandError("No scheme specified. Provide -s, --scheme or set XCODE_SCHEME in .env.")
        }

        // 4. Resolve Target, DerivedData, Archive & Output Directory
        let resolvedConfiguration = configuration ?? EnvLoader.value(for: "XCODE_CONFIGURATION") ?? "Release"

        let mainTarget: String
        if let resolved = await XcodeBuildTask.resolveMainTarget(forScheme: resolvedScheme, workspace: resolvedWorkspace, project: resolvedProject), !resolved.isEmpty {
            mainTarget = resolved
        } else {
            mainTarget = resolvedScheme
        }

        let buildRoot = AppitoolPaths.targetBuildRoot(platform: "ios", target: mainTarget)
        let resolvedDerivedData = AppitoolPaths.iosDerivedDataDirectory(target: mainTarget).path
        let resolvedOutputName = resolvedScheme

        var resolvedArchivePath: String? = nil
        if skipBuildArchive {
            // Latest .xcarchive across previous per-build directories.
            let fm = FileManager.default
            let buildDirs = ((try? fm.contentsOfDirectory(atPath: buildRoot.path)) ?? [])
                .map { buildRoot.appendingPathComponent($0) }
            let archives = buildDirs.flatMap { dir -> [URL] in
                ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { $0.hasSuffix(".xcarchive") }
                    .map { dir.appendingPathComponent($0) }
            }
            resolvedArchivePath = archives.compactMap { url -> (URL, Date)? in
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let modDate = attrs[.modificationDate] as? Date else { return nil }
                return (url, modDate)
            }.sorted { $0.1 > $1.1 }.first?.0.path
        }

        var resolvedVersion: String?
        var resolvedBuildNumber: String?
        if resolvedWorkspace != nil || resolvedProject != nil {
            let projectVersion = await XCodeTasks.resolveProjectVersion(
                projectPath: resolvedProject,
                workspacePath: resolvedWorkspace,
                scheme: resolvedScheme,
                targetName: mainTarget,
                configuration: resolvedConfiguration
            )
            resolvedVersion = projectVersion.version
            resolvedBuildNumber = projectVersion.buildNumber
        }
        if (resolvedVersion == nil || resolvedBuildNumber == nil), let archivePath = resolvedArchivePath {
            let archiveVersion = XcodeBuildTask.extractVersionInfo(fromArchive: archivePath)
            resolvedVersion = resolvedVersion ?? archiveVersion.version
            resolvedBuildNumber = resolvedBuildNumber ?? archiveVersion.buildNumber
        }
        let buildTagName = AppitoolPaths.buildTagName(
            version: resolvedVersion,
            buildNumber: resolvedBuildNumber,
            distribution: distribution
        )
        let resolvedOutputDir = AppitoolPaths.buildDirectory(
            platform: "ios",
            target: mainTarget,
            name: buildTagName
        ).path

        let resolvedTeamId = teamId ?? EnvLoader.value(for: "APPLE_TEAM_ID")
        let resolvedFormatter = xcodebuildFormatter ?? EnvLoader.value(for: "XCODEBUILD_FORMATTER") ?? "xcbeautify --renderer github-actions"

        // 5. Map Distribution to Export Method
        let exportMethod: XcodeBuildTask.ExportMethod
        switch distribution {
        case .appstore:
            exportMethod = .appStore
        case .adhoc:
            exportMethod = .adHoc
        case .development:
            exportMethod = .development
        }

        // 6. Build extra arguments (e.g. provisioning updates, authentication keys)
        var xcargs: [String] = []
        var exportXcargs: [String] = []

        if allowProvisioningUpdates {
            // If App Store Connect credentials are provided and key is a file path, pass authentication arguments
            if let creds = appleCredentials.resolve() {
                if FileManager.default.fileExists(atPath: creds.key) {
                    let authArgs = [
                        "-authenticationKeyPath", creds.key,
                        "-authenticationKeyID", creds.keyId,
                        "-authenticationKeyIssuerID", creds.issuerId,
                    ]
                    xcargs.append(contentsOf: authArgs)
                    exportXcargs.append(contentsOf: authArgs)
                }
            }
        }

        Log("\n" + "─── Starting iOS Build (\(distribution.rawValue.capitalized)) ───".cyan.bold)
        if let ws = resolvedWorkspace {
            Log("   Workspace:   ".dim + "\(ws)".bold)
        } else if let proj = resolvedProject {
            Log("   Project:     ".dim + "\(proj)".bold)
        }
        Log("   Target:      ".dim + "\(mainTarget)".bold)
        Log("   Scheme:      ".dim + "\(resolvedScheme)".bold)
        Log("   Config:      ".dim + "\(resolvedConfiguration)".bold)
        Log("   Output:      ".dim + "\(resolvedOutputDir)".bold)
        Log("   Artifact:    ".dim + "\(resolvedOutputName)".bold)
        Log("   DerivedData: ".dim + "\(resolvedDerivedData)".dim)

        // 7. Execute XcodeBuildTask
        let task = XcodeBuildTask()
        let output = try await task.run(.init(
            workspace: resolvedWorkspace,
            project: resolvedProject,
            scheme: resolvedScheme,
            configuration: resolvedConfiguration,
            outputDirectory: resolvedOutputDir,
            outputName: resolvedOutputName,
            archivePath: resolvedArchivePath,
            derivedDataPath: resolvedDerivedData,
            skipBuildArchive: skipBuildArchive,
            skipPackageIpa: skipPackageIpa,
            clean: clean,
            allowProvisioningUpdates: allowProvisioningUpdates,
            codesigningIdentity: codesigningIdentity,
            exportMethod: exportMethod,
            exportTeamId: resolvedTeamId,
            manageAppVersionAndBuildNumber: manageBuildNumber,
            xcodebuildFormatter: resolvedFormatter,
            silent: silent,
            xcargs: xcargs,
            exportXcargs: exportXcargs
        ))

        Log("\n" + "🎉 iOS Build Completed Successfully!".green.bold)
        if let archive = output.archivePath {
            Log("   Archive: ".dim + "\(archive)".green)
        }
        if let ipa = output.ipaPath {
            Log("   IPA:     ".dim + "\(ipa)".green.bold)
        }
        if let dsym = output.dsymPath {
            Log("   dSYM:    ".dim + "\(dsym)".dim)
        }
    }
}
