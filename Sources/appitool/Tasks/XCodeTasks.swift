import Foundation
import PathKit
import Rainbow
import XcodeProj

/// A suite of atomic Xcode project operations powered exclusively by `XcodeProj`.
public enum XCodeTasks {

    // MARK: - Auto-Detect

    /// Automatically scans the specified directory and its `ios/` subdirectory for `.xcworkspace` or `.xcodeproj`.
    public static func autoDetect(
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> (workspace: String?, project: String?) {
        let fm = FileManager.default
        let currentDir = directory.path
        let searchDirs = [currentDir, "\(currentDir)/ios"]

        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let ws = items.first(where: { $0.hasSuffix(".xcworkspace") && !$0.hasPrefix(".") }) {
                return (workspace: "\(dir)/\(ws)", project: nil)
            }
            if let proj = items.first(where: { $0.hasSuffix(".xcodeproj") && !$0.hasPrefix(".") }) {
                return (workspace: nil, project: "\(dir)/\(proj)")
            }
        }
        return (workspace: nil, project: nil)
    }

    /// Checks if an iOS project (workspace or xcodeproj) exists in the specified directory or its ios/ subdirectory.
    public static func hasIosProject(
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Bool {
        let detected = autoDetect(in: directory)
        return detected.workspace != nil || detected.project != nil
    }

    /// Resolves the path to the target `.xcodeproj` from an explicit project path, workspace path, or directory auto-detection.
    public static func resolveProjectPath(
        projectPath: String? = nil,
        workspacePath: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> String {
        if let proj = projectPath, !proj.isEmpty {
            return proj
        }
        let detected = autoDetect(in: directory)
        if let proj = detected.project {
            return proj
        }
        if let ws = workspacePath ?? detected.workspace {
            let companion = URL(fileURLWithPath: ws).deletingPathExtension().appendingPathExtension("xcodeproj").path
            if FileManager.default.fileExists(atPath: companion) {
                return companion
            }
            throw NSError(
                domain: "XCodeTasks",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Could not find companion .xcodeproj for workspace '\(ws)'."]
            )
        }
        throw NSError(
            domain: "XCodeTasks",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "No Xcode project found in current directory or ios/ subdirectory."]
        )
    }

    // MARK: - Project Inspection

    public struct ProjectInfo: Sendable {
        public let name: String?
        public let schemes: [String]
        public let targets: [String]

        public init(name: String?, schemes: [String], targets: [String]) {
            self.name = name
            self.schemes = schemes
            self.targets = targets
        }
    }

    /// Lists project/workspace information (name, schemes, targets) using exclusively `XcodeProj`.
    public static func inspectProject(
        workspace: String? = nil,
        project: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async throws -> ProjectInfo {
        var effectiveWorkspace = workspace
        var effectiveProject = project

        if effectiveWorkspace == nil && effectiveProject == nil {
            let detected = autoDetect(in: directory)
            effectiveWorkspace = detected.workspace
            effectiveProject = detected.project
        }

        guard effectiveWorkspace != nil || effectiveProject != nil else {
            throw NSError(
                domain: "XCodeTasks",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Either workspace or project path must be specified."
                ]
            )
        }

        if let projectPath = effectiveProject, !projectPath.isEmpty {
            return try inspectSingleProject(at: URL(fileURLWithPath: projectPath))
        }

        if let workspacePath = effectiveWorkspace, !workspacePath.isEmpty {
            return try inspectWorkspace(at: URL(fileURLWithPath: workspacePath), in: directory)
        }

        throw NSError(
            domain: "XCodeTasks",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to inspect project using XcodeProj."]
        )
    }

    private static func inspectSingleProject(at projectUrl: URL) throws -> ProjectInfo {
        let xcodeProj = try XcodeProj(path: Path(projectUrl.path))
        let projectName =
            xcodeProj.pbxproj.projects.first?.name
            ?? projectUrl.deletingPathExtension().lastPathComponent

        var targetNames: [String] = []
        if let projTargets = xcodeProj.pbxproj.projects.first?.targets {
            targetNames = projTargets.map { $0.name }
        } else {
            targetNames = xcodeProj.pbxproj.nativeTargets.map { $0.name }
        }

        var schemeNames: [String] = []
        if let sharedSchemes = xcodeProj.sharedData?.schemes {
            schemeNames.append(contentsOf: sharedSchemes.map { $0.name })
        }
        for userData in xcodeProj.userData {
            schemeNames.append(contentsOf: userData.schemes.map { $0.name })
        }

        collectSchemesFromDisk(root: projectUrl, into: &schemeNames)

        return ProjectInfo(
            name: projectName,
            schemes: uniqueList(schemeNames),
            targets: uniqueList(targetNames)
        )
    }

    private static func inspectWorkspace(at workspaceUrl: URL, in directory: URL) throws
        -> ProjectInfo
    {
        let workspaceName = workspaceUrl.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var allSchemes: [String] = []
        var allTargets: [String] = []

        // 1. Workspace-level schemes (shared + user)
        collectSchemesFromDisk(root: workspaceUrl, into: &allSchemes)

        // 2. Discover child projects
        var candidateProjects: [URL] = []
        let parentDir = workspaceUrl.deletingLastPathComponent()

        // A. Companion project
        let companion = parentDir.appendingPathComponent("\(workspaceName).xcodeproj")
        if fm.fileExists(atPath: companion.path) {
            candidateProjects.append(companion)
        }

        // B. Inspect contents.xcworkspacedata for referenced .xcodeproj paths
        let contentsDataUrl = workspaceUrl.appendingPathComponent("contents.xcworkspacedata")
        if let content = try? String(contentsOf: contentsDataUrl, encoding: .utf8) {
            let pattern = #"location\s*=\s*"[^"]*?:?([^"]+\.xcodeproj)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(
                    in: content, range: NSRange(content.startIndex..., in: content))
                for match in matches where match.numberOfRanges > 1 {
                    if let range = Range(match.range(at: 1), in: content) {
                        let relPath = String(content[range])
                        let projUrl = parentDir.appendingPathComponent(relPath)
                        if fm.fileExists(atPath: projUrl.path)
                            && !candidateProjects.contains(projUrl)
                        {
                            candidateProjects.append(projUrl)
                        }
                    }
                }
            }
        }

        // C. Sibling projects in workspace folder (filtering Pods)
        if let siblings = try? fm.contentsOfDirectory(atPath: parentDir.path) {
            for sibling in siblings
            where sibling.hasSuffix(".xcodeproj") && !sibling.lowercased().contains("pods") {
                let siblingUrl = parentDir.appendingPathComponent(sibling)
                if !candidateProjects.contains(siblingUrl) {
                    candidateProjects.append(siblingUrl)
                }
            }
        }

        // 3. Inspect each child project with XcodeProj
        for projUrl in candidateProjects where fm.fileExists(atPath: projUrl.path) {
            if let projInfo = try? inspectSingleProject(at: projUrl) {
                allSchemes.append(contentsOf: projInfo.schemes)
                allTargets.append(contentsOf: projInfo.targets)
            }
        }

        guard !allSchemes.isEmpty || !allTargets.isEmpty else {
            return ProjectInfo(name: workspaceName, schemes: [], targets: [])
        }

        return ProjectInfo(
            name: workspaceName,
            schemes: uniqueList(allSchemes),
            targets: uniqueList(allTargets)
        )
    }

    private static func collectSchemesFromDisk(root: URL, into schemeNames: inout [String]) {
        let fm = FileManager.default
        let sharedDir = root.appendingPathComponent("xcshareddata/xcschemes")
        if let files = try? fm.contentsOfDirectory(atPath: sharedDir.path) {
            for f in files where f.hasSuffix(".xcscheme") {
                schemeNames.append(
                    URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent)
            }
        }

        let userDir = root.appendingPathComponent("xcuserdata")
        if let users = try? fm.contentsOfDirectory(atPath: userDir.path) {
            for u in users {
                let userSchemes = userDir.appendingPathComponent("\(u)/xcschemes")
                if let files = try? fm.contentsOfDirectory(atPath: userSchemes.path) {
                    for f in files where f.hasSuffix(".xcscheme") {
                        schemeNames.append(
                            URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent)
                    }
                }
            }
        }
    }

    private static func uniqueList(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        return result
    }

    // MARK: - Code Signing Settings

    public struct CodeSigningInput: Sendable {
        public let project: String?
        public let targets: [String]?
        public let buildConfigurations: [String]?
        public let useAutomaticSigning: Bool?
        public let teamId: String?
        public let bundleIdentifier: String?
        public let codeSignIdentity: String?
        public let provisioningProfileSpecifier: String?
        public let provisioningProfileUUID: String?

        public init(
            project: String? = nil,
            targets: [String]? = nil,
            buildConfigurations: [String]? = nil,
            useAutomaticSigning: Bool? = nil,
            teamId: String? = nil,
            bundleIdentifier: String? = nil,
            codeSignIdentity: String? = nil,
            provisioningProfileSpecifier: String? = nil,
            provisioningProfileUUID: String? = nil
        ) {
            self.project = project
            self.targets = targets
            self.buildConfigurations = buildConfigurations
            self.useAutomaticSigning = useAutomaticSigning
            self.teamId = teamId
            self.bundleIdentifier = bundleIdentifier
            self.codeSignIdentity = codeSignIdentity
            self.provisioningProfileSpecifier = provisioningProfileSpecifier
            self.provisioningProfileUUID = provisioningProfileUUID
        }
    }

    /// Updates code signing build settings in the specified `.xcodeproj` using exclusively `XcodeProj`.
    @discardableResult
    public static func updateCodeSigningSettings(
        _ input: CodeSigningInput,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> [String] {
        let effectiveProjectPath: String
        if let proj = input.project, !proj.isEmpty {
            effectiveProjectPath = proj
        } else {
            let detected = autoDetect(in: directory)
            if let proj = detected.project {
                effectiveProjectPath = proj
            } else if let ws = detected.workspace {
                let companion = URL(fileURLWithPath: ws).deletingPathExtension()
                    .appendingPathExtension("xcodeproj").path
                if FileManager.default.fileExists(atPath: companion) {
                    effectiveProjectPath = companion
                } else {
                    throw NSError(
                        domain: "XCodeTasks",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not find companion .xcodeproj for workspace '\(ws)'."
                        ]
                    )
                }
            } else {
                throw NSError(
                    domain: "XCodeTasks",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No Xcode project found in current directory or ios/ subdirectory."
                    ]
                )
            }
        }

        let projectPath = Path(effectiveProjectPath)
        let xcodeProj = try XcodeProj(path: projectPath)
        let pbxproj = xcodeProj.pbxproj

        var modifiedTargets: [String] = []

        let targetsToUpdate: [PBXTarget]
        if let filterNames = input.targets, !filterNames.isEmpty {
            targetsToUpdate = pbxproj.nativeTargets.filter { filterNames.contains($0.name) }
        } else {
            targetsToUpdate = pbxproj.nativeTargets
        }

        for target in targetsToUpdate {
            guard let configList = target.buildConfigurationList else { continue }
            var targetModified = false

            for config in configList.buildConfigurations {
                if let configFilter = input.buildConfigurations, !configFilter.isEmpty {
                    guard configFilter.contains(config.name) else { continue }
                }

                if let teamId = input.teamId {
                    config.buildSettings["DEVELOPMENT_TEAM"] = teamId
                    targetModified = true
                }

                if let useAuto = input.useAutomaticSigning {
                    config.buildSettings["CODE_SIGN_STYLE"] = useAuto ? "Automatic" : "Manual"
                    targetModified = true
                }

                if let bundleId = input.bundleIdentifier {
                    config.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] = bundleId
                    targetModified = true
                }

                if let identity = input.codeSignIdentity {
                    config.buildSettings["CODE_SIGN_IDENTITY"] = identity
                    targetModified = true
                }

                if let profileSpecifier = input.provisioningProfileSpecifier {
                    config.buildSettings["PROVISIONING_PROFILE_SPECIFIER"] = profileSpecifier
                    targetModified = true
                }

                if let profileUUID = input.provisioningProfileUUID {
                    config.buildSettings["PROVISIONING_PROFILE"] = profileUUID
                    targetModified = true
                }
            }

            if targetModified {
                modifiedTargets.append(target.name)
            }
        }

        try xcodeProj.writePBXProj(path: projectPath, override: true, outputSettings: PBXOutputSettings())
        return modifiedTargets
    }

    /// Convenience overload for `updateCodeSigningSettings`.
    @discardableResult
    public static func updateCodeSigningSettings(
        project: String? = nil,
        targets: [String]? = nil,
        buildConfigurations: [String]? = nil,
        useAutomaticSigning: Bool? = nil,
        teamId: String? = nil,
        bundleIdentifier: String? = nil,
        codeSignIdentity: String? = nil,
        provisioningProfileSpecifier: String? = nil,
        provisioningProfileUUID: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> [String] {
        try updateCodeSigningSettings(
            CodeSigningInput(
                project: project,
                targets: targets,
                buildConfigurations: buildConfigurations,
                useAutomaticSigning: useAutomaticSigning,
                teamId: teamId,
                bundleIdentifier: bundleIdentifier,
                codeSignIdentity: codeSignIdentity,
                provisioningProfileSpecifier: provisioningProfileSpecifier,
                provisioningProfileUUID: provisioningProfileUUID
            ),
            in: directory
        )
    }

    // MARK: - Manual Code Signing Configuration

    public struct ManualSigningInput: Sendable {
        public let projectPath: String?
        public let workspacePath: String?
        public let scheme: String?
        public let configuration: String
        public let teamId: String?
        public let identity: String?
        public let profilesByBundleId: [String: MatchTask.ProfileInfo]
        public let isDryRun: Bool

        public init(
            projectPath: String? = nil,
            workspacePath: String? = nil,
            scheme: String? = nil,
            configuration: String,
            teamId: String? = nil,
            identity: String? = nil,
            profilesByBundleId: [String: MatchTask.ProfileInfo],
            isDryRun: Bool = false
        ) {
            self.projectPath = projectPath
            self.workspacePath = workspacePath
            self.scheme = scheme
            self.configuration = configuration
            self.teamId = teamId
            self.identity = identity
            self.profilesByBundleId = profilesByBundleId
            self.isDryRun = isDryRun
        }
    }

    public struct TargetSigningResult: Sendable {
        public let targetName: String
        public let bundleId: String
        public let profileName: String
        public let profileUUID: String
        public let configuration: String
        public let identity: String
        public let teamId: String?

        public init(
            targetName: String,
            bundleId: String,
            profileName: String,
            profileUUID: String,
            configuration: String,
            identity: String,
            teamId: String?
        ) {
            self.targetName = targetName
            self.bundleId = bundleId
            self.profileName = profileName
            self.profileUUID = profileUUID
            self.configuration = configuration
            self.identity = identity
            self.teamId = teamId
        }
    }

    /// Updates code signing build settings in the project to manual signing with the specified provisioning profiles and certificate.
    /// Only the target build settings for the specified configuration (e.g., Release) of the selected scheme are modified.
    /// All distributable native targets (applications, app extensions, widget extensions, watch apps, etc.) are updated while
    /// non-signable targets (tests, frameworks, static libraries, dependencies) are skipped.
    @discardableResult
    public static func configureManualSigning(
        _ input: ManualSigningInput,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> [TargetSigningResult] {
        let effectiveProjectPath = try resolveProjectPath(
            projectPath: input.projectPath,
            workspacePath: input.workspacePath,
            in: directory
        )

        let projectPath = Path(effectiveProjectPath)
        let projectUrl = URL(fileURLWithPath: effectiveProjectPath)
        let xcodeProj = try XcodeProj(path: projectPath)
        let pbxproj = xcodeProj.pbxproj

        guard let pbxProject = pbxproj.projects.first else {
            throw NSError(
                domain: "XCodeTasks",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "No PBXProject found in \(effectiveProjectPath)."]
            )
        }

        let signableTargets = pbxproj.nativeTargets.filter { isDistributableTarget($0) }
        var results: [TargetSigningResult] = []

        let effectiveIdentity = input.identity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? input.identity!
            : "Apple Distribution"

        for target in signableTargets {
            guard let configList = target.buildConfigurationList,
                  let targetConfig = configList.buildConfigurations.first(where: { $0.name == input.configuration }) else {
                continue
            }

            // Resolve target's bundle ID for this configuration
            let rawBundleId = targetConfig.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            var resolvedBundleId: String? = isUnresolvedReference(rawBundleId) ? nil : rawBundleId

            if resolvedBundleId == nil {
                if let xcconfigResolved = resolveXcconfigBundleIdentifier(
                    projectUrl: projectUrl,
                    xcodeProj: xcodeProj,
                    target: target,
                    configurationName: input.configuration,
                    rawBundleId: rawBundleId
                ) {
                    resolvedBundleId = xcconfigResolved
                }
            }

            // Fallback: search rawBundleId or target's other configurations or target name
            let candidateBundleId = resolvedBundleId ?? rawBundleId ?? ""

            // Match provisioning profile
            let matchedProfile: MatchTask.ProfileInfo? = {
                if !candidateBundleId.isEmpty, let p = input.profilesByBundleId[candidateBundleId] {
                    return p
                }
                if !candidateBundleId.isEmpty,
                   let p = input.profilesByBundleId.first(where: { $0.key.caseInsensitiveCompare(candidateBundleId) == .orderedSame })?.value {
                    return p
                }
                // If only 1 profile installed and this is single signable target or the application target
                if input.profilesByBundleId.count == 1 && (signableTargets.count == 1 || isApplicationTarget(target)) {
                    return input.profilesByBundleId.values.first
                }
                return nil
            }()

            guard let profile = matchedProfile else {
                // Skip targets that have no matching profile
                continue
            }

            // Determine team ID
            let targetTeamId: String? = {
                if let t = input.teamId, !t.isEmpty { return t }
                if let t = targetConfig.buildSettings["DEVELOPMENT_TEAM"] as? String, !t.isEmpty, !isUnresolvedReference(t) {
                    return t
                }
                if let attrs = pbxProject.attributes(for: target),
                   let t = attrs["DevelopmentTeam"] as? String, !t.isEmpty {
                    return t
                }
                return nil
            }()

            // Update buildSettings for this specific configuration
            targetConfig.buildSettings["CODE_SIGN_STYLE"] = "Manual"
            targetConfig.buildSettings["CODE_SIGN_IDENTITY"] = effectiveIdentity
            if let teamId = targetTeamId {
                targetConfig.buildSettings["DEVELOPMENT_TEAM"] = teamId
            }
            targetConfig.buildSettings["PROVISIONING_PROFILE_SPECIFIER"] = profile.name
            targetConfig.buildSettings["PROVISIONING_PROFILE"] = profile.uuid

            // Harmonize any sdk=iphoneos* specific overrides
            if targetConfig.buildSettings["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] != nil {
                targetConfig.buildSettings["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = effectiveIdentity
            }
            if targetConfig.buildSettings["PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]"] != nil {
                targetConfig.buildSettings["PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]"] = profile.name
            }
            if targetConfig.buildSettings["PROVISIONING_PROFILE[sdk=iphoneos*]"] != nil {
                targetConfig.buildSettings["PROVISIONING_PROFILE[sdk=iphoneos*]"] = profile.uuid
            }

            // Update PBXProject targetAttributes for this target
            var targetAttrs = pbxProject.attributes(for: target) ?? [:]
            targetAttrs["ProvisioningStyle"] = "Manual"
            if let teamId = targetTeamId {
                targetAttrs["DevelopmentTeam"] = teamId
            }
            pbxProject.setTargetAttributes(targetAttrs, target: target)

            results.append(
                TargetSigningResult(
                    targetName: target.name,
                    bundleId: resolvedBundleId ?? profile.bundleId,
                    profileName: profile.name,
                    profileUUID: profile.uuid,
                    configuration: input.configuration,
                    identity: effectiveIdentity,
                    teamId: targetTeamId
                )
            )
        }

        if !input.isDryRun && !results.isEmpty {
            try xcodeProj.writePBXProj(path: projectPath, override: true, outputSettings: PBXOutputSettings())
        }

        return results
    }

    // MARK: - iOS Bundle Identifiers Resolution

    public enum ConfigurationSource: String, Sendable, Codable {
        case buildSettings = "build_settings"
        case xcodebuild = "xcodebuild"
        case xcconfig = "xcconfig"
    }

    public struct ResolvedTargetInfo: Sendable, Codable {
        public let name: String
        public let bundleId: String
        public let productType: String?
        public let configurationSource: ConfigurationSource?

        enum CodingKeys: String, CodingKey {
            case name
            case bundleId = "bundle_id"
            case productType
            case configurationSource
        }

        public init(
            name: String,
            bundleId: String,
            productType: String?,
            configurationSource: ConfigurationSource?
        ) {
            self.name = name
            self.bundleId = bundleId
            self.productType = productType
            self.configurationSource = configurationSource
        }
    }

    public struct IosSchemeInfo: Sendable, Codable {
        public let scheme: String
        public let configuration: String
        public let mainAppTargetName: String?
        public let bundleId: String?
        public let version: String?
        public let buildNumber: String?
        public let buildableNames: [String]
        public let targets: [ResolvedTargetInfo]

        public init(
            scheme: String,
            configuration: String,
            mainAppTargetName: String?,
            bundleId: String?,
            version: String?,
            buildNumber: String?,
            buildableNames: [String],
            targets: [ResolvedTargetInfo]
        ) {
            self.scheme = scheme
            self.configuration = configuration
            self.mainAppTargetName = mainAppTargetName
            self.bundleId = bundleId
            self.version = version
            self.buildNumber = buildNumber
            self.buildableNames = buildableNames
            self.targets = targets
        }
    }

    public struct IosIdentifiersResult: Sendable, Codable {
        public let workspaceName: String
        public let scheme: String
        public let configuration: String
        public let mainAppTargetName: String?
        public let bundleId: String?
        public let buildableNames: [String]
        public let targets: [ResolvedTargetInfo]
        public let iosRoot: URL
        public let version: String?
        public let buildNumber: String?
        public let schemes: [IosSchemeInfo]?

        enum CodingKeys: String, CodingKey {
            case workspaceName
            case scheme
            case configuration
            case mainAppTargetName
            case bundleId
            case buildableNames
            case targets
            case iosRoot
            case version
            case buildNumber
            case schemes
        }

        public init(
            workspaceName: String,
            scheme: String,
            configuration: String,
            mainAppTargetName: String?,
            bundleId: String?,
            buildableNames: [String],
            targets: [ResolvedTargetInfo],
            iosRoot: URL,
            version: String? = nil,
            buildNumber: String? = nil,
            schemes: [IosSchemeInfo]? = nil
        ) {
            self.workspaceName = workspaceName
            self.scheme = scheme
            self.configuration = configuration
            self.mainAppTargetName = mainAppTargetName
            self.bundleId = bundleId
            self.buildableNames = buildableNames
            self.targets = targets
            self.iosRoot = iosRoot
            self.version = version
            self.buildNumber = buildNumber
            self.schemes = schemes
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(workspaceName, forKey: .workspaceName)
            try container.encode(scheme, forKey: .scheme)
            try container.encode(configuration, forKey: .configuration)
            try container.encodeIfPresent(mainAppTargetName, forKey: .mainAppTargetName)
            try container.encodeIfPresent(bundleId, forKey: .bundleId)
            try container.encode(buildableNames, forKey: .buildableNames)
            try container.encode(targets, forKey: .targets)
            try container.encode(iosRoot.path, forKey: .iosRoot)
            try container.encodeIfPresent(version, forKey: .version)
            try container.encodeIfPresent(buildNumber, forKey: .buildNumber)
            try container.encodeIfPresent(schemes, forKey: .schemes)
        }
    }

    public struct GetIosIdentifiersOptions: Sendable {
        public let workspaceRoot: URL
        public let workspaceName: String?
        public let scheme: String?
        public let configuration: String?

        public init(
            workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            workspaceName: String? = nil,
            scheme: String? = nil,
            configuration: String? = nil
        ) {
            self.workspaceRoot = workspaceRoot
            self.workspaceName = workspaceName
            self.scheme = scheme
            self.configuration = configuration
        }
    }

    /// Detects workspace/project, resolves scheme, targets, and extracts iOS bundle identifiers.
    /// Follows the 3-tier resolution strategy: buildSettings -> xcodebuild -showBuildSettings -> xcconfig.
    public static func getIosIdentifiers(
        workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        workspaceName: String? = nil,
        scheme: String? = nil,
        configuration: String? = nil
    ) async throws -> IosIdentifiersResult {
        try await getIosIdentifiers(
            GetIosIdentifiersOptions(
                workspaceRoot: workspaceRoot,
                workspaceName: workspaceName,
                scheme: scheme,
                configuration: configuration
            )
        )
    }

    private static func resolveWorkspaceProjectContext(
        workspaceRoot: URL,
        workspaceName explicitWorkspaceName: String?
    ) throws -> (resolvedWorkspaceName: String, iosRoot: URL, projectUrl: URL, workspaceUrl: URL) {
        let fm = FileManager.default
        let iosDir =
            fm.fileExists(atPath: workspaceRoot.appendingPathComponent("ios").path)
            ? workspaceRoot.appendingPathComponent("ios")
            : workspaceRoot

        var workspaceName = explicitWorkspaceName
        if workspaceName == nil || workspaceName?.isEmpty == true {
            let detected = autoDetect(in: iosDir)
            if let ws = detected.workspace {
                workspaceName = URL(fileURLWithPath: ws).deletingPathExtension().lastPathComponent
            } else if let proj = detected.project {
                workspaceName = URL(fileURLWithPath: proj).deletingPathExtension().lastPathComponent
            } else if let items = try? fm.contentsOfDirectory(atPath: iosDir.path) {
                if let ws = items.first(where: {
                    $0.hasSuffix(".xcworkspace") && !$0.hasPrefix(".")
                        && !$0.lowercased().hasPrefix("pods")
                }) {
                    workspaceName = (ws as NSString).deletingPathExtension
                } else if let proj = items.first(where: {
                    $0.hasSuffix(".xcodeproj") && !$0.hasPrefix(".")
                        && !$0.lowercased().hasPrefix("pods")
                }) {
                    workspaceName = (proj as NSString).deletingPathExtension
                }
            }
        }

        guard let resolvedWorkspaceName = workspaceName, !resolvedWorkspaceName.isEmpty else {
            throw NSError(
                domain: "XCodeTasks",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Workspace/project name could not be found. Provide options.workspaceName or place project in ios/."
                ]
            )
        }

        let iosRoot: URL
        if fm.fileExists(
            atPath: workspaceRoot.appendingPathComponent("\(resolvedWorkspaceName).xcodeproj").path)
        {
            iosRoot = workspaceRoot
        } else if fm.fileExists(
            atPath: workspaceRoot.appendingPathComponent("ios/\(resolvedWorkspaceName).xcodeproj").path)
        {
            iosRoot = workspaceRoot.appendingPathComponent("ios")
        } else {
            iosRoot = iosDir
        }

        let projectUrl = iosRoot.appendingPathComponent("\(resolvedWorkspaceName).xcodeproj")
        let workspaceUrl = iosRoot.appendingPathComponent("\(resolvedWorkspaceName).xcworkspace")

        guard fm.fileExists(atPath: projectUrl.path) else {
            throw NSError(
                domain: "XCodeTasks",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey: "Xcode project not found at path: \(projectUrl.path)"
                ]
            )
        }

        return (resolvedWorkspaceName, iosRoot, projectUrl, workspaceUrl)
    }

    /// Inspects all available non-Pod/distributable Xcode schemes in the workspace or project and returns
    /// their per-scheme configuration, target, bundle identifier, version, and build number metadata.
    public static func inspectAllIosSchemes(
        workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        workspaceName: String? = nil,
        configuration: String? = nil
    ) async throws -> IosIdentifiersResult {
        let ctx = try resolveWorkspaceProjectContext(
            workspaceRoot: workspaceRoot,
            workspaceName: workspaceName
        )
        let rawSchemes = getAvailableSchemes(iosDir: ctx.iosRoot, workspaceName: ctx.resolvedWorkspaceName)
            .filter { !$0.hasPrefix("Pods_") && !$0.hasPrefix("Pods-") }

        guard !rawSchemes.isEmpty else {
            return try await getIosIdentifiers(
                workspaceRoot: workspaceRoot,
                workspaceName: ctx.resolvedWorkspaceName,
                scheme: nil,
                configuration: configuration
            )
        }

        let xcodeProj = try XcodeProj(path: Path(ctx.projectUrl.path))
        let distributableTargetNames = Set(
            xcodeProj.pbxproj.nativeTargets
                .filter { isDistributableTarget($0) }
                .map(\.name)
        )

        let filteredSchemes = rawSchemes.filter { schemeName in
            let buildable = extractBuildableNamesFromScheme(
                scheme: schemeName,
                workspaceUrl: ctx.workspaceUrl,
                projectUrl: ctx.projectUrl
            )
            return buildable.isEmpty || !Set(buildable).isDisjoint(with: distributableTargetNames)
        }

        let candidateSchemes = (filteredSchemes.isEmpty ? rawSchemes : filteredSchemes)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var results: [IosIdentifiersResult] = []
        var firstError: Error?

        for schemeName in candidateSchemes {
            do {
                let res = try await getIosIdentifiers(
                    workspaceRoot: workspaceRoot,
                    workspaceName: ctx.resolvedWorkspaceName,
                    scheme: schemeName,
                    configuration: configuration
                )
                results.append(res)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        guard !results.isEmpty else {
            throw firstError!
        }

        let schemeInfos = results.map { res in
            IosSchemeInfo(
                scheme: res.scheme,
                configuration: res.configuration,
                mainAppTargetName: res.mainAppTargetName,
                bundleId: res.bundleId,
                version: res.version,
                buildNumber: res.buildNumber,
                buildableNames: res.buildableNames,
                targets: res.targets
            )
        }

        let primary = results.first(where: {
            $0.scheme.caseInsensitiveCompare(ctx.resolvedWorkspaceName) == .orderedSame
        }) ?? results[0]

        return IosIdentifiersResult(
            workspaceName: primary.workspaceName,
            scheme: primary.scheme,
            configuration: primary.configuration,
            mainAppTargetName: primary.mainAppTargetName,
            bundleId: primary.bundleId,
            buildableNames: primary.buildableNames,
            targets: primary.targets,
            iosRoot: primary.iosRoot,
            version: primary.version,
            buildNumber: primary.buildNumber,
            schemes: schemeInfos
        )
    }

    /// Detects workspace/project, resolves scheme, targets, and extracts iOS bundle identifiers.
    /// Follows the 3-tier resolution strategy: buildSettings -> xcodebuild -showBuildSettings -> xcconfig.
    public static func getIosIdentifiers(
        _ options: GetIosIdentifiersOptions = GetIosIdentifiersOptions()
    ) async throws -> IosIdentifiersResult {
        let fm = FileManager.default
        let wsRoot = options.workspaceRoot
        let ctx = try resolveWorkspaceProjectContext(
            workspaceRoot: wsRoot,
            workspaceName: options.workspaceName
        )
        let resolvedWorkspaceName = ctx.resolvedWorkspaceName
        let iosRoot = ctx.iosRoot
        let projectUrl = ctx.projectUrl
        let workspaceUrl = ctx.workspaceUrl

        // 3. Resolve scheme
        let availableSchemes = getAvailableSchemes(
            iosDir: iosRoot, workspaceName: resolvedWorkspaceName)
        let resolvedScheme: String
        if let explicitScheme = options.scheme?.trimmingCharacters(in: .whitespacesAndNewlines),
            !explicitScheme.isEmpty
        {
            if !availableSchemes.contains(explicitScheme) {
                let candidateScheme1 = projectUrl.appendingPathComponent(
                    "xcshareddata/xcschemes/\(explicitScheme).xcscheme")
                let candidateScheme2 = workspaceUrl.appendingPathComponent(
                    "xcshareddata/xcschemes/\(explicitScheme).xcscheme")
                if !fm.fileExists(atPath: candidateScheme1.path)
                    && !fm.fileExists(atPath: candidateScheme2.path)
                {
                    let availableList =
                        availableSchemes.isEmpty ? "none" : availableSchemes.joined(separator: ", ")
                    throw NSError(
                        domain: "XCodeTasks",
                        code: 12,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Specified Xcode scheme not found: '\(explicitScheme)'. Available schemes: \(availableList)"
                        ]
                    )
                }
            }
            resolvedScheme = explicitScheme
        } else if availableSchemes.contains(resolvedWorkspaceName) {
            resolvedScheme = resolvedWorkspaceName
        } else if let firstNonPods = availableSchemes.first(where: {
            !$0.lowercased().hasPrefix("pods")
        }) {
            resolvedScheme = firstNonPods
        } else if let first = availableSchemes.first {
            resolvedScheme = first
        } else {
            resolvedScheme = resolvedWorkspaceName
        }

        // 4. Load XcodeProj
        let projectPath = Path(projectUrl.path)
        let xcodeProj = try XcodeProj(path: projectPath)

        // 5. Read scheme to extract buildableNames and archive configuration
        let buildableNames = extractBuildableNamesFromScheme(
            scheme: resolvedScheme,
            workspaceUrl: workspaceUrl,
            projectUrl: projectUrl
        )

        let extractedArchiveConfig = extractArchiveConfigurationFromScheme(
            scheme: resolvedScheme,
            workspaceUrl: workspaceUrl,
            projectUrl: projectUrl
        )

        let allDistributableTargets = xcodeProj.pbxproj.nativeTargets.filter {
            isDistributableTarget($0)
        }
        let buildableTargets = allDistributableTargets.filter { buildableNames.contains($0.name) }
        let targets =
            buildableTargets.isEmpty
            ? allDistributableTargets
            : expandBuildableTargets(
                buildableTargets: buildableTargets, allTargets: allDistributableTargets)

        let resolvedConfiguration =
            options.configuration
            ?? extractedArchiveConfig
            ?? targets.first?.buildConfigurationList?.defaultConfigurationName
            ?? "Release"

        // 6. Check if any target has unresolved reference in its raw buildSettings
        var xcodebuildSettings: [String: [String: String]]? = nil
        let needsXcodebuildResolution = targets.contains { target in
            let raw = rawBundleIdentifier(for: target, configurationName: resolvedConfiguration)
            return isUnresolvedReference(raw)
        }

        if needsXcodebuildResolution {
            let wsPathString = fm.fileExists(atPath: workspaceUrl.path) ? workspaceUrl.path : nil
            let projPathString = projectUrl.path
            if let output = await captureXcodebuildBuildSettings(
                workspacePath: wsPathString,
                projectPath: wsPathString == nil ? projPathString : nil,
                scheme: resolvedScheme,
                configurationName: resolvedConfiguration,
                workingDirectory: wsRoot
            ) {
                xcodebuildSettings = parseXcodebuildBuildSettings(output)
            }
        }

        // 7. Resolve mainAppTargetName
        let mainAppTargetName = inferMainAppTargetName(
            targets: targets,
            scheme: resolvedScheme,
            buildableNames: buildableNames
        )

        // 8. Resolve bundle identifier for each target
        var resolvedTargets: [ResolvedTargetInfo] = []

        for target in targets {
            let rawBundleId = rawBundleIdentifier(
                for: target, configurationName: resolvedConfiguration)
            var finalBundleId: String? = isUnresolvedReference(rawBundleId) ? nil : rawBundleId
            var source: ConfigurationSource? = finalBundleId != nil ? .buildSettings : nil

            // Strategy 2: xcodebuild -showBuildSettings
            if finalBundleId == nil,
                let xcb = xcodebuildSettings?[target.name]?["PRODUCT_BUNDLE_IDENTIFIER"],
                !xcb.isEmpty
            {
                finalBundleId = xcb
                source = .xcodebuild
            }

            // Strategy 3: xcconfig resolution
            if finalBundleId == nil {
                if let xcconfigResolved = resolveXcconfigBundleIdentifier(
                    projectUrl: projectUrl,
                    xcodeProj: xcodeProj,
                    target: target,
                    configurationName: resolvedConfiguration,
                    rawBundleId: rawBundleId
                ) {
                    finalBundleId = xcconfigResolved
                    source = .xcconfig
                }
            }

            guard let confirmedBundleId = finalBundleId, !confirmedBundleId.isEmpty else {
                throw NSError(
                    domain: "XCodeTasks",
                    code: 13,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not resolve PRODUCT_BUNDLE_IDENTIFIER for target '\(target.name)' (productType=\(target.productType?.rawValue ?? "unknown"), configuration=\(resolvedConfiguration))."
                    ]
                )
            }

            resolvedTargets.append(
                ResolvedTargetInfo(
                    name: target.name,
                    bundleId: confirmedBundleId,
                    productType: target.productType?.rawValue,
                    configurationSource: source
                )
            )
        }

        let mainTarget =
            resolvedTargets.first(where: { $0.name == mainAppTargetName }) ?? resolvedTargets.first
        let mainBundleId = mainTarget?.bundleId

        let wsPathIfPresent = fm.fileExists(atPath: workspaceUrl.path) ? workspaceUrl.path : nil
        let targetForVersion = mainAppTargetName ?? mainTarget?.name

        var resolvedVersion: String?
        var resolvedBuildNumber: String?

        if let staticVersion = try? getProjectVersion(
            projectPath: projectUrl.path,
            workspacePath: wsPathIfPresent,
            targetName: targetForVersion,
            configuration: resolvedConfiguration,
            in: wsRoot
        ) {
            resolvedVersion = staticVersion.version
            resolvedBuildNumber = staticVersion.buildNumber
        }

        if resolvedVersion == nil || resolvedBuildNumber == nil {
            if let xcodebuildSettings {
                if let selectedSettings = selectTargetBuildSettings(
                    from: xcodebuildSettings,
                    targetName: targetForVersion,
                    scheme: resolvedScheme
                ) {
                    let evaluated = extractVersionFromBuildSettings(
                        selectedSettings,
                        fallbackProjectDirectory: iosRoot
                    )
                    resolvedVersion = resolvedVersion ?? evaluated.version
                    resolvedBuildNumber = resolvedBuildNumber ?? evaluated.buildNumber
                }
            } else {
                let evaluated = await resolveProjectVersion(
                    projectPath: projectUrl.path,
                    workspacePath: wsPathIfPresent,
                    scheme: resolvedScheme,
                    targetName: targetForVersion,
                    configuration: resolvedConfiguration,
                    in: wsRoot
                )
                resolvedVersion = resolvedVersion ?? evaluated.version
                resolvedBuildNumber = resolvedBuildNumber ?? evaluated.buildNumber
            }
        }

        return IosIdentifiersResult(
            workspaceName: resolvedWorkspaceName,
            scheme: resolvedScheme,
            configuration: resolvedConfiguration,
            mainAppTargetName: mainAppTargetName,
            bundleId: mainBundleId,
            buildableNames: buildableNames,
            targets: resolvedTargets,
            iosRoot: iosRoot,
            version: resolvedVersion,
            buildNumber: resolvedBuildNumber
        )
    }

    // MARK: - Private Resolution Helpers

    private static let excludedProductTypes: Set<String> = [
        "com.apple.product-type.bundle",
        "com.apple.product-type.bundle.unit-test",
        "com.apple.product-type.bundle.ui-testing",
        "com.apple.product-type.framework",
        "com.apple.product-type.framework.static",
        "com.apple.product-type.library.dynamic",
        "com.apple.product-type.library.static",
        "com.apple.product-type.tool",
        "com.apple.product-type.xpc-service",
    ]

    private static let distributableKeywords = [
        "application",
        "app-extension",
        "extension",
        "messages-extension",
        "widgetkit-extension",
        "watchkit2-extension",
    ]

    public static func isDistributableTarget(_ target: PBXNativeTarget) -> Bool {
        guard let pType = target.productType?.rawValue else { return false }
        if excludedProductTypes.contains(pType) { return false }
        return distributableKeywords.contains { pType.contains($0) }
    }

    public static func isApplicationTarget(_ target: PBXNativeTarget) -> Bool {
        target.productType == .application
    }

    private static func expandBuildableTargets(
        buildableTargets: [PBXNativeTarget],
        allTargets: [PBXNativeTarget]
    ) -> [PBXNativeTarget] {
        var expanded: [PBXNativeTarget] = buildableTargets
        for target in buildableTargets {
            // 1. Dependencies
            for dep in target.dependencies {
                if let depNative = dep.target as? PBXNativeTarget,
                    !expanded.contains(where: { $0.uuid == depNative.uuid })
                {
                    expanded.append(depNative)
                }
            }

            // 2. Embedded appex build phases
            for phase in target.buildPhases {
                guard let copyPhase = phase as? PBXCopyFilesBuildPhase else { continue }
                let isAppexPhase =
                    copyPhase.dstSubfolderSpec == .plugins
                    || "\(copyPhase.dstSubfolderSpec ?? .resources)".contains("13")
                    || "\(copyPhase.dstSubfolderSpec ?? .resources)".contains("plugin")

                if isAppexPhase, let files = copyPhase.files {
                    for f in files {
                        let name = f.file?.name ?? f.file?.path ?? ""
                        if name.hasSuffix(".appex") {
                            let appexName = (name as NSString).deletingPathExtension
                            if let candidate = allTargets.first(where: {
                                $0.name == appexName || $0.productName == appexName
                                    || $0.product?.name == name
                            }), !expanded.contains(where: { $0.uuid == candidate.uuid }) {
                                expanded.append(candidate)
                            }
                        }
                    }
                }
            }
        }
        return expanded
    }

    private static func isUnresolvedReference(_ value: String?) -> Bool {
        guard let val = value?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else {
            return false
        }
        return val.contains("$(") || val.contains("${")
    }

    private static func rawBundleIdentifier(for target: PBXNativeTarget, configurationName: String)
        -> String?
    {
        let config =
            target.buildConfigurationList?.buildConfigurations.first(where: {
                $0.name == configurationName
            })
            ?? target.buildConfigurationList?.buildConfigurations.first
        return config?.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
    }

    private static func inferMainAppTargetName(
        targets: [PBXNativeTarget],
        scheme: String,
        buildableNames: [String]
    ) -> String? {
        let appTargets = targets.filter { isApplicationTarget($0) }
        if appTargets.isEmpty { return nil }

        if let schemeMatch = appTargets.first(where: { $0.name == scheme }) {
            return schemeMatch.name
        }

        if let buildableMatch = appTargets.first(where: { buildableNames.contains($0.name) }) {
            return buildableMatch.name
        }

        return appTargets.first?.name
    }

    private static func getAvailableSchemes(iosDir: URL, workspaceName: String) -> [String] {
        var schemes: [String] = []
        let fm = FileManager.default

        let scanDir: (URL) -> Void = { dir in
            guard fm.fileExists(atPath: dir.path),
                let files = try? fm.contentsOfDirectory(atPath: dir.path)
            else { return }
            for file in files where file.hasSuffix(".xcscheme") {
                let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
                if !schemes.contains(name) {
                    schemes.append(name)
                }
            }
        }

        // Shared schemes
        scanDir(
            iosDir.appendingPathComponent("\(workspaceName).xcworkspace/xcshareddata/xcschemes"))
        scanDir(iosDir.appendingPathComponent("\(workspaceName).xcodeproj/xcshareddata/xcschemes"))

        // User schemes
        for rootName in ["\(workspaceName).xcworkspace", "\(workspaceName).xcodeproj"] {
            let userData = iosDir.appendingPathComponent("\(rootName)/xcuserdata")
            if let userDirs = try? fm.contentsOfDirectory(atPath: userData.path) {
                for u in userDirs {
                    scanDir(userData.appendingPathComponent("\(u)/xcschemes"))
                }
            }
        }

        return schemes.filter { !$0.hasPrefix("Pods-") }
    }

    private static func getCandidateSchemePaths(scheme: String, workspaceUrl: URL, projectUrl: URL)
        -> [URL]
    {
        var paths = [
            workspaceUrl.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme"),
            projectUrl.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme"),
        ]
        let fm = FileManager.default
        for root in [workspaceUrl, projectUrl] {
            let userDir = root.appendingPathComponent("xcuserdata")
            if let users = try? fm.contentsOfDirectory(atPath: userDir.path) {
                for u in users {
                    paths.append(
                        userDir.appendingPathComponent("\(u)/xcschemes/\(scheme).xcscheme"))
                }
            }
        }
        return paths.filter { fm.fileExists(atPath: $0.path) }
    }

    private static func extractBuildableNamesFromScheme(
        scheme: String,
        workspaceUrl: URL,
        projectUrl: URL
    ) -> [String] {
        let candidatePaths = getCandidateSchemePaths(
            scheme: scheme, workspaceUrl: workspaceUrl, projectUrl: projectUrl)
        for path in candidatePaths {
            guard let content = try? String(contentsOf: path, encoding: .utf8) else { continue }
            var names: [String] = []
            let pattern = #"BlueprintName\s*=\s*"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(
                    in: content, range: NSRange(content.startIndex..., in: content))
                for match in matches where match.numberOfRanges > 1 {
                    if let range = Range(match.range(at: 1), in: content) {
                        let name = String(content[range])
                        if !names.contains(name) {
                            names.append(name)
                        }
                    }
                }
            }
            if !names.isEmpty {
                return names
            }
        }
        return []
    }

    private static func extractArchiveConfigurationFromScheme(
        scheme: String,
        workspaceUrl: URL,
        projectUrl: URL
    ) -> String? {
        let candidatePaths = getCandidateSchemePaths(
            scheme: scheme, workspaceUrl: workspaceUrl, projectUrl: projectUrl)
        for path in candidatePaths {
            guard let content = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let pattern = #"<ArchiveAction[\s\S]*?buildConfiguration\s*=\s*"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: content, range: NSRange(content.startIndex..., in: content)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: content)
            {
                return String(content[range])
            }
        }
        return nil
    }

    private static func captureXcodebuildBuildSettings(
        workspacePath: String?,
        projectPath: String?,
        scheme: String,
        configurationName: String,
        workingDirectory: URL
    ) async -> String? {
        var args = ["-scheme", scheme, "-configuration", configurationName, "-showBuildSettings"]
        if let ws = workspacePath {
            args.append(contentsOf: ["-workspace", ws])
        } else if let proj = projectPath {
            args.append(contentsOf: ["-project", proj])
        }

        do {
            let result = try await ProcessRunner.run(
                "xcrun",
                arguments: ["xcodebuild"] + args,
                workingDirectory: workingDirectory.path,
                discardError: true
            )
            guard result.isSuccess else { return nil }
            return result.stdout
        } catch {
            return nil
        }
    }

    internal static func parseXcodebuildBuildSettings(_ output: String) -> [String: [String: String]]
    {
        var settingsByTarget: [String: [String: String]] = [:]
        var currentTarget: String? = nil

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.contains("Build settings for action") && line.contains("and target") {
                let pattern = #"and target ([^:]+):"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                    let match = regex.firstMatch(
                        in: line, range: NSRange(line.startIndex..., in: line)),
                    let range = Range(match.range(at: 1), in: line)
                {
                    let extracted = String(line[range]).trimmingCharacters(in: .whitespaces)
                    currentTarget = extracted
                    settingsByTarget[extracted] = [:]
                    continue
                }
            }

            if line.hasPrefix("Build settings from command line:") {
                currentTarget = nil
                continue
            }

            guard let current = currentTarget else { continue }

            if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(
                    in: .whitespaces)
                if !key.isEmpty {
                    settingsByTarget[current, default: [:]][key] = value
                }
            }
        }

        return settingsByTarget
    }

    private static func resolveXcconfigBundleIdentifier(
        projectUrl: URL,
        xcodeProj: XcodeProj,
        target: PBXNativeTarget,
        configurationName: String,
        rawBundleId: String?
    ) -> String? {
        var settings: [String: String] = [:]
        settings["TARGET_NAME"] = target.name

        let projectDir = projectUrl.deletingLastPathComponent()

        // 1. Project level build settings & xcconfig
        if let project = xcodeProj.pbxproj.projects.first,
            let projConfig = project.buildConfigurationList?.buildConfigurations.first(where: {
                $0.name == configurationName
            })
        {
            loadXcconfigSettings(
                into: &settings, baseConfig: projConfig.baseConfiguration, projectDir: projectDir)
            for (k, v) in projConfig.buildSettings {
                if let str = v as? String { settings[k] = str }
            }
        }

        // 2. Target level build settings & xcconfig
        if let targetConfig = target.buildConfigurationList?.buildConfigurations.first(where: {
            $0.name == configurationName
        }) {
            loadXcconfigSettings(
                into: &settings, baseConfig: targetConfig.baseConfiguration, projectDir: projectDir)
            for (k, v) in targetConfig.buildSettings {
                if let str = v as? String { settings[k] = str }
            }
        }

        if let raw = rawBundleId {
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = raw
        }

        return getResolvedSettingFromMap(key: "PRODUCT_BUNDLE_IDENTIFIER", settings: settings)
    }

    private static func loadXcconfigSettings(
        into settings: inout [String: String],
        baseConfig: PBXFileReference?,
        projectDir: URL
    ) {
        guard let ref = baseConfig else { return }
        let candidatePath = (try? ref.fullPath(sourceRoot: projectDir.path))
            ?? ref.path.map { relPath in
                relPath.hasPrefix("/")
                    ? relPath
                    : projectDir.appendingPathComponent(relPath).path
            }
        guard let candidatePath else { return }

        var visitedFiles: Set<String> = []
        loadXcconfigFile(
            at: URL(fileURLWithPath: candidatePath),
            projectDir: projectDir,
            into: &settings,
            visitedFiles: &visitedFiles
        )
    }

    private static func loadXcconfigFile(
        at fileURL: URL,
        projectDir: URL,
        into settings: inout [String: String],
        visitedFiles: inout Set<String>
    ) {
        let standardized = fileURL.standardizedFileURL
        guard !visitedFiles.contains(standardized.path),
              FileManager.default.fileExists(atPath: standardized.path),
              let content = try? String(contentsOf: standardized, encoding: .utf8)
        else { return }

        visitedFiles.insert(standardized.path)
        let parentDir = standardized.deletingLastPathComponent()

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }

            if let includePath = parseXcconfigIncludePath(from: trimmed) {
                if let includeUrl = resolveXcconfigIncludeURL(
                    includePath: includePath,
                    relativeTo: parentDir,
                    projectDir: projectDir
                ) {
                    loadXcconfigFile(
                        at: includeUrl,
                        projectDir: projectDir,
                        into: &settings,
                        visitedFiles: &visitedFiles
                    )
                }
                continue
            }

            if let eq = trimmed.firstIndex(of: "=") {
                let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = stripXcconfigInlineComment(String(trimmed[trimmed.index(after: eq)...]))
                    .trimmingCharacters(in: .whitespaces)
                if !k.isEmpty && v != "$(inherited)" && v != "${inherited}" {
                    settings[k] = v
                }
            }
        }
    }

    private static func parseXcconfigIncludePath(from line: String) -> String? {
        let pattern = #"^#include\??\s+["<]([^">]+)[">]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        let path = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func resolveXcconfigIncludeURL(
        includePath: String,
        relativeTo currentDir: URL,
        projectDir: URL
    ) -> URL? {
        if includePath.hasPrefix("/") {
            let abs = URL(fileURLWithPath: includePath)
            return FileManager.default.fileExists(atPath: abs.path) ? abs : nil
        }
        let localCandidate = currentDir.appendingPathComponent(includePath)
        if FileManager.default.fileExists(atPath: localCandidate.path) {
            return localCandidate
        }
        let projectCandidate = projectDir.appendingPathComponent(includePath)
        if FileManager.default.fileExists(atPath: projectCandidate.path) {
            return projectCandidate
        }
        return nil
    }

    private static func stripXcconfigInlineComment(_ value: String) -> String {
        var searchStart = value.startIndex
        while let commentRange = value.range(of: "//", range: searchStart..<value.endIndex) {
            if commentRange.lowerBound == value.startIndex {
                return ""
            }
            let prevIndex = value.index(before: commentRange.lowerBound)
            if value[prevIndex].isWhitespace {
                return String(value[..<commentRange.lowerBound])
            }
            searchStart = commentRange.upperBound
        }
        return value
    }

    internal static func expandBuildSettingValue(
        _ value: String,
        settings: [String: String],
        seen: Set<String> = []
    ) -> String? {
        let pattern = #"\$\(([^)]+)\)|\$\{([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var resolved = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))

        for match in matches.reversed() {
            let varRange =
                match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let swiftVarRange = Range(varRange, in: value),
                  let fullMatchRange = Range(match.range, in: resolved)
            else { continue }

            let rawVarName = String(value[swiftVarRange])
            let settingName = rawVarName.components(separatedBy: ":").first ?? rawVarName

            if settingName == "inherited" {
                continue
            }

            if !seen.contains(settingName), let subValue = settings[settingName] {
                var nextSeen = seen
                nextSeen.insert(settingName)
                if let resolvedSub = expandBuildSettingValue(subValue, settings: settings, seen: nextSeen) {
                    resolved.replaceSubrange(fullMatchRange, with: resolvedSub)
                }
            }
        }

        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func getResolvedSettingFromMap(
        key: String,
        settings: [String: String],
        seen: Set<String> = []
    ) -> String? {
        guard let value = settings[key] else { return nil }
        if seen.contains(key) { return value }
        var nextSeen = seen
        nextSeen.insert(key)
        return expandBuildSettingValue(value, settings: settings, seen: nextSeen)
    }

    // MARK: - Build Number / Version

    public struct UpdateBuildNumberInput: Sendable {
        public let projectPath: String?
        public let workspacePath: String?
        public let buildNumber: String
        public let version: String?
        public let targets: [String]?
        public let configurations: [String]?

        public init(
            projectPath: String? = nil,
            workspacePath: String? = nil,
            buildNumber: String,
            version: String? = nil,
            targets: [String]? = nil,
            configurations: [String]? = nil
        ) {
            self.projectPath = projectPath
            self.workspacePath = workspacePath
            self.buildNumber = buildNumber
            self.version = version
            self.targets = targets
            self.configurations = configurations
        }
    }

    public struct UpdateBuildNumberResult: Sendable {
        public let updatedTargets: [String]
        public let normalizedInfoPlists: [URL]
        public let temporaryBackups: [URL: Data]

        public init(
            updatedTargets: [String] = [],
            normalizedInfoPlists: [URL] = [],
            temporaryBackups: [URL: Data] = [:]
        ) {
            self.updatedTargets = updatedTargets
            self.normalizedInfoPlists = normalizedInfoPlists
            self.temporaryBackups = temporaryBackups
        }
    }

    /// Normalizes literal `CFBundleVersion` values in referenced `Info.plist` files to `$(CURRENT_PROJECT_VERSION)`
    /// without mutating `project.pbxproj`. When any configuration of a target lacks `CURRENT_PROJECT_VERSION`, the
    /// original `Info.plist` bytes are returned in `temporaryBackups` so callers can restore them after building.
    @discardableResult
    public static func updateBuildNumber(
        _ input: UpdateBuildNumberInput,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> UpdateBuildNumberResult {
        let effectiveProjectPath = try resolveProjectPath(
            projectPath: input.projectPath,
            workspacePath: input.workspacePath,
            in: directory
        )

        let projectPath = Path(effectiveProjectPath)
        let xcodeProj = try XcodeProj(path: projectPath)
        let pbxproj = xcodeProj.pbxproj
        let projectDirectory = URL(fileURLWithPath: effectiveProjectPath).deletingLastPathComponent()

        let targetsToUpdate: [PBXNativeTarget]
        if let filterNames = input.targets, !filterNames.isEmpty {
            targetsToUpdate = pbxproj.nativeTargets.filter { filterNames.contains($0.name) }
        } else {
            targetsToUpdate = pbxproj.nativeTargets.filter { isDistributableTarget($0) }
        }

        var updatedTargets: [String] = []
        var modifiedPlists: [URL: (originalData: Data, shouldPersist: Bool)] = [:]

        for target in targetsToUpdate {
            guard let configList = target.buildConfigurationList else { continue }
            let canPersistNormalization = hasCurrentProjectVersion(
                target: target,
                project: pbxproj.projects.first,
                projectDir: projectDirectory
            )
            var targetModified = false

            for config in configList.buildConfigurations {
                if let configFilter = input.configurations, !configFilter.isEmpty {
                    guard configFilter.contains(config.name) else { continue }
                }

                guard let plistUrl = resolveInfoPlistURL(config: config, projectDirectory: projectDirectory) else {
                    continue
                }

                if modifiedPlists[plistUrl] != nil {
                    if !canPersistNormalization {
                        modifiedPlists[plistUrl]?.shouldPersist = false
                    }
                    continue
                }

                if let originalData = syncInfoPlist(at: plistUrl) {
                    modifiedPlists[plistUrl] = (originalData: originalData, shouldPersist: canPersistNormalization)
                    targetModified = true
                }
            }

            if targetModified {
                updatedTargets.append(target.name)
            }
        }

        var normalizedInfoPlists: [URL] = []
        var temporaryBackups: [URL: Data] = [:]
        for (url, entry) in modifiedPlists.sorted(by: { $0.key.path < $1.key.path }) {
            if entry.shouldPersist {
                normalizedInfoPlists.append(url)
            } else {
                temporaryBackups[url] = entry.originalData
            }
        }

        return UpdateBuildNumberResult(
            updatedTargets: updatedTargets,
            normalizedInfoPlists: normalizedInfoPlists,
            temporaryBackups: temporaryBackups
        )
    }

    /// Sets `MARKETING_VERSION` (the App Store version string) on every build configuration of distributable targets,
    /// and on project-level configurations that already define it. Literal `CFBundleShortVersionString` values in
    /// referenced `Info.plist` files are pointed at `$(MARKETING_VERSION)` so the new value takes effect.
    /// Returns the names of the updated targets. `.xcconfig` files are not modified.
    @discardableResult
    public static func updateMarketingVersion(
        _ version: String,
        projectPath: String? = nil,
        workspacePath: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> [String] {
        let effectiveProjectPath = try resolveProjectPath(
            projectPath: projectPath,
            workspacePath: workspacePath,
            in: directory
        )
        let path = Path(effectiveProjectPath)
        let xcodeProj = try XcodeProj(path: path)
        let pbxproj = xcodeProj.pbxproj
        let projectDirectory = URL(fileURLWithPath: effectiveProjectPath).deletingLastPathComponent()

        var updatedTargets: [String] = []
        var syncedPlists = Set<URL>()
        for target in pbxproj.nativeTargets where isDistributableTarget(target) {
            guard let configList = target.buildConfigurationList else { continue }
            for config in configList.buildConfigurations {
                config.buildSettings["MARKETING_VERSION"] = version
                if let plistUrl = resolveInfoPlistURL(config: config, projectDirectory: projectDirectory),
                   syncedPlists.insert(plistUrl).inserted {
                    syncShortVersionString(at: plistUrl)
                }
            }
            updatedTargets.append(target.name)
        }

        if let projectConfigs = pbxproj.projects.first?.buildConfigurationList?.buildConfigurations {
            for config in projectConfigs where config.buildSettings["MARKETING_VERSION"] != nil {
                config.buildSettings["MARKETING_VERSION"] = version
            }
        }

        try xcodeProj.writePBXProj(path: path, override: true, outputSettings: PBXOutputSettings())
        return updatedTargets
    }

    /// Replaces a literal `CFBundleShortVersionString` value in `Info.plist` with `$(MARKETING_VERSION)`.
    /// Values already referencing build settings and binary plists are left untouched.
    private static func syncShortVersionString(at plistUrl: URL) {
        guard let data = try? Data(contentsOf: plistUrl),
              var content = String(data: data, encoding: .utf8) else { return }
        let pattern = "(<key>CFBundleShortVersionString</key>\\s*<string>)([^<]*)(</string>)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let valueRange = Range(match.range(at: 2), in: content) else { return }
        let current = content[valueRange]
        guard !current.contains("$(") && !current.contains("${") else { return }
        content.replaceSubrange(valueRange, with: "$(MARKETING_VERSION)")
        try? content.write(to: plistUrl, atomically: true, encoding: .utf8)
    }

    private static func stringSettingValue(_ value: Any?) -> String? {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let int = value as? Int {
            return String(int)
        }
        if let double = value as? Double {
            return String(double)
        }
        return nil
    }

    private static func mergeRawBuildSettings(
        _ rawSettings: BuildSettings,
        into settings: inout [String: String]
    ) {
        for (key, value) in rawSettings {
            if let rawString = value as? String {
                let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    settings.removeValue(forKey: key)
                } else if trimmed != "$(inherited)" && trimmed != "${inherited}" {
                    settings[key] = trimmed
                }
            } else if let str = stringSettingValue(value) {
                settings[key] = str
            }
        }
    }

    private static func hasCurrentProjectVersion(
        target: PBXNativeTarget,
        project: PBXProject?,
        projectDir: URL
    ) -> Bool {
        guard let targetConfigs = target.buildConfigurationList?.buildConfigurations, !targetConfigs.isEmpty else {
            return false
        }

        return targetConfigs.allSatisfy { targetConfig in
            var settings: [String: String] = [:]

            if let projConfig = project?.buildConfigurationList?.buildConfigurations.first(where: { $0.name == targetConfig.name }) {
                loadXcconfigSettings(into: &settings, baseConfig: projConfig.baseConfiguration, projectDir: projectDir)
                mergeRawBuildSettings(projConfig.buildSettings, into: &settings)
            }

            loadXcconfigSettings(into: &settings, baseConfig: targetConfig.baseConfiguration, projectDir: projectDir)
            mergeRawBuildSettings(targetConfig.buildSettings, into: &settings)

            guard let resolved = getResolvedSettingFromMap(key: "CURRENT_PROJECT_VERSION", settings: settings) else {
                return false
            }
            return !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func resolveInfoPlistURL(config: XCBuildConfiguration, projectDirectory: URL) -> URL? {
        guard var plistRef = config.buildSettings["INFOPLIST_FILE"] as? String, !plistRef.isEmpty else { return nil }

        for variable in ["SRCROOT", "PROJECT_DIR"] {
            plistRef = plistRef
                .replacingOccurrences(of: "$(\(variable))", with: projectDirectory.path)
                .replacingOccurrences(of: "${\(variable)}", with: projectDirectory.path)
        }
        guard !plistRef.contains("$") else { return nil }

        return (plistRef.hasPrefix("/")
            ? URL(fileURLWithPath: plistRef)
            : projectDirectory.appendingPathComponent(plistRef)
        ).standardizedFileURL
    }

    /// Replaces a literal `CFBundleVersion` value in `Info.plist` with `$(CURRENT_PROJECT_VERSION)` and returns
    /// the original raw file bytes. Values already referencing build settings (`$(...)` / `${...}`) and binary plists are skipped.
    private static func syncInfoPlist(at plistUrl: URL) -> Data? {
        guard let originalData = try? Data(contentsOf: plistUrl),
              var content = String(data: originalData, encoding: .utf8) else { return nil }

        let pattern = "(<key>CFBundleVersion</key>\\s*<string>)([^<]*)(</string>)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let valueRange = Range(match.range(at: 2), in: content) else { return nil }

        let current = content[valueRange]
        guard !current.contains("$(") && !current.contains("${") else { return nil }

        content.replaceSubrange(valueRange, with: "$(CURRENT_PROJECT_VERSION)")
        guard (try? content.write(to: plistUrl, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return originalData
    }

    /// Reads the current `CURRENT_PROJECT_VERSION` (build number) and `MARKETING_VERSION` (version string)
    /// from the Xcode project (`.xcodeproj`) using `XcodeProj`, evaluating project/target `.xcconfig` chains,
    /// `buildSettings`, and `Info.plist` variable expansion while ignoring unresolved build-setting references (`$`).
    public static func getProjectVersion(
        projectPath: String? = nil,
        workspacePath: String? = nil,
        targetName: String? = nil,
        configuration: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> (version: String?, buildNumber: String?) {
        let effectiveProjectPath = try resolveProjectPath(
            projectPath: projectPath,
            workspacePath: workspacePath,
            in: directory
        )

        let xcodeProj = try XcodeProj(path: Path(effectiveProjectPath))
        let pbxproj = xcodeProj.pbxproj
        let projectDirectory = URL(fileURLWithPath: effectiveProjectPath).deletingLastPathComponent()

        let selectConfig: (XCConfigurationList?) -> XCBuildConfiguration? = { list in
            guard let list else { return nil }
            if let configuration {
                return list.buildConfigurations.first(where: { $0.name == configuration })
            }
            return list.buildConfigurations.first(where: { $0.name == "Release" })
                ?? list.buildConfigurations.first
        }

        let target = targetName != nil
            ? pbxproj.nativeTargets.first(where: { $0.name == targetName })
            : pbxproj.nativeTargets.first(where: { isApplicationTarget($0) })
                ?? pbxproj.nativeTargets.first(where: { isDistributableTarget($0) })

        let targetConfig = selectConfig(target?.buildConfigurationList)
        let matchingConfigName = configuration ?? targetConfig?.name
        let projConfig: XCBuildConfiguration?
        if let projList = pbxproj.projects.first?.buildConfigurationList {
            if let matchingConfigName {
                projConfig = projList.buildConfigurations.first(where: { $0.name == matchingConfigName })
                    ?? selectConfig(projList)
            } else {
                projConfig = selectConfig(projList)
            }
        } else {
            projConfig = nil
        }

        var settings: [String: String] = [
            "SRCROOT": projectDirectory.path,
            "PROJECT_DIR": projectDirectory.path,
        ]
        if let resolvedTargetName = target?.name ?? targetName {
            settings["TARGET_NAME"] = resolvedTargetName
        }

        if let projConfig {
            loadXcconfigSettings(
                into: &settings,
                baseConfig: projConfig.baseConfiguration,
                projectDir: projectDirectory
            )
            mergeRawBuildSettings(projConfig.buildSettings, into: &settings)
        }

        if let targetConfig {
            loadXcconfigSettings(
                into: &settings,
                baseConfig: targetConfig.baseConfiguration,
                projectDir: projectDirectory
            )
            mergeRawBuildSettings(targetConfig.buildSettings, into: &settings)
        }

        return extractVersionFromBuildSettings(settings, fallbackProjectDirectory: projectDirectory)
    }

    internal static func extractVersionFromBuildSettings(
        _ settings: [String: String],
        fallbackProjectDirectory: URL? = nil
    ) -> (version: String?, buildNumber: String?) {
        let cleanExpanded: (String) -> String? = { raw in
            guard let expanded = expandBuildSettingValue(raw, settings: settings) else {
                return nil
            }
            let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("$") else {
                return nil
            }
            return trimmed
        }

        var resolvedVersion = settings["MARKETING_VERSION"].flatMap(cleanExpanded)
        var resolvedBuildNumber = settings["CURRENT_PROJECT_VERSION"].flatMap(cleanExpanded)

        if (resolvedVersion == nil || resolvedBuildNumber == nil),
           let rawInfoPlist = settings["INFOPLIST_FILE"],
           let expandedInfoPlist = cleanExpanded(rawInfoPlist)
        {
            let plistUrl: URL
            if expandedInfoPlist.hasPrefix("/") {
                plistUrl = URL(fileURLWithPath: expandedInfoPlist)
            } else if let rootDir = settings["PROJECT_DIR"] ?? settings["SRCROOT"] {
                plistUrl = URL(fileURLWithPath: rootDir).appendingPathComponent(expandedInfoPlist)
            } else if let fallbackProjectDirectory {
                plistUrl = fallbackProjectDirectory.appendingPathComponent(expandedInfoPlist)
            } else {
                plistUrl = URL(fileURLWithPath: expandedInfoPlist)
            }

            if let data = try? Data(contentsOf: plistUrl.standardizedFileURL),
               let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            {
                if resolvedVersion == nil,
                   let rawShort = stringSettingValue(plist["CFBundleShortVersionString"])
                {
                    resolvedVersion = cleanExpanded(rawShort)
                }
                if resolvedBuildNumber == nil,
                   let rawBuild = stringSettingValue(plist["CFBundleVersion"])
                {
                    resolvedBuildNumber = cleanExpanded(rawBuild)
                }
            }
        }

        return (version: resolvedVersion, buildNumber: resolvedBuildNumber)
    }

    /// Resolves version and build number via static `.xcodeproj`/`.xcconfig`/`Info.plist` inspection first,
    /// falling back to `xcodebuild -showBuildSettings` only when either field remains unresolved.
    public static func resolveProjectVersion(
        projectPath: String? = nil,
        workspacePath: String? = nil,
        scheme: String? = nil,
        targetName: String? = nil,
        configuration: String? = nil,
        in directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async -> (version: String?, buildNumber: String?) {
        var resolvedVersion: String?
        var resolvedBuildNumber: String?

        if let staticVersion = try? getProjectVersion(
            projectPath: projectPath,
            workspacePath: workspacePath,
            targetName: targetName,
            configuration: configuration,
            in: directory
        ) {
            resolvedVersion = staticVersion.version
            resolvedBuildNumber = staticVersion.buildNumber
        }

        if resolvedVersion != nil && resolvedBuildNumber != nil {
            return (version: resolvedVersion, buildNumber: resolvedBuildNumber)
        }

        var effectiveWorkspace = workspacePath
        var effectiveProject = projectPath
        if effectiveWorkspace == nil && effectiveProject == nil {
            let detected = autoDetect(in: directory)
            effectiveWorkspace = detected.workspace
            effectiveProject = detected.project
        }

        let effectiveScheme = scheme ?? targetName
        let effectiveConfig = configuration ?? "Release"

        guard let effectiveScheme, !effectiveScheme.isEmpty,
              effectiveWorkspace != nil || effectiveProject != nil
        else {
            return (version: resolvedVersion, buildNumber: resolvedBuildNumber)
        }

        let projectDir: URL? = (effectiveProject ?? effectiveWorkspace).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }

        if let output = await captureXcodebuildBuildSettings(
            workspacePath: effectiveWorkspace,
            projectPath: effectiveWorkspace == nil ? effectiveProject : nil,
            scheme: effectiveScheme,
            configurationName: effectiveConfig,
            workingDirectory: directory
        ) {
            let settingsByTarget = parseXcodebuildBuildSettings(output)
            if let selectedSettings = selectTargetBuildSettings(
                from: settingsByTarget,
                targetName: targetName,
                scheme: effectiveScheme
            ) {
                let evaluated = extractVersionFromBuildSettings(
                    selectedSettings,
                    fallbackProjectDirectory: projectDir
                )
                resolvedVersion = resolvedVersion ?? evaluated.version
                resolvedBuildNumber = resolvedBuildNumber ?? evaluated.buildNumber
            }
        }

        return (version: resolvedVersion, buildNumber: resolvedBuildNumber)
    }

    private static func selectTargetBuildSettings(
        from settingsByTarget: [String: [String: String]],
        targetName: String?,
        scheme: String
    ) -> [String: String]? {
        if let targetName, let exact = settingsByTarget[targetName] {
            return exact
        }
        if let schemeMatch = settingsByTarget[scheme] {
            return schemeMatch
        }
        if settingsByTarget.count == 1 {
            return settingsByTarget.values.first
        }
        return nil
    }
}
