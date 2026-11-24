import Foundation
import Testing
@testable import appitool

@Suite("XCode Build Version & Restore Tests")
struct XCodeBuildVersionTests {

    private enum StubFlowError: Error {
        case boom
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XCodeBuildVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createMinimalXcodeProject(
        in root: URL,
        infoPlistBundleVersion: String,
        targetBuildVersions: (debug: String?, release: String?)
    ) throws -> (projectDir: URL, pbxprojUrl: URL, infoPlistUrl: URL) {
        let fm = FileManager.default
        let projectDir = root.appendingPathComponent("TestApp.xcodeproj")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let infoPlistUrl = root.appendingPathComponent("TestApp/Info.plist")
        try fm.createDirectory(at: infoPlistUrl.deletingLastPathComponent(), withIntermediateDirectories: true)

        let infoPlistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleVersion</key>
            <string>\(infoPlistBundleVersion)</string>
        </dict>
        </plist>
        """
        try infoPlistContent.write(to: infoPlistUrl, atomically: true, encoding: .utf8)

        let debugVersionLine = targetBuildVersions.debug.map { "\t\t\t\tCURRENT_PROJECT_VERSION = \($0);\n" } ?? ""
        let releaseVersionLine = targetBuildVersions.release.map { "\t\t\t\tCURRENT_PROJECT_VERSION = \($0);\n" } ?? ""

        let pbxprojContent = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 56;
        \tobjects = {
        \t\t000000000000000000000001 /* Project object */ = {
        \t\t\tisa = PBXProject;
        \t\t\tbuildConfigurationList = 000000000000000000000002;
        \t\t\tcompatibilityVersion = "Xcode 14.0";
        \t\t\tdevelopmentRegion = en;
        \t\t\thasScannedForEncodings = 0;
        \t\t\tknownRegions = (
        \t\t\t\ten,
        \t\t\t);
        \t\t\tmainGroup = 000000000000000000000003;
        \t\t\tprojectDirPath = "";
        \t\t\tprojectRoot = "";
        \t\t\ttargets = (
        \t\t\t\t000000000000000000000010 /* TestApp */,
        \t\t\t);
        \t\t};
        \t\t000000000000000000000002 /* Build configuration list for PBXProject "TestApp" */ = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\t000000000000000000000004 /* Debug */,
        \t\t\t\t000000000000000000000005 /* Release */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        \t\t000000000000000000000003 = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\t000000000000000000000004 /* Debug */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t};
        \t\t\tname = Debug;
        \t\t};
        \t\t000000000000000000000005 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t\t000000000000000000000010 /* TestApp */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = 000000000000000000000011;
        \t\t\tbuildPhases = (
        \t\t\t);
        \t\t\tbuildRules = (
        \t\t\t);
        \t\t\tdependencies = (
        \t\t\t);
        \t\t\tname = TestApp;
        \t\t\tproductName = TestApp;
        \t\t\tproductType = "com.apple.product-type.application";
        \t\t};
        \t\t000000000000000000000011 /* Build configuration list for PBXNativeTarget "TestApp" */ = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\t000000000000000000000012 /* Debug */,
        \t\t\t\t000000000000000000000013 /* Release */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        \t\t000000000000000000000012 /* Debug */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \(debugVersionLine)\t\t\t\tINFOPLIST_FILE = "TestApp/Info.plist";
        \t\t\t};
        \t\t\tname = Debug;
        \t\t};
        \t\t000000000000000000000013 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \(releaseVersionLine)\t\t\t\tINFOPLIST_FILE = "TestApp/Info.plist";
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t};
        \trootObject = 000000000000000000000001 /* Project object */;
        }
        """

        let pbxprojUrl = projectDir.appendingPathComponent("project.pbxproj")
        try pbxprojContent.write(to: pbxprojUrl, atomically: true, encoding: .utf8)
        return (projectDir, pbxprojUrl, infoPlistUrl)
    }

    @Test("XcodeBuildTask passes CURRENT_PROJECT_VERSION when buildNumber is provided and omits otherwise")
    func archiveArgumentsIncludeBuildNumberOverride() {
        let withBuildNumber = XcodeBuildTask.buildArchiveArguments(
            input: .init(
                project: "/tmp/TestApp.xcodeproj",
                outputDirectory: "/tmp/out",
                buildNumber: "42"
            ),
            scheme: "TestApp",
            archivePath: "/tmp/out/TestApp.xcarchive"
        )
        #expect(withBuildNumber.contains("CURRENT_PROJECT_VERSION=42"))

        let withNil = XcodeBuildTask.buildArchiveArguments(
            input: .init(
                project: "/tmp/TestApp.xcodeproj",
                outputDirectory: "/tmp/out",
                buildNumber: nil
            ),
            scheme: "TestApp",
            archivePath: "/tmp/out/TestApp.xcarchive"
        )
        #expect(!withNil.contains(where: { $0.hasPrefix("CURRENT_PROJECT_VERSION=") }))

        let withEmpty = XcodeBuildTask.buildArchiveArguments(
            input: .init(
                project: "/tmp/TestApp.xcodeproj",
                outputDirectory: "/tmp/out",
                buildNumber: ""
            ),
            scheme: "TestApp",
            archivePath: "/tmp/out/TestApp.xcarchive"
        )
        #expect(!withEmpty.contains(where: { $0.hasPrefix("CURRENT_PROJECT_VERSION=") }))
    }

    @Test("TemporaryFileRestorer snapshots once, restores atomically, and runs via FlowRunner defer on failure")
    func temporaryFileRestorerRestoresOnDemandAndOnFlowFailure() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileUrl = root.appendingPathComponent("sample.txt")
        try "original-content".write(to: fileUrl, atomically: true, encoding: .utf8)

        let restorer = TemporaryFileRestorer(enableSignalHandlers: false)
        try restorer.backup(fileUrl)
        try "mutated-1".write(to: fileUrl, atomically: true, encoding: .utf8)
        try restorer.backup(fileUrl) // First snapshot must win
        #expect(restorer.hasPendingBackups)

        let firstRestore = restorer.restoreAll()
        #expect(firstRestore.count == 1)
        #expect(try String(contentsOf: fileUrl, encoding: .utf8) == "original-content")
        #expect(!restorer.hasPendingBackups)
        #expect(restorer.restoreAll().isEmpty)

        // Verify FlowRunner defer restores modified file when a later stage throws
        let flowFileUrl = root.appendingPathComponent("project.pbxproj")
        try "pbx-original".write(to: flowFileUrl, atomically: true, encoding: .utf8)

        let flowRestorer = TemporaryFileRestorer(enableSignalHandlers: false)
        var context = FlowContext(
            platform: .ios,
            distribution: .appstore,
            projectDirectory: root,
            isDryRun: true,
            fileRestorer: flowRestorer
        )

        let handlers: [FlowStage: any FlowStageHandler] = [
            .prebuild: AnyFlowStageHandler { ctx in
                try ctx.fileRestorer.backup(flowFileUrl)
                try "pbx-mutated".write(to: flowFileUrl, atomically: true, encoding: .utf8)
            },
            .build: AnyFlowStageHandler { _ in
                throw StubFlowError.boom
            },
        ]

        await #expect(throws: StubFlowError.self) {
            try await FlowRunner().run(context: &context, stageHandlers: handlers)
        }
        #expect(try String(contentsOf: flowFileUrl, encoding: .utf8) == "pbx-original")
        #expect(!context.fileRestorer.hasPendingBackups)
    }

    @Test("XCodeTasks.updateMarketingVersion sets MARKETING_VERSION on app targets and is read back")
    func updateMarketingVersionWritesProject() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (projectDir, _, _) = try createMinimalXcodeProject(
            in: root,
            infoPlistBundleVersion: "1",
            targetBuildVersions: (debug: "1", release: "1")
        )

        let targets = try XCodeTasks.updateMarketingVersion("1.0.9", projectPath: projectDir.path, in: root)
        #expect(targets == ["TestApp"])
        let version = try XCodeTasks.getProjectVersion(projectPath: projectDir.path, in: root)
        #expect(version.version == "1.0.9")
        #expect(version.buildNumber == "1")
    }

    @Test("XCodeTasks.updateBuildNumber keeps Info.plist normalized permanently when CURRENT_PROJECT_VERSION exists")
    func updateBuildNumberKeepsNormalizationWhenProjectDefinesCurrentProjectVersion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (projectDir, pbxprojUrl, infoPlistUrl) = try createMinimalXcodeProject(
            in: root,
            infoPlistBundleVersion: "1",
            targetBuildVersions: (debug: "1", release: "1")
        )
        let originalPbx = try Data(contentsOf: pbxprojUrl)

        let result = try XCodeTasks.updateBuildNumber(
            .init(projectPath: projectDir.path, buildNumber: "99", configurations: ["Release"]),
            in: root
        )

        #expect(try Data(contentsOf: pbxprojUrl) == originalPbx)
        #expect(result.updatedTargets == ["TestApp"])
        #expect(result.normalizedInfoPlists == [infoPlistUrl.standardizedFileURL])
        #expect(result.temporaryBackups.isEmpty)

        let updatedPlist = try String(contentsOf: infoPlistUrl, encoding: .utf8)
        #expect(updatedPlist.contains("<string>$(CURRENT_PROJECT_VERSION)</string>"))
        #expect(!updatedPlist.contains("<string>1</string>"))
    }

    @Test("XCodeTasks.updateBuildNumber records temporary backup when CURRENT_PROJECT_VERSION is missing")
    func updateBuildNumberTracksTemporaryBackupWhenProjectLacksCurrentProjectVersion() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (projectDir, pbxprojUrl, infoPlistUrl) = try createMinimalXcodeProject(
            in: root,
            infoPlistBundleVersion: "1",
            targetBuildVersions: (debug: nil, release: nil)
        )
        let originalPbx = try Data(contentsOf: pbxprojUrl)
        let originalPlist = try Data(contentsOf: infoPlistUrl)

        let result = try XCodeTasks.updateBuildNumber(
            .init(projectPath: projectDir.path, buildNumber: "99", configurations: ["Release"]),
            in: root
        )

        #expect(try Data(contentsOf: pbxprojUrl) == originalPbx)
        #expect(result.updatedTargets == ["TestApp"])
        #expect(result.normalizedInfoPlists.isEmpty)
        #expect(result.temporaryBackups == [infoPlistUrl.standardizedFileURL: originalPlist])

        let mutatedPlist = try String(contentsOf: infoPlistUrl, encoding: .utf8)
        #expect(mutatedPlist.contains("<string>$(CURRENT_PROJECT_VERSION)</string>"))

        let restorer = TemporaryFileRestorer(enableSignalHandlers: false)
        for (url, data) in result.temporaryBackups {
            restorer.registerBackup(data, for: url)
        }
        restorer.restoreAll()

        #expect(try Data(contentsOf: infoPlistUrl) == originalPlist)
    }

    @Test("XCodeTasks.updateBuildNumber leaves existing build-setting references untouched")
    func updateBuildNumberSkipsExistingBuildSettingReferences() throws {
        for existingValue in ["$(CURRENT_PROJECT_VERSION)", "$(FLUTTER_BUILD_NUMBER)"] {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }

            let (projectDir, _, infoPlistUrl) = try createMinimalXcodeProject(
                in: root,
                infoPlistBundleVersion: existingValue,
                targetBuildVersions: (debug: nil, release: nil)
            )
            let originalPlist = try Data(contentsOf: infoPlistUrl)

            let result = try XCodeTasks.updateBuildNumber(
                .init(projectPath: projectDir.path, buildNumber: "99", configurations: ["Release"]),
                in: root
            )

            #expect(result.updatedTargets.isEmpty)
            #expect(result.normalizedInfoPlists.isEmpty)
            #expect(result.temporaryBackups.isEmpty)
            #expect(try Data(contentsOf: infoPlistUrl) == originalPlist)
        }
    }
}
