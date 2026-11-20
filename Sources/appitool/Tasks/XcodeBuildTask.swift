import Foundation
import Rainbow

/// A task that handles building, archiving, and packaging iOS applications using `xcodebuild`
/// providing full functional parity with Fastlane's `build_app` (`gym`) and `@cmd-bin/react-native`.
public struct XcodeBuildTask: Task {
    /// Export method options for IPA packaging.
    public enum ExportMethod: String, Sendable, CaseIterable {
        case appStore = "app-store-connect"
        case adHoc = "release-testing"
        case enterprise = "enterprise"
        case development = "debugging"
    }

    /// Signing style options for export options plist.
    public enum SigningStyle: String, Sendable {
        case manual
        case automatic
    }

    /// Configuration input for `XcodeBuildTask`.
    public struct Input: Sendable {
        /// Path to the `.xcworkspace` file (if building with workspace).
        public let workspace: String?

        /// Path to the `.xcodeproj` file (if building with project directly).
        public let project: String?

        /// The scheme to build. If nil, automatically discovered from project via `xcodebuild -list -json`.
        public let scheme: String?

        /// Build configuration (e.g., "Release", "Debug"). Defaults to "Release".
        public let configuration: String

        /// Directory where the xcarchive and exported artifacts will be stored.
        public let outputDirectory: String

        /// Optional custom name for the exported archive / IPA (defaults to scheme name).
        public let outputName: String?

        /// Custom path to the `.xcarchive`. If nil, automatically determined inside `outputDirectory`.
        public let archivePath: String?

        /// Path to custom derived data directory.
        public let derivedDataPath: String?

        /// Whether to skip the archive compilation step (e.g., when packaging an existing archive).
        public let skipBuildArchive: Bool

        /// Whether to skip packaging the IPA (e.g., archive-only step).
        public let skipPackageIpa: Bool

        /// Whether to clean the build folder before building. Defaults to `false`.
        public let clean: Bool

        /// Whether to allow xcodebuild to automatically communicate with Apple Developer Portal for provisioning updates. Defaults to `false`.
        public let allowProvisioningUpdates: Bool

        /// Code signing identity override (e.g., "Apple Distribution: ...").
        public let codesigningIdentity: String?

        /// Build number override passed via CURRENT_PROJECT_VERSION=<value> during archive.
        public let buildNumber: String?

        /// Distribution method used for generating export options plist. Defaults to `.appStore`.
        public let exportMethod: ExportMethod

        /// Apple Developer Team ID used for code signing / export.
        public let exportTeamId: String?

        /// Signing style in ExportOptions plist ("manual" or "automatic").
        public let signingStyle: SigningStyle?

        /// Explicit mapping of bundle identifiers to provisioning profile UUIDs or names.
        public let provisioningProfiles: [String: String]?

        /// Whether to allow App Store Connect to manage/increment version and build numbers automatically.
        public let manageAppVersionAndBuildNumber: Bool?

        /// Formatter tool for xcodebuild output (e.g. "xcbeautify --renderer github-actions").
        public let xcodebuildFormatter: String?

        /// Whether to suppress printing xcodebuild commands and stdout. Defaults to `false`.
        public let silent: Bool

        /// Additional raw arguments passed to `xcodebuild archive`.
        public let xcargs: [String]

        /// Additional raw arguments passed to `xcodebuild -exportArchive`.
        public let exportXcargs: [String]

        public init(
            workspace: String? = nil,
            project: String? = nil,
            scheme: String? = nil,
            configuration: String = "Release",
            outputDirectory: String,
            outputName: String? = nil,
            archivePath: String? = nil,
            derivedDataPath: String? = nil,
            skipBuildArchive: Bool = false,
            skipPackageIpa: Bool = false,
            clean: Bool = false,
            allowProvisioningUpdates: Bool = false,
            codesigningIdentity: String? = nil,
            buildNumber: String? = nil,
            exportMethod: ExportMethod = .appStore,
            exportTeamId: String? = nil,
            signingStyle: SigningStyle? = nil,
            provisioningProfiles: [String: String]? = nil,
            manageAppVersionAndBuildNumber: Bool? = nil,
            xcodebuildFormatter: String? = "xcbeautify --renderer github-actions",
            silent: Bool = false,
            xcargs: [String] = [],
            exportXcargs: [String] = []
        ) {
            self.workspace = workspace
            self.project = project
            self.scheme = scheme
            self.configuration = configuration
            self.outputDirectory = outputDirectory
            self.outputName = outputName
            self.archivePath = archivePath
            self.derivedDataPath = derivedDataPath
            self.skipBuildArchive = skipBuildArchive
            self.skipPackageIpa = skipPackageIpa
            self.clean = clean
            self.allowProvisioningUpdates = allowProvisioningUpdates
            self.codesigningIdentity = codesigningIdentity
            self.buildNumber = buildNumber
            self.exportMethod = exportMethod
            self.exportTeamId = exportTeamId
            self.signingStyle = signingStyle
            self.provisioningProfiles = provisioningProfiles
            self.manageAppVersionAndBuildNumber = manageAppVersionAndBuildNumber
            self.xcodebuildFormatter = xcodebuildFormatter
            self.silent = silent
            self.xcargs = xcargs
            self.exportXcargs = exportXcargs
        }
    }

    /// Result containing generated artifacts from `XcodeBuildTask`.
    public struct Output: Sendable {
        /// Path to the generated `.xcarchive` directory.
        public let archivePath: String?

        /// Path to the exported `.ipa` file.
        public let ipaPath: String?

        /// Path to generated `.dSYM.zip` file (if symbols were exported or discovered).
        public let dsymPath: String?

        /// Directory containing all output artifacts.
        public let outputDirectory: String

        public init(
            archivePath: String? = nil,
            ipaPath: String? = nil,
            dsymPath: String? = nil,
            outputDirectory: String
        ) {
            self.archivePath = archivePath
            self.ipaPath = ipaPath
            self.dsymPath = dsymPath
            self.outputDirectory = outputDirectory
        }
    }

    /// Errors thrown during `XcodeBuildTask` execution.
    public enum XcodeBuildError: LocalizedError, Sendable {
        case missingWorkspaceOrProject
        case schemeNotFound(requested: String, available: [String])
        case noSchemesFound
        case schemeListFailed(String)
        case missingScheme
        case archiveNotFound(path: String)
        case archiveFailed(exitCode: Int32, output: String)
        case exportFailed(exitCode: Int32, output: String)
        case ipaNotFound(expectedPath: String)
        case ambiguousIpa(paths: [String])
        case plistSerializationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingWorkspaceOrProject:
                return "Either workspace or project path must be specified for xcodebuild."
            case .schemeNotFound(let requested, let available):
                let list = available.isEmpty ? "None" : available.joined(separator: ", ")
                return "Scheme '\(requested)' was not found in project. Available schemes: \(list)"
            case .noSchemesFound:
                return "No schemes found in the specified workspace or project."
            case .schemeListFailed(let message):
                return "Failed to list schemes from xcodebuild: \(message)"
            case .missingScheme:
                return "No scheme specified. Please provide a scheme name."
            case .archiveNotFound(let path):
                return "Archive not found at path: \(path)"
            case .archiveFailed(let code, let output):
                return "xcodebuild archive failed with exit code \(code):\n\(output)"
            case .exportFailed(let code, let output):
                return "xcodebuild -exportArchive failed with exit code \(code):\n\(output)"
            case .ipaNotFound(let path):
                return "Exported IPA file was not found in directory: \(path)"
            case .ambiguousIpa(let paths):
                return "Export produced multiple IPA files, cannot determine which one to use: \(paths.joined(separator: ", "))"
            case .plistSerializationFailed(let message):
                return "Failed to generate ExportOptions.plist: \(message)"
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        let fileManager = FileManager.default

        // 1. Ensure output directory exists
        try fileManager.createDirectory(atPath: input.outputDirectory, withIntermediateDirectories: true)

        let resolvedScheme: String
        if !input.skipBuildArchive {
            guard input.workspace != nil || input.project != nil else {
                throw XcodeBuildError.missingWorkspaceOrProject
            }
            resolvedScheme = try await Self.resolveScheme(
                requested: input.scheme,
                workspace: input.workspace,
                project: input.project
            )
        } else if let explicitScheme = input.scheme {
            resolvedScheme = explicitScheme
        } else if input.workspace != nil || input.project != nil {
            resolvedScheme = try await Self.resolveScheme(
                requested: nil,
                workspace: input.workspace,
                project: input.project
            )
        } else if let archivePath = input.archivePath {
            resolvedScheme = URL(fileURLWithPath: archivePath).deletingPathExtension().lastPathComponent
        } else if let outputName = input.outputName {
            resolvedScheme = outputName
        } else {
            throw XcodeBuildError.missingScheme
        }

        let baseName = input.outputName ?? resolvedScheme
        let resolvedArchivePath = input.archivePath ?? URL(fileURLWithPath: input.outputDirectory)
            .appendingPathComponent("\(baseName).xcarchive").path

        var resultingArchivePath: String?
        var resultingIpaPath: String?
        var resultingDsymPath: String?

        // 2. Step 1: Archive (`xcodebuild archive`)
        if !input.skipBuildArchive {
            try await executeArchive(input: input, scheme: resolvedScheme, archivePath: resolvedArchivePath)
            resultingArchivePath = resolvedArchivePath
        } else {
            guard fileManager.fileExists(atPath: resolvedArchivePath) else {
                throw XcodeBuildError.archiveNotFound(path: resolvedArchivePath)
            }
            resultingArchivePath = resolvedArchivePath
        }

        // 3. Step 2: Package IPA (`xcodebuild -exportArchive`)
        if !input.skipPackageIpa {
            guard let archivePath = resultingArchivePath, fileManager.fileExists(atPath: archivePath) else {
                throw XcodeBuildError.archiveNotFound(path: resultingArchivePath ?? resolvedArchivePath)
            }

            let exportResult = try await executeExport(input: input, archivePath: archivePath, baseName: baseName)
            resultingIpaPath = exportResult.ipaPath
            resultingDsymPath = exportResult.dsymPath
        }

        return Output(
            archivePath: resultingArchivePath,
            ipaPath: resultingIpaPath,
            dsymPath: resultingDsymPath,
            outputDirectory: input.outputDirectory
        )
    }

    // MARK: - Scheme Resolution & Discovery

    public typealias ProjectInfo = XCodeTasks.ProjectInfo

    /// Automatically scans the specified directory and its `ios/` subdirectory for `.xcworkspace` or `.xcodeproj`.
    public static func autoDetect(
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> (workspace: String?, project: String?) {
        XCodeTasks.autoDetect(in: directory)
    }

    /// Lists project/workspace information (name, schemes, targets) using `XCodeTasks`.
    public static func inspectProject(
        workspace: String? = nil,
        project: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async throws -> ProjectInfo {
        try await XCodeTasks.inspectProject(workspace: workspace, project: project, in: directory)
    }

    /// Lists all schemes available in the workspace or project using `xcodebuild -list -json`.
    public static func listSchemes(
        workspace: String? = nil,
        project: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async throws -> [String] {
        let info = try await inspectProject(workspace: workspace, project: project, in: directory)
        return info.schemes
    }

    /// Lists all targets available in the workspace or project using `xcodebuild -list -json`.
    public static func listTargets(
        workspace: String? = nil,
        project: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async throws -> [String] {
        let info = try await inspectProject(workspace: workspace, project: project, in: directory)
        return info.targets
    }

    /// Resolves the primary target name built by the given scheme:
    /// 1. Searches for `<scheme>.xcscheme` and extracts `BlueprintName` (the target name).
    /// 2. If not found in .xcscheme, queries `xcodebuild -showBuildSettings -scheme <scheme>` to extract `TARGET_NAME`.
    /// 3. Falls back to project targets list filtering out tests.
    public static func resolveMainTarget(
        forScheme scheme: String,
        workspace: String? = nil,
        project: String? = nil
    ) async -> String? {
        // 1. Try finding and reading <scheme>.xcscheme
        if let targetFromScheme = extractTargetFromSchemeFile(scheme: scheme, workspace: workspace, project: project) {
            return targetFromScheme
        }

        // 2. Try xcodebuild -showBuildSettings -scheme <scheme>
        if let targetFromBuildSettings = await extractTargetFromBuildSettings(scheme: scheme, workspace: workspace, project: project) {
            return targetFromBuildSettings
        }

        // 3. Fallback: inspect companion or specified .xcodeproj
        var effectiveProject = project
        if effectiveProject == nil, let ws = workspace {
            let candidate = URL(fileURLWithPath: ws).deletingPathExtension().appendingPathExtension("xcodeproj").path
            if FileManager.default.fileExists(atPath: candidate) {
                effectiveProject = candidate
            } else {
                let wsDir = URL(fileURLWithPath: ws).deletingLastPathComponent().path
                if let items = try? FileManager.default.contentsOfDirectory(atPath: wsDir) {
                    if let found = items.first(where: { $0.hasSuffix(".xcodeproj") && !$0.lowercased().contains("pods") }) {
                        effectiveProject = URL(fileURLWithPath: wsDir).appendingPathComponent(found).path
                    }
                }
            }
        }

        guard let effectiveProject else { return nil }
        guard let info = try? await inspectProject(project: effectiveProject) else { return nil }

        let appTargets = info.targets.filter { t in
            let lower = t.lowercased()
            return !lower.hasSuffix("tests") && !lower.hasSuffix("test") && !lower.hasSuffix("uitests")
        }
        return appTargets.first ?? info.targets.first
    }

    private static func extractTargetFromSchemeFile(
        scheme: String,
        workspace: String?,
        project: String?
    ) -> String? {
        let fm = FileManager.default
        var searchRoots: [String] = []

        if let project {
            searchRoots.append(project)
        }
        if let workspace {
            searchRoots.append(workspace)
            let companion = URL(fileURLWithPath: workspace).deletingPathExtension().appendingPathExtension("xcodeproj").path
            searchRoots.append(companion)
        }

        var candidateSchemePaths: [String] = []
        for root in searchRoots {
            candidateSchemePaths.append("\(root)/xcshareddata/xcschemes/\(scheme).xcscheme")

            let userDataDir = "\(root)/xcuserdata"
            if let userDirs = try? fm.contentsOfDirectory(atPath: userDataDir) {
                for u in userDirs {
                    candidateSchemePaths.append("\(userDataDir)/\(u)/xcschemes/\(scheme).xcscheme")
                }
            }
        }

        for path in candidateSchemePaths {
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            let patterns = [
                #"<ArchiveAction[\s\S]*?BlueprintName\s*=\s*"([^"]+)""#,
                #"<BuildActionEntry[^>]*buildForArchiving\s*=\s*"YES"[\s\S]*?BlueprintName\s*=\s*"([^"]+)""#,
                #"BlueprintName\s*=\s*"([^"]+)""#
            ]

            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: content) {
                    let target = String(content[range])
                    if !target.isEmpty {
                        return target
                    }
                }
            }
        }

        return nil
    }

    private static func extractTargetFromBuildSettings(
        scheme: String,
        workspace: String?,
        project: String?
    ) async -> String? {
        var arguments = ["-showBuildSettings", "-scheme", scheme]
        if let workspace {
            arguments.append(contentsOf: ["-workspace", workspace])
        } else if let project {
            arguments.append(contentsOf: ["-project", project])
        }

        guard let result = try? await ProcessRunner.run("xcrun", arguments: ["xcodebuild"] + arguments, combineOutput: true),
              result.exitCode == 0 else {
            return nil
        }

        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TARGET_NAME =") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let target = parts[1].trimmingCharacters(in: .whitespaces)
                    if !target.isEmpty {
                        return target
                    }
                }
            }
        }

        return nil
    }

    /// Resolves the build scheme:
    /// - If a scheme is requested, validates it against available schemes. Throws `schemeNotFound` if not present.
    /// - If no scheme is requested, prioritizes schemes matching the project/workspace name, filtering out SPM and Pods dependency schemes.
    public static func resolveScheme(
        requested: String?,
        workspace: String?,
        project: String?
    ) async throws -> String {
        // 1. Determine base target name from workspace or project file name
        let targetName: String?
        if let ws = workspace {
            targetName = URL(fileURLWithPath: ws).deletingPathExtension().lastPathComponent
        } else if let proj = project {
            targetName = URL(fileURLWithPath: proj).deletingPathExtension().lastPathComponent
        } else {
            targetName = nil
        }

        // 2. Locate companion .xcodeproj if workspace is provided
        // (xcodebuild -list on .xcodeproj returns ONLY app schemes, whereas .xcworkspace includes all SPM dependencies like AppAuth, Firebase, etc.)
        var effectiveProject = project
        if effectiveProject == nil, let ws = workspace {
            let candidate = URL(fileURLWithPath: ws).deletingPathExtension().appendingPathExtension("xcodeproj").path
            if FileManager.default.fileExists(atPath: candidate) {
                effectiveProject = candidate
            }
        }

        var projectSchemes: [String] = []
        if let effectiveProject {
            projectSchemes = (try? await listSchemes(project: effectiveProject)) ?? []
        }

        let allSchemes: [String]
        if !projectSchemes.isEmpty {
            allSchemes = projectSchemes
        } else {
            allSchemes = try await listSchemes(workspace: workspace, project: project)
        }

        guard !allSchemes.isEmpty else {
            throw XcodeBuildError.noSchemesFound
        }

        // 3. If a specific scheme was requested, validate it
        if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            if allSchemes.contains(requested) {
                return requested
            }
            // Check workspace schemes as a fallback if effectiveProject didn't include it
            if let ws = workspace {
                let wsSchemes = (try? await listSchemes(workspace: ws)) ?? []
                if wsSchemes.contains(requested) {
                    return requested
                }
                throw XcodeBuildError.schemeNotFound(requested: requested, available: wsSchemes)
            }
            throw XcodeBuildError.schemeNotFound(requested: requested, available: allSchemes)
        }

        // 4. If no scheme was requested, apply intelligent auto-selection:
        // Priority A: Scheme matching the project/workspace name exactly
        if let targetName, let exact = allSchemes.first(where: { $0 == targetName }) {
            return exact
        }

        // Priority B: Scheme matching the project/workspace name case-insensitively
        if let targetName, let caseInsensitive = allSchemes.first(where: { $0.caseInsensitiveCompare(targetName) == .orderedSame }) {
            return caseInsensitive
        }

        // Priority C: Filter out CocoaPods and SPM dependency schemes
        let appSchemes = allSchemes.filter { !$0.hasPrefix("Pods-") && !$0.hasPrefix("Pods_") }

        // Priority D: Scheme containing project/workspace name
        if let targetName, let contains = appSchemes.first(where: { $0.localizedCaseInsensitiveContains(targetName) }) {
            return contains
        }

        // Priority E: First non-test scheme
        let nonTestSchemes = appSchemes.filter { !$0.hasSuffix("Tests") && !$0.hasSuffix("UITests") }
        if let firstValid = nonTestSchemes.first {
            return firstValid
        }

        if let firstAppScheme = appSchemes.first {
            return firstAppScheme
        }

        return allSchemes[0]
    }

    // MARK: - Archive Execution

    internal static func buildArchiveArguments(
        input: Input,
        scheme: String,
        archivePath: String
    ) -> [String] {
        var arguments: [String] = []

        if let workspace = input.workspace {
            arguments.append(contentsOf: ["-workspace", workspace])
        } else if let project = input.project {
            arguments.append(contentsOf: ["-project", project])
        }

        arguments.append(contentsOf: [
            "-scheme", scheme,
            "-configuration", input.configuration,
            "-destination", "generic/platform=iOS",
            "-sdk", "iphoneos",
            "-archivePath", archivePath,
        ])

        if let derivedDataPath = input.derivedDataPath, !derivedDataPath.isEmpty {
            arguments.append(contentsOf: ["-derivedDataPath", derivedDataPath])
        }

        if input.clean {
            arguments.append("clean")
        }
        arguments.append("archive")

        if let teamId = input.exportTeamId, !teamId.isEmpty {
            arguments.append("DEVELOPMENT_TEAM=\(teamId)")
        }

        if let identity = input.codesigningIdentity, !identity.isEmpty {
            arguments.append("CODE_SIGN_IDENTITY=\(identity)")
        }

        if let buildNumber = input.buildNumber, !buildNumber.isEmpty {
            arguments.append("CURRENT_PROJECT_VERSION=\(buildNumber)")
        }

        if input.allowProvisioningUpdates {
            arguments.append("-allowProvisioningUpdates")
        }

        arguments.append(contentsOf: input.xcargs)
        return arguments
    }

    private func executeArchive(input: Input, scheme: String, archivePath: String) async throws {
        let arguments = Self.buildArchiveArguments(input: input, scheme: scheme, archivePath: archivePath)

        if !input.silent {
            Log("🔨 ".bold + "Compiling Xcode archive: \(scheme) (\(input.configuration))...".dim)
        }

        let result = try await ProcessRunner.stream(
            "xcodebuild",
            arguments: arguments,
            formatter: input.xcodebuildFormatter,
            style: input.silent ? .silent : .logLines
        )

        guard result.exitCode == 0 else {
            throw XcodeBuildError.archiveFailed(exitCode: result.exitCode, output: result.stdout)
        }

        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw XcodeBuildError.archiveNotFound(path: archivePath)
        }

        if !input.silent {
            Log("🟢 Xcode archive created at \(archivePath)".dim)
        }
    }

    // MARK: - Export Execution

    private func executeExport(
        input: Input,
        archivePath: String,
        baseName: String
    ) async throws -> (ipaPath: String, dsymPath: String?) {
        let fileManager = FileManager.default
        let temporaryPlistUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appitool-exportOptions-\(UUID().uuidString).plist")
        try generateExportOptionsPlist(input: input, archivePath: archivePath, destinationUrl: temporaryPlistUrl)
        let exportPlistPath = temporaryPlistUrl.path

        defer {
            try? fileManager.removeItem(at: temporaryPlistUrl)
        }

        var arguments = [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportOptionsPlist", exportPlistPath,
            "-exportPath", input.outputDirectory,
        ]

        if input.allowProvisioningUpdates && !input.exportXcargs.contains("-allowProvisioningUpdates") {
            arguments.append("-allowProvisioningUpdates")
        }
        arguments.append(contentsOf: input.exportXcargs)

        if !input.silent {
            Log("📦 ".bold + "Packaging IPA with export method: \(input.exportMethod.rawValue)...".dim)
        }

        let ipasBefore = Self.ipaModificationDates(in: input.outputDirectory)

        let result = try await ProcessRunner.stream(
            "xcodebuild",
            arguments: arguments,
            formatter: input.xcodebuildFormatter,
            style: input.silent ? .silent : .logLines
        )

        guard result.exitCode == 0 else {
            throw XcodeBuildError.exportFailed(exitCode: result.exitCode, output: result.stdout)
        }

        // Locate the IPA produced by this export. The output directory is dedicated to this build,
        // so only IPAs that are new (or rewritten) since before the export are considered.
        // No guessing or renaming: exactly one IPA must have been produced.
        let ipasAfter = Self.ipaModificationDates(in: input.outputDirectory)
        let producedIpas = ipasAfter
            .filter { ipasBefore[$0.key] != $0.value }
            .map { URL(fileURLWithPath: input.outputDirectory).appendingPathComponent($0.key).path }
            .sorted()

        let resolvedIpa: String
        switch producedIpas.count {
        case 1:
            resolvedIpa = producedIpas[0]
        case 0:
            throw XcodeBuildError.ipaNotFound(expectedPath: input.outputDirectory)
        default:
            throw XcodeBuildError.ambiguousIpa(paths: producedIpas)
        }

        // Check for dSYM bundle / zip
        var resolvedDsym: String?
        let dsymInArchive = URL(fileURLWithPath: archivePath).appendingPathComponent("dSYMs").path
        if fileManager.fileExists(atPath: dsymInArchive) {
            let zipPath = URL(fileURLWithPath: input.outputDirectory).appendingPathComponent("\(baseName).dSYM.zip").path
            if fileManager.fileExists(atPath: zipPath) {
                try? fileManager.removeItem(atPath: zipPath)
            }
            _ = try? await ProcessRunner.run(
                "zip",
                arguments: ["-q", "-r", zipPath, "."],
                workingDirectory: dsymInArchive,
                discardError: true,
                discardOutput: true,
            )

            if fileManager.fileExists(atPath: zipPath) {
                resolvedDsym = zipPath
            } else {
                resolvedDsym = dsymInArchive
            }
        }

        if !input.silent {
            Log("🟢 IPA packaged successfully at \(resolvedIpa)".dim)
        }

        return (resolvedIpa, resolvedDsym)
    }

    /// Snapshot of `.ipa` file names (top-level only) mapped to their modification dates.
    private static func ipaModificationDates(in directory: String) -> [String: Date] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        var result: [String: Date] = [:]
        for name in names where name.hasSuffix(".ipa") {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            result[name] = date ?? .distantPast
        }
        return result
    }

    // MARK: - Plist Generation

    private func generateExportOptionsPlist(input: Input, archivePath: String, destinationUrl: URL) throws {
        // Resolve team ID from input or automatically extract from archive's Info.plist
        let resolvedTeamId = input.exportTeamId ?? extractTeamIdFromArchive(archivePath)

        // Resolve signing style:
        // - if explicitly specified, use it
        // - if provisioningProfiles is provided and non-empty -> manual
        // - otherwise default to automatic
        let resolvedSigningStyle: SigningStyle
        if let style = input.signingStyle {
            resolvedSigningStyle = style
        } else if let profiles = input.provisioningProfiles, !profiles.isEmpty {
            resolvedSigningStyle = .manual
        } else {
            resolvedSigningStyle = .automatic
        }

        var options: [String: Any] = [
            "method": input.exportMethod.rawValue,
            "signingStyle": resolvedSigningStyle.rawValue,
            "uploadSymbols": true,
            "compileBitcode": false,
        ]

        if let teamId = resolvedTeamId, !teamId.isEmpty {
            options["teamID"] = teamId
        }

        if let manage = input.manageAppVersionAndBuildNumber {
            options["manageAppVersionAndBuildNumber"] = manage
        }

        if let profiles = input.provisioningProfiles, !profiles.isEmpty {
            options["provisioningProfiles"] = profiles
        }

        do {
            let plistData = try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
            try plistData.write(to: destinationUrl)
        } catch {
            throw XcodeBuildError.plistSerializationFailed(error.localizedDescription)
        }
    }

    private func extractTeamIdFromArchive(_ archivePath: String) -> String? {
        let plistPath = URL(fileURLWithPath: archivePath).appendingPathComponent("Info.plist").path
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let appProps = plist["ApplicationProperties"] as? [String: Any],
              let team = appProps["Team"] as? String, !team.isEmpty else {
            return nil
        }
        return team
    }
}
