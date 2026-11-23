import Foundation
import Testing
@testable import appitool

@Suite("Build Directory Naming Tests")
struct BuildDirectoryNamingTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDirectoryNamingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createMinimalXcodeProject(
        in root: URL,
        targetMarketingVersion: String? = nil,
        targetBuildNumber: String? = nil,
        projectMarketingVersion: String? = nil,
        projectBuildNumber: String? = nil,
        infoPlistShortVersion: String? = nil,
        infoPlistBundleVersion: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let projectDir = root.appendingPathComponent("TestApp.xcodeproj")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let infoPlistUrl = root.appendingPathComponent("TestApp/Info.plist")
        try fm.createDirectory(at: infoPlistUrl.deletingLastPathComponent(), withIntermediateDirectories: true)

        var plistEntries: [String] = []
        if let infoPlistShortVersion {
            plistEntries.append("    <key>CFBundleShortVersionString</key>\n    <string>\(infoPlistShortVersion)</string>")
        }
        if let infoPlistBundleVersion {
            plistEntries.append("    <key>CFBundleVersion</key>\n    <string>\(infoPlistBundleVersion)</string>")
        }

        let infoPlistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(plistEntries.joined(separator: "\n"))
        </dict>
        </plist>
        """
        try infoPlistContent.write(to: infoPlistUrl, atomically: true, encoding: .utf8)

        let projVersionLine = projectMarketingVersion.map { "\t\t\t\tMARKETING_VERSION = \"\($0)\";\n" } ?? ""
        let projBuildLine = projectBuildNumber.map { "\t\t\t\tCURRENT_PROJECT_VERSION = \"\($0)\";\n" } ?? ""
        let targetVersionLine = targetMarketingVersion.map { "\t\t\t\tMARKETING_VERSION = \"\($0)\";\n" } ?? ""
        let targetBuildLine = targetBuildNumber.map { "\t\t\t\tCURRENT_PROJECT_VERSION = \"\($0)\";\n" } ?? ""

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
        \t\t000000000000000000000005 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \(projBuildLine)\(projVersionLine)\t\t\t};
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
        \t\t\t\t000000000000000000000013 /* Release */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        \t\t000000000000000000000013 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \(targetBuildLine)\t\t\t\tINFOPLIST_FILE = "TestApp/Info.plist";
        \(targetVersionLine)\t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t};
        \trootObject = 000000000000000000000001 /* Project object */;
        }
        """

        let pbxprojUrl = projectDir.appendingPathComponent("project.pbxproj")
        try pbxprojContent.write(to: pbxprojUrl, atomically: true, encoding: .utf8)
        return projectDir
    }

    // MARK: - AppitoolPaths.buildTagName & buildDirectory Tests

    @Test("AppitoolPaths.buildTagName formats distribution suffixes without platform prefix")
    func buildTagNameDistributions() {
        #expect(AppitoolPaths.buildTagName(version: "1.2.3", buildNumber: "42", distribution: .appstore) == "1.2.3_42")
        #expect(AppitoolPaths.buildTagName(version: "1.2.3", buildNumber: "42", distribution: .adhoc) == "1.2.3_42_adhoc")
        #expect(AppitoolPaths.buildTagName(version: "1.2.3", buildNumber: "42", distribution: .development) == "1.2.3_42_development")
    }

    @Test("AppitoolPaths.buildTagName normalizes whitespace and sanitizes unsafe path characters")
    func buildTagNameSanitization() {
        #expect(
            AppitoolPaths.buildTagName(version: " 1.2.3  beta ", buildNumber: " 42 ", distribution: .appstore)
                == "1.2.3_beta_42"
        )
        #expect(
            AppitoolPaths.buildTagName(version: "1.0/beta", buildNumber: "42:1", distribution: .adhoc)
                == "1.0_beta_42_1_adhoc"
        )
        #expect(
            AppitoolPaths.buildTagName(version: "../1.0", buildNumber: "7", distribution: .appstore)
                == "__1.0_7"
        )
    }

    @Test("AppitoolPaths.buildTagName returns nil on missing, blank, or unresolved variable values")
    func buildTagNameRejectsInvalidInputs() {
        #expect(AppitoolPaths.buildTagName(version: nil, buildNumber: "42", distribution: .appstore) == nil)
        #expect(AppitoolPaths.buildTagName(version: "1.0.0", buildNumber: nil, distribution: .appstore) == nil)
        #expect(AppitoolPaths.buildTagName(version: "   ", buildNumber: "42", distribution: .appstore) == nil)
        #expect(AppitoolPaths.buildTagName(version: "1.0.0", buildNumber: "\n\t", distribution: .adhoc) == nil)
        #expect(AppitoolPaths.buildTagName(version: "$(MARKETING_VERSION)", buildNumber: "42", distribution: .appstore) == nil)
        #expect(AppitoolPaths.buildTagName(version: "1.0.0", buildNumber: "${VERSION_CODE}", distribution: .appstore) == nil)
    }

    @Test("AppitoolPaths.buildDirectory uses tag name when provided and timestamp fallback when nil or blank")
    func buildDirectoryResolutionAndFallback() throws {
        let tagged = AppitoolPaths.buildDirectory(platform: "ios", target: "MyApp", name: "2.0.1_99_adhoc")
        #expect(
            tagged.path == AppitoolPaths.rootDirectory
                .appendingPathComponent("ios")
                .appendingPathComponent("MyApp")
                .appendingPathComponent("build")
                .appendingPathComponent("2.0.1_99_adhoc")
                .path
        )

        let timestampRegex = try NSRegularExpression(pattern: #"^\d{4}_\d{2}_\d{2}_\d{2}_\d{2}$"#)
        for fallbackName in [nil, "", "   "] as [String?] {
            let dir = AppitoolPaths.buildDirectory(platform: "android", target: "MyApp", name: fallbackName)
            let leaf = dir.lastPathComponent
            let range = NSRange(leaf.startIndex..., in: leaf)
            #expect(timestampRegex.firstMatch(in: leaf, range: range) != nil)
        }
    }

    // MARK: - FlowContext.buildDirectoryName vs releaseTagName Tests

    @Test("FlowContext separates ASCII buildDirectoryName from emoji releaseTagName across platforms and fallbacks")
    func flowContextBuildDirectoryNameVsReleaseTagName() {
        var iosAppStore = FlowContext(platform: .ios, distribution: .appstore)
        iosAppStore.version = "1.4.0"
        iosAppStore.buildNumber = "77"
        #expect(iosAppStore.releaseTagName == "🍏_1.4.0_77")
        #expect(iosAppStore.buildDirectoryName == "1.4.0_77")

        var androidAdHoc = FlowContext(platform: .android, distribution: .adhoc)
        androidAdHoc.version = "2.1.0"
        androidAdHoc.buildNumber = "205"
        #expect(androidAdHoc.releaseTagName == "🤖_2.1.0_205_adhoc")
        #expect(androidAdHoc.buildDirectoryName == "2.1.0_205_adhoc")

        var iosDev = FlowContext(platform: .ios, distribution: .development)
        iosDev.metadata["firebase_version"] = "3.0.0"
        iosDev.metadata["firebase_build_number"] = "12"
        #expect(iosDev.releaseTagName == "🍏_3.0.0_12_development")
        #expect(iosDev.buildDirectoryName == "3.0.0_12_development")

        // Unresolved placeholder in context.version falls back cleanly to metadata
        var unresolvedFallback = FlowContext(platform: .ios, distribution: .appstore)
        unresolvedFallback.version = "$(MARKETING_VERSION)"
        unresolvedFallback.metadata["appstore_version"] = "1.5.0"
        unresolvedFallback.buildNumber = "$(CURRENT_PROJECT_VERSION)"
        unresolvedFallback.metadata["appstore_build_number"] = "88"
        #expect(unresolvedFallback.releaseTagName == "🍏_1.5.0_88")
        #expect(unresolvedFallback.buildDirectoryName == "1.5.0_88")

        // Missing buildNumber yields nil (timestamp fallback at call site)
        var incomplete = FlowContext(platform: .android, distribution: .appstore)
        incomplete.version = "1.0.0"
        #expect(incomplete.releaseTagName == nil)
        #expect(incomplete.buildDirectoryName == nil)
    }

    // MARK: - XCodeTasks.getProjectVersion & XcodeBuildTask.extractVersionInfo Tests

    @Test("XCodeTasks.getProjectVersion merges target, project, and Info.plist while ignoring $ references")
    func xcodeGetProjectVersionFallbacks() throws {
        // 1. Target has buildNumber only, project has marketingVersion
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }

            let projectDir = try createMinimalXcodeProject(
                in: root,
                targetMarketingVersion: "$(inherited)",
                targetBuildNumber: "42",
                projectMarketingVersion: "1.8.0",
                projectBuildNumber: "1",
                infoPlistShortVersion: "0.9.0",
                infoPlistBundleVersion: "$(CURRENT_PROJECT_VERSION)"
            )

            let resolved = try XCodeTasks.getProjectVersion(projectPath: projectDir.path, configuration: "Release", in: root)
            #expect(resolved.version == "1.8.0")
            #expect(resolved.buildNumber == "42")
        }

        // 2. Build settings use placeholders; falls back to literal Info.plist entries
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }

            let projectDir = try createMinimalXcodeProject(
                in: root,
                targetMarketingVersion: "$(FLUTTER_BUILD_NAME)",
                targetBuildNumber: nil,
                projectMarketingVersion: nil,
                projectBuildNumber: "$(FLUTTER_BUILD_NUMBER)",
                infoPlistShortVersion: "2.3.4",
                infoPlistBundleVersion: "56"
            )

            let resolved = try XCodeTasks.getProjectVersion(projectPath: projectDir.path, configuration: "Release", in: root)
            #expect(resolved.version == "2.3.4")
            #expect(resolved.buildNumber == "56")
        }

        // 3. No literal values anywhere returns (nil, nil)
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }

            let projectDir = try createMinimalXcodeProject(
                in: root,
                targetMarketingVersion: "$(MARKETING_VERSION)",
                targetBuildNumber: "$(CURRENT_PROJECT_VERSION)",
                infoPlistShortVersion: "$(MARKETING_VERSION)",
                infoPlistBundleVersion: "$(CURRENT_PROJECT_VERSION)"
            )

            let resolved = try XCodeTasks.getProjectVersion(projectPath: projectDir.path, configuration: "Release", in: root)
            #expect(resolved.version == nil)
            #expect(resolved.buildNumber == nil)
        }
    }

    @Test("XcodeBuildTask.extractVersionInfo reads version and build from .xcarchive Info.plist")
    func extractVersionInfoFromArchive() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let archiveDir = root.appendingPathComponent("TestApp.xcarchive")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "ApplicationProperties": [
                "CFBundleShortVersionString": "2.4.0",
                "CFBundleVersion": "108",
                "Team": "ABCDE12345",
            ]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: archiveDir.appendingPathComponent("Info.plist"))

        let extracted = XcodeBuildTask.extractVersionInfo(fromArchive: archiveDir.path)
        #expect(extracted.version == "2.4.0")
        #expect(extracted.buildNumber == "108")

        let missing = XcodeBuildTask.extractVersionInfo(fromArchive: root.appendingPathComponent("Missing.xcarchive").path)
        #expect(missing.version == nil)
        #expect(missing.buildNumber == nil)
    }

    @Test("XCodeTasks.getProjectVersion resolves grouped .xcconfig chains, composed vars, Info.plist vars, and #include cycles")
    func xcconfigIncludeChainGroupedPathsComposedVarsAndCycles() throws {
        // 1. Flutter-style grouped Flutter/Release.xcconfig -> #include "Generated.xcconfig" -> Info.plist $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER)
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default

            let flutterDir = root.appendingPathComponent("Flutter")
            try fm.createDirectory(at: flutterDir, withIntermediateDirectories: true)
            try """
            // Flutter build settings
            FLUTTER_BUILD_NAME=3.2.1
            FLUTTER_BUILD_NUMBER=145
            """.write(to: flutterDir.appendingPathComponent("Generated.xcconfig"), atomically: true, encoding: .utf8)

            try """
            #include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"
            #include "Generated.xcconfig"
            FLUTTER_BUILD_NAME = $(inherited)
            """.write(to: flutterDir.appendingPathComponent("Release.xcconfig"), atomically: true, encoding: .utf8)

            let runnerDir = root.appendingPathComponent("Runner")
            try fm.createDirectory(at: runnerDir, withIntermediateDirectories: true)
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleShortVersionString</key>
                <string>$(FLUTTER_BUILD_NAME)</string>
                <key>CFBundleVersion</key>
                <string>$(FLUTTER_BUILD_NUMBER)</string>
            </dict>
            </plist>
            """.write(to: runnerDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            let projectDir = root.appendingPathComponent("Runner.xcodeproj")
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
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
            \t\t\t\t000000000000000000000010 /* Runner */,
            \t\t\t);
            \t\t};
            \t\t000000000000000000000002 /* Build configuration list for PBXProject "Runner" */ = {
            \t\t\tisa = XCConfigurationList;
            \t\t\tbuildConfigurations = (
            \t\t\t\t000000000000000000000005 /* Release */,
            \t\t\t);
            \t\t\tdefaultConfigurationIsVisible = 0;
            \t\t\tdefaultConfigurationName = Release;
            \t\t};
            \t\t000000000000000000000003 = {
            \t\t\tisa = PBXGroup;
            \t\t\tchildren = (
            \t\t\t\t000000000000000000000021 /* Flutter */,
            \t\t\t);
            \t\t\tsourceTree = "<group>";
            \t\t};
            \t\t000000000000000000000021 /* Flutter */ = {
            \t\t\tisa = PBXGroup;
            \t\t\tchildren = (
            \t\t\t\t000000000000000000000020 /* Release.xcconfig */,
            \t\t\t);
            \t\t\tpath = Flutter;
            \t\t\tsourceTree = "<group>";
            \t\t};
            \t\t000000000000000000000020 /* Release.xcconfig */ = {
            \t\t\tisa = PBXFileReference;
            \t\t\tlastKnownFileType = text.xcconfig;
            \t\t\tpath = Release.xcconfig;
            \t\t\tsourceTree = "<group>";
            \t\t};
            \t\t000000000000000000000005 /* Release */ = {
            \t\t\tisa = XCBuildConfiguration;
            \t\t\tbuildSettings = {
            \t\t\t};
            \t\t\tname = Release;
            \t\t};
            \t\t000000000000000000000010 /* Runner */ = {
            \t\t\tisa = PBXNativeTarget;
            \t\t\tbuildConfigurationList = 000000000000000000000011;
            \t\t\tbuildPhases = (
            \t\t\t);
            \t\t\tbuildRules = (
            \t\t\t);
            \t\t\tdependencies = (
            \t\t\t);
            \t\t\tname = Runner;
            \t\t\tproductName = Runner;
            \t\t\tproductType = "com.apple.product-type.application";
            \t\t};
            \t\t000000000000000000000011 /* Build configuration list for PBXNativeTarget "Runner" */ = {
            \t\t\tisa = XCConfigurationList;
            \t\t\tbuildConfigurations = (
            \t\t\t\t000000000000000000000013 /* Release */,
            \t\t\t);
            \t\t\tdefaultConfigurationIsVisible = 0;
            \t\t\tdefaultConfigurationName = Release;
            \t\t};
            \t\t000000000000000000000013 /* Release */ = {
            \t\t\tisa = XCBuildConfiguration;
            \t\t\tbaseConfigurationReference = 000000000000000000000020 /* Release.xcconfig */;
            \t\t\tbuildSettings = {
            \t\t\t\tINFOPLIST_FILE = "Runner/Info.plist";
            \t\t\t};
            \t\t\tname = Release;
            \t\t};
            \t};
            \trootObject = 000000000000000000000001 /* Project object */;
            }
            """
            try pbxprojContent.write(to: projectDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

            let resolved = try XCodeTasks.getProjectVersion(projectPath: projectDir.path, configuration: "Release", in: root)
            #expect(resolved.version == "3.2.1")
            #expect(resolved.buildNumber == "145")
        }

        // 2. Composed variables, precedence, inline comment stripping, and cyclic #include termination
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }

            try """
            #include "B.xcconfig"
            APP_MAJOR = 4 // major bump
            MARKETING_VERSION = $(APP_MAJOR).$(APP_MINOR).0
            """.write(to: root.appendingPathComponent("A.xcconfig"), atomically: true, encoding: .utf8)

            try """
            #include "A.xcconfig"
            APP_MINOR = 7
            MARKETING_VERSION = 0.0.0
            CURRENT_PROJECT_VERSION = 222 // build number
            """.write(to: root.appendingPathComponent("B.xcconfig"), atomically: true, encoding: .utf8)

            let projectDir = try createMinimalXcodeProject(
                in: root,
                infoPlistShortVersion: "$(MARKETING_VERSION)",
                infoPlistBundleVersion: "$(CURRENT_PROJECT_VERSION)"
            )
            // Attach A.xcconfig as ungrouped project-relative reference on Release config
            let pbxPath = projectDir.appendingPathComponent("project.pbxproj")
            var pbx = try String(contentsOf: pbxPath, encoding: .utf8)
            pbx = pbx.replacingOccurrences(
                of: "\t\t000000000000000000000013 /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;",
                with: """
                \t\t000000000000000000000030 /* A.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "A.xcconfig"; sourceTree = "<group>"; };
                \t\t000000000000000000000013 /* Release */ = {
                \t\t\tisa = XCBuildConfiguration;
                \t\t\tbaseConfigurationReference = 000000000000000000000030 /* A.xcconfig */;
                """
            )
            try pbx.write(to: pbxPath, atomically: true, encoding: .utf8)

            let resolved = try XCodeTasks.getProjectVersion(projectPath: projectDir.path, configuration: "Release", in: root)
            #expect(resolved.version == "4.7.0")
            #expect(resolved.buildNumber == "222")
        }
    }

    @Test("XCodeTasks parses xcodebuild -showBuildSettings and expands build settings and Info.plist")
    func xcodebuildBuildSettingsParsingAndExtraction() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleDirect = """
        Build settings for action build and target Pods-Runner:
            MARKETING_VERSION = 1.0
            CURRENT_PROJECT_VERSION = 1

        Build settings for action build and target Runner:
            PRODUCT_BUNDLE_IDENTIFIER = com.example.runner
            MARKETING_VERSION = 5.1.0
            CURRENT_PROJECT_VERSION = 90
        """
        let parsedDirect = XCodeTasks.parseXcodebuildBuildSettings(sampleDirect)
        let directSettings = try #require(parsedDirect["Runner"])
        let extractedDirect = XCodeTasks.extractVersionFromBuildSettings(directSettings)
        #expect(extractedDirect.version == "5.1.0")
        #expect(extractedDirect.buildNumber == "90")

        let runnerDir = root.appendingPathComponent("Runner")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>$(FLUTTER_BUILD_NAME)</string>
            <key>CFBundleVersion</key>
            <string>$(FLUTTER_BUILD_NUMBER)</string>
        </dict>
        </plist>
        """.write(to: runnerDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let samplePlist = """
        Build settings for action build and target Runner:
            SRCROOT = \(root.path)
            INFOPLIST_FILE = Runner/Info.plist
            FLUTTER_BUILD_NAME = 6.0.0
            FLUTTER_BUILD_NUMBER = 301
        """
        let parsedPlist = XCodeTasks.parseXcodebuildBuildSettings(samplePlist)
        let plistSettings = try #require(parsedPlist["Runner"])
        let extractedPlist = XCodeTasks.extractVersionFromBuildSettings(plistSettings)
        #expect(extractedPlist.version == "6.0.0")
        #expect(extractedPlist.buildNumber == "301")
    }
}
