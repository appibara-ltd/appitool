import Foundation
import Testing
@testable import appitool

// MARK: - Fixture

/// Generates minimal-but-valid `.xcodeproj` bundles for exercising `XCodeTasks` / `XcodeBuildTask`
/// without ever invoking `xcodebuild` (every distributable target gets a literal bundle ID and
/// static version settings so no `-showBuildSettings` fallback is triggered).
enum XcodeFixture {
    struct Target {
        var name: String
        var productType: String = "com.apple.product-type.application"
        var settings: [String: [String: String]] = [:]
        var xcconfig: String?
        var dependencies: [String] = []
        var embeddedAppex: [String] = []
        var teamAttribute: String?
    }

    static let app = "com.apple.product-type.application"
    static let appex = "com.apple.product-type.app-extension"
    static let unitTest = "com.apple.product-type.bundle.unit-test"

    private final class IDs {
        var next = 1
        func make() -> String {
            defer { next += 1 }
            return String(format: "%024X", next)
        }
    }

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func settingsBlock(_ settings: [String: String]) -> String {
        settings.sorted { $0.key < $1.key }.map { "\(q($0.key)) = \(q($0.value));" }.joined(separator: " ")
    }

    @discardableResult
    static func writeProject(
        name: String,
        in dir: URL,
        targets: [Target],
        projectSettings: [String: [String: String]] = [:],
        projectXcconfig: String? = nil,
        configs: [String] = ["Debug", "Release"]
    ) throws -> URL {
        let ids = IDs()
        var objects: [String] = []
        let projectId = ids.make()
        let projectListId = ids.make()
        let mainGroupId = ids.make()
        var groupChildren: [String] = []

        var xcconfigRefs: [String: String] = [:]
        func xcconfigRef(_ path: String) -> String {
            if let existing = xcconfigRefs[path] { return existing }
            let id = ids.make()
            xcconfigRefs[path] = id
            objects.append("\(id) = { isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = \(q(path)); sourceTree = \(q("<group>")); };")
            groupChildren.append(id)
            return id
        }

        func configList(_ listId: String, settings: [String: [String: String]], xcconfig: String?) {
            var configIds: [String] = []
            for config in configs {
                let cid = ids.make()
                configIds.append(cid)
                let base = xcconfig.map { "baseConfigurationReference = \(xcconfigRef($0)); " } ?? ""
                objects.append("\(cid) = { isa = XCBuildConfiguration; \(base)buildSettings = { \(settingsBlock(settings[config] ?? [:])) }; name = \(q(config)); };")
            }
            objects.append("\(listId) = { isa = XCConfigurationList; buildConfigurations = ( \(configIds.joined(separator: ", ")) ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };")
        }

        configList(projectListId, settings: projectSettings, xcconfig: projectXcconfig)

        var targetIds: [String: String] = [:]
        for target in targets { targetIds[target.name] = ids.make() }

        var attributes: [String] = []
        for target in targets {
            let tid = targetIds[target.name]!
            let listId = ids.make()
            configList(listId, settings: target.settings, xcconfig: target.xcconfig)

            var depIds: [String] = []
            for dep in target.dependencies {
                guard let depTarget = targetIds[dep] else { continue }
                let did = ids.make()
                objects.append("\(did) = { isa = PBXTargetDependency; target = \(depTarget); };")
                depIds.append(did)
            }

            var phaseIds: [String] = []
            if !target.embeddedAppex.isEmpty {
                var fileIds: [String] = []
                for appexName in target.embeddedAppex {
                    let ref = ids.make()
                    objects.append("\(ref) = { isa = PBXFileReference; explicitFileType = \(q("wrapper.app-extension")); includeInIndex = 0; path = \(q(appexName)); sourceTree = BUILT_PRODUCTS_DIR; };")
                    groupChildren.append(ref)
                    let buildFile = ids.make()
                    objects.append("\(buildFile) = { isa = PBXBuildFile; fileRef = \(ref); };")
                    fileIds.append(buildFile)
                }
                let phase = ids.make()
                objects.append("\(phase) = { isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \(q("")); dstSubfolderSpec = 13; files = ( \(fileIds.joined(separator: ", ")) ); name = \(q("Embed Foundation Extensions")); runOnlyForDeploymentPostprocessing = 0; };")
                phaseIds.append(phase)
            }

            objects.append("\(tid) = { isa = PBXNativeTarget; buildConfigurationList = \(listId); buildPhases = ( \(phaseIds.joined(separator: ", ")) ); buildRules = ( ); dependencies = ( \(depIds.joined(separator: ", ")) ); name = \(q(target.name)); productName = \(q(target.name)); productType = \(q(target.productType)); };")

            if let team = target.teamAttribute {
                attributes.append("\(tid) = { DevelopmentTeam = \(q(team)); };")
            }
        }

        objects.append("\(mainGroupId) = { isa = PBXGroup; children = ( \(groupChildren.joined(separator: ", ")) ); sourceTree = \(q("<group>")); };")
        let targetList = targets.map { targetIds[$0.name]! }.joined(separator: ", ")
        objects.append("\(projectId) = { isa = PBXProject; attributes = { TargetAttributes = { \(attributes.joined(separator: " ")) }; }; buildConfigurationList = \(projectListId); compatibilityVersion = \(q("Xcode 14.0")); developmentRegion = en; hasScannedForEncodings = 0; knownRegions = ( en ); mainGroup = \(mainGroupId); projectDirPath = \(q("")); projectRoot = \(q("")); targets = ( \(targetList) ); };")

        let pbxproj = """
        // !$*UTF8*$!
        {
        archiveVersion = 1;
        classes = { };
        objectVersion = 56;
        objects = {
        \(objects.joined(separator: "\n"))
        };
        rootObject = \(projectId);
        }
        """
        let projectDir = dir.appendingPathComponent("\(name).xcodeproj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try pbxproj.write(to: projectDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        return projectDir
    }

    static func schemeXML(blueprints: [String], archiveConfig: String? = "Release", container: String = "App.xcodeproj") -> String {
        let entries = blueprints.map { name in
            """
            <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="ID\(name)" BuildableName="\(name).app" BlueprintName="\(name)" ReferencedContainer="container:\(container)"></BuildableReference>
            </BuildActionEntry>
            """
        }.joined(separator: "\n")
        let archive = archiveConfig.map { "<ArchiveAction buildConfiguration=\"\($0)\" revealArchiveInOrganizer=\"YES\"></ArchiveAction>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="1500" version="1.7">
        <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        <BuildActionEntries>
        \(entries)
        </BuildActionEntries>
        </BuildAction>
        \(archive)
        </Scheme>
        """
    }

    static func writeScheme(_ name: String, in root: URL, blueprints: [String], archiveConfig: String? = "Release", user: String? = nil) throws {
        let dir = user.map { root.appendingPathComponent("xcuserdata/\($0).xcuserdatad/xcschemes") }
            ?? root.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try schemeXML(blueprints: blueprints, archiveConfig: archiveConfig)
            .write(to: dir.appendingPathComponent("\(name).xcscheme"), atomically: true, encoding: .utf8)
    }

    static func writeWorkspace(_ name: String, in dir: URL, projects: [String] = []) throws -> URL {
        let ws = dir.appendingPathComponent("\(name).xcworkspace")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let refs = projects.map { "<FileRef location = \"\($0)\"></FileRef>" }.joined(separator: "\n")
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
        \(refs)
        </Workspace>
        """
        try content.write(to: ws.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        return ws
    }

    /// Standard app project: App (application, embeds Intents.appex, depends on Widget), Widget, Intents, AppTests.
    static func standardTargets() -> [Target] {
        [
            Target(
                name: "App",
                settings: [
                    "Debug": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.app"],
                    "Release": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.app"],
                ],
                dependencies: ["Widget"],
                embeddedAppex: ["Intents.appex"]
            ),
            Target(name: "Widget", productType: appex, settings: [
                "Debug": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.app.widget"],
                "Release": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.app.widget"],
            ]),
            Target(name: "Intents", productType: appex, settings: [
                "Debug": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.app.intents"],
                "Release": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.app.intents"],
            ]),
            Target(name: "AppTests", productType: unitTest, settings: [
                "Release": ["PRODUCT_BUNDLE_IDENTIFIER": "$(UNRESOLVED)"],
            ]),
        ]
    }

    static let versionSettings: [String: [String: String]] = [
        "Debug": ["MARKETING_VERSION": "1.2.3", "CURRENT_PROJECT_VERSION": "7"],
        "Release": ["MARKETING_VERSION": "1.2.3", "CURRENT_PROJECT_VERSION": "7"],
    ]
}

private func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = try TestFiles.makeTempDir("appitool-xcode-cov")
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

private func nsCode(_ error: any Error) -> Int { (error as NSError).code }

// MARK: - Detection & Inspection

@Suite("XCodeTasks Coverage: detection and inspection")
struct XCodeTasksDetectionCoverageTests {
    @Test("autoDetect, hasIosProject and resolveProjectPath cover ios/ subdir, companion, and errors")
    func detection() async throws {
        try await withTempDir { dir in
            #expect(XCodeTasks.autoDetect(in: dir).workspace == nil)
            #expect(!XCodeTasks.hasIosProject(in: dir))
            let noProject = #expect(throws: NSError.self) { try XCodeTasks.resolveProjectPath(in: dir) }
            #expect(noProject?.code == 7)
            #expect(try XCodeTasks.resolveProjectPath(projectPath: "/x/A.xcodeproj", in: dir) == "/x/A.xcodeproj")

            let ios = dir.appendingPathComponent("ios")
            try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
            _ = try XcodeFixture.writeWorkspace("App", in: ios)
            let missingCompanion = #expect(throws: NSError.self) { try XCodeTasks.resolveProjectPath(in: dir) }
            #expect(missingCompanion?.code == 6)

            try XcodeFixture.writeProject(name: "App", in: ios, targets: XcodeFixture.standardTargets())
            let detected = XCodeTasks.autoDetect(in: dir)
            #expect(detected.workspace?.hasSuffix("ios/App.xcworkspace") == true)
            #expect(XCodeTasks.hasIosProject(in: dir))
            #expect(XcodeBuildTask.autoDetect(in: dir).workspace == detected.workspace)
            #expect(try XCodeTasks.resolveProjectPath(in: dir).hasSuffix("ios/App.xcodeproj"))
        }
    }

    @Test("inspectProject reads targets plus shared, user and on-disk schemes for a project")
    func inspectSingleProject() async throws {
        try await withTempDir { dir in
            await #expect(throws: NSError.self) { _ = try await XCodeTasks.inspectProject(in: dir) }

            let proj = try XcodeFixture.writeProject(name: "App", in: dir, targets: XcodeFixture.standardTargets())
            try XcodeFixture.writeScheme("App", in: proj, blueprints: ["App"])
            try XcodeFixture.writeScheme("AppDev", in: proj, blueprints: ["App"], user: "tester")
            try FileManager.default.createDirectory(at: proj.appendingPathComponent("xcuserdata/empty.xcuserdatad"), withIntermediateDirectories: true)

            let info = try await XCodeTasks.inspectProject(in: dir)
            #expect(info.targets == ["App", "Widget", "Intents", "AppTests"])
            #expect(info.schemes.contains("App"))
            #expect(info.schemes.contains("AppDev"))
            #expect(Set(info.schemes).count == info.schemes.count)

            #expect(try await XcodeBuildTask.listTargets(project: proj.path) == info.targets)
            #expect(try await XcodeBuildTask.listSchemes(project: proj.path).contains("App"))
            #expect(try await XcodeBuildTask.inspectProject(project: proj.path).name != nil)
        }
    }

    @Test("inspectProject on a workspace merges companion, referenced, and sibling projects (excluding Pods)")
    func inspectWorkspace() async throws {
        try await withTempDir { dir in
            let ws = try XcodeFixture.writeWorkspace("App", in: dir, projects: ["Sub/Other.xcodeproj", "Missing/None.xcodeproj"])
            try XcodeFixture.writeScheme("WorkspaceScheme", in: ws, blueprints: ["App"])
            let companion = try XcodeFixture.writeProject(name: "App", in: dir, targets: [XcodeFixture.Target(name: "App")])
            try XcodeFixture.writeScheme("App", in: companion, blueprints: ["App"])
            let sub = dir.appendingPathComponent("Sub")
            try XcodeFixture.writeProject(name: "Other", in: sub, targets: [XcodeFixture.Target(name: "OtherTarget")])
            try XcodeFixture.writeProject(name: "Sibling", in: dir, targets: [XcodeFixture.Target(name: "SiblingTarget")])
            try XcodeFixture.writeProject(name: "Pods", in: dir, targets: [XcodeFixture.Target(name: "PodTarget")])

            let info = try await XCodeTasks.inspectProject(workspace: ws.path, in: dir)
            #expect(info.name == "App")
            #expect(info.schemes.first == "WorkspaceScheme")
            #expect(info.schemes.contains("App"))
            #expect(Set(info.targets) == ["App", "OtherTarget", "SiblingTarget"])
        }

        try await withTempDir { dir in
            let ws = try XcodeFixture.writeWorkspace("Empty", in: dir)
            let info = try await XCodeTasks.inspectProject(workspace: ws.path, in: dir)
            #expect(info.name == "Empty" && info.schemes.isEmpty && info.targets.isEmpty)
        }
    }
}

// MARK: - Code signing

@Suite("XCodeTasks Coverage: code signing")
struct XCodeTasksSigningCoverageTests {
    @Test("updateCodeSigningSettings writes all requested settings honoring target and configuration filters")
    func updateCodeSigning() async throws {
        try await withTempDir { dir in
            let proj = try XcodeFixture.writeProject(name: "App", in: dir, targets: XcodeFixture.standardTargets())
            let pbx = proj.appendingPathComponent("project.pbxproj")

            let modified = try XCodeTasks.updateCodeSigningSettings(
                project: proj.path,
                targets: ["App", "Widget"],
                buildConfigurations: ["Release"],
                useAutomaticSigning: false,
                teamId: "TEAM123",
                bundleIdentifier: "com.override",
                codeSignIdentity: "Apple Distribution",
                provisioningProfileSpecifier: "Profile Name",
                provisioningProfileUUID: "UUID-1"
            )
            // XcodeProj's nativeTargets order is not stable, so compare as a set.
            #expect(Set(modified) == ["App", "Widget"])
            let content = try String(contentsOf: pbx, encoding: .utf8)
            #expect(content.contains("TEAM123"))
            #expect(content.contains("CODE_SIGN_STYLE = Manual"))
            #expect(content.contains("UUID-1"))

            // Auto-detected project, all targets, automatic signing, no-op filter on missing config.
            let all = try XCodeTasks.updateCodeSigningSettings(.init(useAutomaticSigning: true), in: dir)
            #expect(all.count == 4)
            let none = try XCodeTasks.updateCodeSigningSettings(.init(buildConfigurations: ["Nope"], teamId: "T"), in: dir)
            #expect(none.isEmpty)
        }

        try await withTempDir { dir in
            let e7 = #expect(throws: NSError.self) { try XCodeTasks.updateCodeSigningSettings(.init(teamId: "T"), in: dir) }
            #expect(e7?.code == 7)
            _ = try XcodeFixture.writeWorkspace("App", in: dir)
            let e6 = #expect(throws: NSError.self) { try XCodeTasks.updateCodeSigningSettings(.init(teamId: "T"), in: dir) }
            #expect(e6?.code == 6)
            try XcodeFixture.writeProject(name: "App", in: dir, targets: [XcodeFixture.Target(name: "App")])
            #expect(try XCodeTasks.updateCodeSigningSettings(.init(teamId: "T"), in: dir) == ["App"])
        }
    }

    private func signingTargets() -> [XcodeFixture.Target] {
        [
            XcodeFixture.Target(name: "App", settings: [
                "Release": [
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
                    "DEVELOPMENT_TEAM": "BUILDTEAM",
                    "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "iPhone Developer",
                    "PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": "old",
                    "PROVISIONING_PROFILE[sdk=iphoneos*]": "old-uuid",
                ],
            ]),
            XcodeFixture.Target(
                name: "Widget",
                productType: XcodeFixture.appex,
                settings: ["Release": ["PRODUCT_BUNDLE_IDENTIFIER": "$(BASE_ID).widget", "DEVELOPMENT_TEAM": "$(TEAM_VAR)"]],
                xcconfig: "Widget.xcconfig",
                teamAttribute: "ATTRTEAM"
            ),
            XcodeFixture.Target(name: "AppTests", productType: XcodeFixture.unitTest, settings: [
                "Release": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.tests"],
            ]),
        ]
    }

    private func profile(_ bundleId: String, _ name: String) -> MatchTask.ProfileInfo {
        MatchTask.ProfileInfo(name: name, uuid: "uuid-\(name)", path: "/p/\(name)", bundleId: bundleId)
    }

    @Test("configureManualSigning matches profiles by exact, case-insensitive, and xcconfig-resolved bundle IDs")
    func manualSigning() async throws {
        try await withTempDir { dir in
            try "BASE_ID = com.example.app // trailing comment\nOTHER = $(inherited)\n"
                .write(to: dir.appendingPathComponent("Widget.xcconfig"), atomically: true, encoding: .utf8)
            let proj = try XcodeFixture.writeProject(
                name: "App", in: dir, targets: signingTargets(),
                projectSettings: ["Release": ["SDKROOT": "iphoneos"]]
            )
            let pbx = proj.appendingPathComponent("project.pbxproj")
            let original = try Data(contentsOf: pbx)
            let profiles = [
                "com.example.app": profile("com.example.app", "AppProfile"),
                "COM.EXAMPLE.APP.WIDGET": profile("com.example.app.widget", "WidgetProfile"),
            ]

            let dry = try XCodeTasks.configureManualSigning(
                .init(projectPath: proj.path, configuration: "Release", profilesByBundleId: profiles, isDryRun: true)
            )
            #expect(dry.count == 2)
            #expect(try Data(contentsOf: pbx) == original)

            let results = try XCodeTasks.configureManualSigning(
                .init(configuration: "Release", profilesByBundleId: profiles), in: dir
            )
            let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.targetName, $0) })
            #expect(byName["App"]?.teamId == "BUILDTEAM")
            #expect(byName["App"]?.identity == "Apple Distribution")
            #expect(byName["Widget"]?.bundleId == "com.example.app.widget")
            #expect(byName["Widget"]?.profileName == "WidgetProfile")
            #expect(byName["Widget"]?.teamId == "ATTRTEAM")
            let written = try String(contentsOf: pbx, encoding: .utf8)
            #expect(written.contains("uuid-AppProfile"))
            #expect(!written.contains("old-uuid"))

            // Explicit identity/team; unknown configuration yields no results.
            let explicit = try XCodeTasks.configureManualSigning(
                .init(projectPath: proj.path, configuration: "Release", teamId: "EXPLICIT", identity: "iPhone Distribution", profilesByBundleId: profiles)
            )
            #expect(explicit.allSatisfy { $0.teamId == "EXPLICIT" && $0.identity == "iPhone Distribution" })
            let missingConfig = try XCodeTasks.configureManualSigning(
                .init(projectPath: proj.path, configuration: "Staging", profilesByBundleId: profiles)
            )
            #expect(missingConfig.isEmpty)

            // A single unmatched profile is applied only to the application target.
            let single = try XCodeTasks.configureManualSigning(
                .init(projectPath: proj.path, configuration: "Release", profilesByBundleId: ["other.id": profile("other.id", "Only")], isDryRun: true)
            )
            #expect(single.map(\.targetName) == ["App"])
            #expect(single.first?.bundleId == "com.example.app")

            // Two unmatched profiles match nothing.
            let none = try XCodeTasks.configureManualSigning(
                .init(projectPath: proj.path, configuration: "Release", profilesByBundleId: ["a": profile("a", "A"), "b": profile("b", "B")])
            )
            #expect(none.isEmpty)
        }
    }

    @Test("configureManualSigning falls back to the profile bundle ID when nothing resolves")
    func manualSigningUnresolved() async throws {
        try await withTempDir { dir in
            let proj = try XcodeFixture.writeProject(name: "Solo", in: dir, targets: [
                XcodeFixture.Target(name: "Solo", settings: ["Release": ["PRODUCT_BUNDLE_IDENTIFIER": "$(MISSING_VAR)"]]),
            ])
            let results = try XCodeTasks.configureManualSigning(
                .init(projectPath: proj.path, configuration: "Release", profilesByBundleId: ["x": profile("com.solo", "SoloProfile")], isDryRun: true)
            )
            #expect(results.count == 1)
            #expect(results.first?.teamId == nil)
        }
    }
}

// MARK: - Identifiers

@Suite("XCodeTasks Coverage: identifiers and versions")
struct XCodeTasksIdentifiersCoverageTests {
    private func makeStandardProject(in root: URL) throws -> URL {
        let ios = root.appendingPathComponent("ios")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        let proj = try XcodeFixture.writeProject(
            name: "App", in: ios, targets: XcodeFixture.standardTargets(),
            projectSettings: XcodeFixture.versionSettings
        )
        try XcodeFixture.writeScheme("App", in: proj, blueprints: ["App"])
        try XcodeFixture.writeScheme("Widget", in: proj, blueprints: ["Widget"], archiveConfig: "Debug")
        try XcodeFixture.writeScheme("AppTests", in: proj, blueprints: ["AppTests"], user: "tester")
        try XcodeFixture.writeScheme("Pods-App", in: proj, blueprints: ["Pods"])
        return proj
    }

    @Test("getIosIdentifiers expands dependencies and embedded app extensions and reads static versions")
    func identifiers() async throws {
        try await withTempDir { root in
            _ = try makeStandardProject(in: root)
            let result = try await XCodeTasks.getIosIdentifiers(workspaceRoot: root)
            #expect(result.scheme == "App")
            #expect(result.configuration == "Release")
            #expect(result.mainAppTargetName == "App")
            #expect(result.bundleId == "com.example.app")
            #expect(Set(result.targets.map(\.name)) == ["App", "Widget", "Intents"])
            #expect(result.targets.allSatisfy { $0.configurationSource == .buildSettings })
            #expect(result.version == "1.2.3")
            #expect(result.buildNumber == "7")
            #expect(result.iosRoot.lastPathComponent == "ios")

            let encoded = try JSONEncoder().encode(result)
            let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            #expect(json?["workspaceName"] as? String == "App")
            #expect((json?["iosRoot"] as? String)?.hasSuffix("ios") == true)

            let widget = try await XCodeTasks.getIosIdentifiers(workspaceRoot: root, workspaceName: "App", scheme: "Widget")
            #expect(widget.configuration == "Debug")
            #expect(widget.mainAppTargetName == nil)
            #expect(widget.bundleId == "com.example.app.widget")

            let error = await #expect(throws: NSError.self) {
                _ = try await XCodeTasks.getIosIdentifiers(workspaceRoot: root, scheme: "Nope")
            }
            #expect(error?.code == 12)
        }
    }

    @Test("inspectAllIosSchemes skips Pods and non-distributable schemes")
    func allSchemes() async throws {
        try await withTempDir { root in
            _ = try makeStandardProject(in: root)
            let result = try await XCodeTasks.inspectAllIosSchemes(workspaceRoot: root)
            #expect(result.scheme == "App")
            #expect(result.schemes?.map(\.scheme) == ["App", "Widget"])
            #expect(result.schemes?.last?.bundleId == "com.example.app.widget")
        }
    }

    @Test("Scheme fallbacks: no schemes, unrelated scheme, and only Pods-like schemes")
    func schemeFallbacks() async throws {
        let targets = [XcodeFixture.Target(name: "Tool", settings: ["Release": ["PRODUCT_BUNDLE_IDENTIFIER": "com.tool"]])]
        try await withTempDir { root in
            try XcodeFixture.writeProject(name: "Tool", in: root, targets: targets, projectSettings: XcodeFixture.versionSettings)
            let res = try await XCodeTasks.getIosIdentifiers(workspaceRoot: root)
            #expect(res.scheme == "Tool")
            #expect(res.buildableNames.isEmpty)
            #expect(res.bundleId == "com.tool")
            let all = try await XCodeTasks.inspectAllIosSchemes(workspaceRoot: root)
            #expect(all.schemes == nil)
        }
        try await withTempDir { root in
            let proj = try XcodeFixture.writeProject(name: "Tool", in: root, targets: targets, projectSettings: XcodeFixture.versionSettings)
            try XcodeFixture.writeScheme("Zeta", in: proj, blueprints: ["Tool"])
            #expect(try await XCodeTasks.getIosIdentifiers(workspaceRoot: root).scheme == "Zeta")
        }
        try await withTempDir { root in
            let proj = try XcodeFixture.writeProject(name: "Tool", in: root, targets: targets, projectSettings: XcodeFixture.versionSettings)
            try XcodeFixture.writeScheme("PodsLike", in: proj, blueprints: ["Tool"])
            #expect(try await XCodeTasks.getIosIdentifiers(workspaceRoot: root).scheme == "PodsLike")
        }
    }

    @Test("Workspace context errors: nothing found, and named project missing")
    func contextErrors() async throws {
        try await withTempDir { root in
            let e10 = await #expect(throws: NSError.self) { _ = try await XCodeTasks.getIosIdentifiers(workspaceRoot: root) }
            #expect(e10?.code == 10)
            let e11 = await #expect(throws: NSError.self) { _ = try await XCodeTasks.getIosIdentifiers(workspaceRoot: root, workspaceName: "Ghost") }
            #expect(e11?.code == 11)
            let all = await #expect(throws: NSError.self) { _ = try await XCodeTasks.inspectAllIosSchemes(workspaceRoot: root) }
            #expect(all?.code == 10)
        }
    }

    @Test("resolveProjectVersion returns static values or stops before xcodebuild without a scheme")
    func resolveProjectVersion() async throws {
        try await withTempDir { root in
            let proj = try XcodeFixture.writeProject(
                name: "App", in: root, targets: XcodeFixture.standardTargets(), projectSettings: XcodeFixture.versionSettings
            )
            let full = await XCodeTasks.resolveProjectVersion(projectPath: proj.path, in: root)
            #expect(full.version == "1.2.3" && full.buildNumber == "7")
        }
        try await withTempDir { root in
            try XcodeFixture.writeProject(name: "App", in: root, targets: [XcodeFixture.Target(name: "App", settings: ["Release": ["MARKETING_VERSION": "2.0"]])])
            let partial = await XCodeTasks.resolveProjectVersion(in: root)
            #expect(partial.version == "2.0")
            #expect(partial.buildNumber == nil)
        }
        try await withTempDir { root in
            let partial = await XCodeTasks.resolveProjectVersion(scheme: "App", in: root)
            #expect(partial.version == nil && partial.buildNumber == nil)
        }
    }
}

// MARK: - XcodeBuildTask

@Suite("XcodeBuildTask Coverage")
struct XcodeBuildTaskCoverageTests {
    private func project(named name: String, schemes: [String], in dir: URL) throws -> URL {
        let proj = try XcodeFixture.writeProject(name: name, in: dir, targets: [XcodeFixture.Target(name: name)])
        for scheme in schemes {
            try XcodeFixture.writeScheme(scheme, in: proj, blueprints: [name])
        }
        return proj
    }

    @Test("resolveScheme priorities: exact, requested, case-insensitive, contains, non-test, tests-only, pods-only")
    func resolveScheme() async throws {
        try await withTempDir { dir in
            let proj = try project(named: "MyApp", schemes: ["MyApp", "MyAppTests", "Pods-X"], in: dir)
            #expect(try await XcodeBuildTask.resolveScheme(requested: nil, workspace: nil, project: proj.path) == "MyApp")
            #expect(try await XcodeBuildTask.resolveScheme(requested: " MyAppTests ", workspace: nil, project: proj.path) == "MyAppTests")
            let notFound = await #expect(throws: XcodeBuildTask.XcodeBuildError.self) {
                _ = try await XcodeBuildTask.resolveScheme(requested: "Nope", workspace: nil, project: proj.path)
            }
            #expect(notFound?.errorDescription?.contains("Nope") == true)

            // Workspace with companion project: requested scheme checked against workspace schemes too.
            let ws = try XcodeFixture.writeWorkspace("MyApp", in: dir)
            try XcodeFixture.writeScheme("WSOnly", in: ws, blueprints: ["MyApp"])
            #expect(try await XcodeBuildTask.resolveScheme(requested: nil, workspace: ws.path, project: nil) == "MyApp")
            #expect(try await XcodeBuildTask.resolveScheme(requested: "WSOnly", workspace: ws.path, project: nil) == "WSOnly")
            await #expect(throws: XcodeBuildTask.XcodeBuildError.self) {
                _ = try await XcodeBuildTask.resolveScheme(requested: "Ghost", workspace: ws.path, project: nil)
            }
        }
        let cases: [(name: String, schemes: [String], expected: String)] = [
            ("Case", ["case"], "case"),
            ("Shop", ["Pods-Shop", "ShopDev"], "ShopDev"),
            ("Alpha", ["BetaTests", "Gamma"], "Gamma"),
            ("Delta", ["EpsilonTests"], "EpsilonTests"),
            ("Zed", ["Pods-One"], "Pods-One"),
        ]
        for testCase in cases {
            try await withTempDir { dir in
                let proj = try project(named: testCase.name, schemes: testCase.schemes, in: dir)
                #expect(try await XcodeBuildTask.resolveScheme(requested: nil, workspace: nil, project: proj.path) == testCase.expected)
            }
        }
        try await withTempDir { dir in
            let proj = try project(named: "Empty", schemes: [], in: dir)
            // No on-disk schemes: project-level inspection still lists none.
            await #expect(throws: XcodeBuildTask.XcodeBuildError.self) {
                _ = try await XcodeBuildTask.resolveScheme(requested: nil, workspace: nil, project: proj.path)
            }
        }
    }

    @Test("resolveMainTarget reads the BlueprintName from project, workspace, and user scheme files")
    func resolveMainTarget() async throws {
        try await withTempDir { dir in
            let proj = try project(named: "App", schemes: ["App"], in: dir)
            #expect(await XcodeBuildTask.resolveMainTarget(forScheme: "App", project: proj.path) == "App")
            let ws = try XcodeFixture.writeWorkspace("App", in: dir)
            try XcodeFixture.writeScheme("Custom", in: ws, blueprints: ["Main"], user: "me")
            #expect(await XcodeBuildTask.resolveMainTarget(forScheme: "Custom", workspace: ws.path) == "Main")
            #expect(await XcodeBuildTask.resolveMainTarget(forScheme: "App", workspace: ws.path) == "App")
        }
    }

    @Test("run with skipped archive and export resolves schemes and archive paths without invoking xcodebuild")
    func runSkipping() async throws {
        try await withTempDir { dir in
            let out = dir.appendingPathComponent("out").path
            let archive = dir.appendingPathComponent("Prebuilt.xcarchive")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

            let explicit = try await XcodeBuildTask().run(.init(scheme: "S", outputDirectory: out, archivePath: archive.path, skipBuildArchive: true, skipPackageIpa: true))
            #expect(explicit.archivePath == archive.path)
            #expect(explicit.ipaPath == nil && explicit.outputDirectory == out)

            let fromArchive = try await XcodeBuildTask().run(.init(outputDirectory: out, archivePath: archive.path, skipBuildArchive: true, skipPackageIpa: true))
            #expect(fromArchive.archivePath == archive.path)

            let named = URL(fileURLWithPath: out).appendingPathComponent("Named.xcarchive")
            try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
            let byName = try await XcodeBuildTask().run(.init(outputDirectory: out, outputName: "Named", skipBuildArchive: true, skipPackageIpa: true))
            #expect(byName.archivePath == named.path)

            let proj = try project(named: "Proj", schemes: ["Proj"], in: dir)
            let projArchive = URL(fileURLWithPath: out).appendingPathComponent("Proj.xcarchive")
            try FileManager.default.createDirectory(at: projArchive, withIntermediateDirectories: true)
            let byProject = try await XcodeBuildTask().run(.init(project: proj.path, outputDirectory: out, skipBuildArchive: true, skipPackageIpa: true))
            #expect(byProject.archivePath == projArchive.path)

            await #expect(throws: XcodeBuildTask.XcodeBuildError.self) {
                _ = try await XcodeBuildTask().run(.init(outputDirectory: out, skipBuildArchive: true, skipPackageIpa: true))
            }
            await #expect(throws: XcodeBuildTask.XcodeBuildError.self) {
                _ = try await XcodeBuildTask().run(.init(scheme: "Missing", outputDirectory: out, skipBuildArchive: true, skipPackageIpa: true))
            }
            await #expect(throws: XcodeBuildTask.XcodeBuildError.self) {
                _ = try await XcodeBuildTask().run(.init(outputDirectory: out))
            }
        }
    }

    @Test("buildArchiveArguments includes optional flags")
    func archiveArguments() {
        let args = XcodeBuildTask.buildArchiveArguments(
            input: .init(
                workspace: "/w/App.xcworkspace", outputDirectory: "/o", derivedDataPath: "/dd", clean: true,
                allowProvisioningUpdates: true, codesigningIdentity: "Apple Distribution", exportTeamId: "TEAM",
                xcargs: ["-quiet"]
            ),
            scheme: "App", archivePath: "/o/App.xcarchive"
        )
        #expect(args.starts(with: ["-workspace", "/w/App.xcworkspace"]))
        for expected in ["-derivedDataPath", "clean", "archive", "DEVELOPMENT_TEAM=TEAM", "CODE_SIGN_IDENTITY=Apple Distribution", "-allowProvisioningUpdates", "-quiet"] {
            #expect(args.contains(expected))
        }
    }

    @Test("extractVersionInfo normalizes string, int, double, and unresolved values")
    func versionInfo() async throws {
        try await withTempDir { dir in
            func write(_ props: [String: Any]?) throws -> String {
                let archive = dir.appendingPathComponent("\(UUID().uuidString).xcarchive")
                try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
                if let props {
                    let data = try PropertyListSerialization.data(fromPropertyList: ["ApplicationProperties": props], format: .xml, options: 0)
                    try data.write(to: archive.appendingPathComponent("Info.plist"))
                }
                return archive.path
            }
            let strings = XcodeBuildTask.extractVersionInfo(fromArchive: try write(["CFBundleShortVersionString": " 1.0 ", "CFBundleVersion": "5"]))
            #expect(strings.version == "1.0" && strings.buildNumber == "5")
            let numbers = XcodeBuildTask.extractVersionInfo(fromArchive: try write(["CFBundleShortVersionString": 2.5, "CFBundleVersion": 9]))
            #expect(numbers.version == "2.5" && numbers.buildNumber == "9")
            let unresolved = XcodeBuildTask.extractVersionInfo(fromArchive: try write(["CFBundleShortVersionString": "$(X)", "CFBundleVersion": Data()]))
            #expect(unresolved.version == nil && unresolved.buildNumber == nil)
            let missing = XcodeBuildTask.extractVersionInfo(fromArchive: try write(nil))
            #expect(missing.version == nil)
        }
    }

    @Test("Error descriptions")
    func errors() {
        let errors: [XcodeBuildTask.XcodeBuildError] = [
            .missingWorkspaceOrProject, .schemeNotFound(requested: "a", available: []), .schemeNotFound(requested: "a", available: ["b"]),
            .noSchemesFound, .schemeListFailed("x"), .missingScheme, .archiveNotFound(path: "p"),
            .archiveFailed(exitCode: 1, output: "o"), .exportFailed(exitCode: 2, output: "o"), .ipaNotFound(expectedPath: "p"),
            .ambiguousIpa(paths: ["a", "b"]), .plistSerializationFailed("x"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(XcodeBuildTask.ExportMethod.adHoc.rawValue == "release-testing")
        #expect(XcodeBuildTask.Output(outputDirectory: "/o").ipaPath == nil)
    }
}
