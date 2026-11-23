import ArgumentParser
import Foundation
import Testing
@testable import appitool

@Suite("InspectCommand Tests")
struct InspectCommandTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("InspectCommand parses options including flavor, project-dir, and json")
    func inspectCommandCLIParsing() throws {
        let cmd1 = try InspectCommand.parse([
            "-p", "android",
            "--workspace-name", "MyWorkspace",
            "-s", "MyScheme",
            "-c", "Debug",
            "--flavor", "staging",
            "--project-dir", "/tmp/project",
            "--json",
        ])
        #expect(cmd1.platform == .android)
        #expect(cmd1.workspaceName == "MyWorkspace")
        #expect(cmd1.scheme == "MyScheme")
        #expect(cmd1.configuration == "Debug")
        #expect(cmd1.flavor == "staging")
        #expect(cmd1.projectDir == "/tmp/project")
        #expect(cmd1.json == true)

        let cmd2 = try InspectCommand.parse([
            "--platform", "ios",
            "--flavor", "prod",
            "--project-dir", "/tmp/other",
        ])
        #expect(cmd2.platform == .ios)
        #expect(cmd2.flavor == "prod")
        #expect(cmd2.projectDir == "/tmp/other")
        #expect(cmd2.json == false)

        let rootCmd = try #require(
            try appitool.parseAsRoot(["inspect", "--flavor", "beta", "--json"]) as? InspectCommand
        )
        #expect(rootCmd.flavor == "beta")
        #expect(rootCmd.json == true)

        for removed in [["-f", "staging"], ["-w", "MyWorkspace"], ["-d", "/tmp"], ["--workspace-root", "/tmp"]] {
            #expect(throws: (any Error).self) {
                _ = try InspectCommand.parse(removed)
            }
        }
    }

    @Test("XCodeTasks.getIosIdentifiers includes resolved version and buildNumber and encodes them to JSON")
    func iosIdentifiersIncludesVersionAndBuildNumber() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let projectDir = root.appendingPathComponent("TestApp.xcodeproj")
        let schemesDir = projectDir.appendingPathComponent("xcshareddata/xcschemes")
        try fm.createDirectory(at: schemesDir, withIntermediateDirectories: true)

        let pbxproj = """
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
        \t\t000000000000000000000002 = {
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
        \t\t000000000000000000000011 = {
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
        \t\t\t\tCURRENT_PROJECT_VERSION = "55";
        \t\t\t\tMARKETING_VERSION = "2.1.0";
        \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.example.inspect";
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t};
        \trootObject = 000000000000000000000001 /* Project object */;
        }
        """
        try pbxproj.write(to: projectDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
           <BuildAction>
              <BuildActionEntries>
                 <BuildActionEntry>
                    <BuildableReference BlueprintName = "TestApp">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <ArchiveAction buildConfiguration = "Release">
           </ArchiveAction>
        </Scheme>
        """
        try scheme.write(to: schemesDir.appendingPathComponent("TestApp.xcscheme"), atomically: true, encoding: .utf8)

        let iosResult = try await XCodeTasks.getIosIdentifiers(
            workspaceRoot: root,
            scheme: "TestApp",
            configuration: "Release"
        )
        #expect(iosResult.bundleId == "com.example.inspect")
        #expect(iosResult.version == "2.1.0")
        #expect(iosResult.buildNumber == "55")

        let data = try JSONEncoder().encode(iosResult)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["bundleId"] as? String == "com.example.inspect")
        #expect(json["version"] as? String == "2.1.0")
        #expect(json["buildNumber"] as? String == "55")

        // Verify nil version/buildNumber are omitted cleanly
        let emptyVersionResult = XCodeTasks.IosIdentifiersResult(
            workspaceName: "TestApp",
            scheme: "TestApp",
            configuration: "Release",
            mainAppTargetName: "TestApp",
            bundleId: "com.example.inspect",
            buildableNames: ["TestApp"],
            targets: [],
            iosRoot: root,
            version: nil,
            buildNumber: nil
        )
        let emptyData = try JSONEncoder().encode(emptyVersionResult)
        let emptyJson = try #require(try JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        #expect(emptyJson["version"] == nil)
        #expect(emptyJson["buildNumber"] == nil)
    }

    @Test("Android inspection resolves flavor version overrides and serializes versionName, versionCode, and flavors")
    func androidInspectionFlavorVersionAndJsonEncoding() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let androidAppDir = root.appendingPathComponent("android/app")
        try FileManager.default.createDirectory(at: androidAppDir, withIntermediateDirectories: true)

        let gradle = """
        android {
            namespace "com.example.inspect"
            defaultConfig {
                applicationId "com.example.inspect"
                versionName "1.5.0"
                versionCode 12
            }
            productFlavors {
                staging {
                    applicationIdSuffix ".staging"
                    versionNameSuffix "-staging"
                    versionCode 13
                }
            }
        }
        """
        try gradle.write(to: androidAppDir.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)

        let rawAndroid = try AndroidTasks.getAndroidIdentifiers(workspaceRoot: root)
        let resolvedVersion = await AndroidTasks.resolveProjectVersion(
            in: root,
            flavor: "staging",
            identifiers: rawAndroid
        )
        #expect(resolvedVersion.versionName == "1.5.0-staging")
        #expect(resolvedVersion.versionCode == "13")

        let merged = AndroidTasks.AndroidIdentifiersResult(
            androidRoot: rawAndroid.androidRoot,
            appBuildGradlePath: rawAndroid.appBuildGradlePath,
            manifestPath: rawAndroid.manifestPath,
            namespace: rawAndroid.namespace,
            applicationId: rawAndroid.applicationId,
            packageName: rawAndroid.packageName,
            versionName: resolvedVersion.versionName ?? rawAndroid.versionName,
            versionCode: resolvedVersion.versionCode ?? rawAndroid.versionCode,
            flavors: rawAndroid.flavors
        )

        let data = try JSONEncoder().encode(merged)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["versionName"] as? String == "1.5.0-staging")
        #expect(json["versionCode"] as? String == "13")
        let jsonFlavors = try #require(json["flavors"] as? [[String: Any]])
        #expect(jsonFlavors.count == 1)
        #expect(jsonFlavors[0]["name"] as? String == "staging")
        #expect(jsonFlavors[0]["versionNameSuffix"] as? String == "-staging")
        #expect(jsonFlavors[0]["versionCode"] as? String == "13")
    }

    @Test("XCodeTasks.inspectAllIosSchemes inspects all distributable schemes, skips test-only schemes, and serializes schemes to JSON")
    func inspectAllIosSchemesMultiScheme() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let projectDir = root.appendingPathComponent("TestApp.xcodeproj")
        let schemesDir = projectDir.appendingPathComponent("xcshareddata/xcschemes")
        try fm.createDirectory(at: schemesDir, withIntermediateDirectories: true)

        let pbxproj = """
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
        \t\t\t\t000000000000000000000015 /* TestAppTests */,
        \t\t\t);
        \t\t};
        \t\t000000000000000000000002 = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\t000000000000000000000005 /* Release */,
        \t\t\t\t000000000000000000000006 /* Staging */,
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
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t\t000000000000000000000006 /* Staging */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t};
        \t\t\tname = Staging;
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
        \t\t000000000000000000000011 = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\t000000000000000000000013 /* Release */,
        \t\t\t\t000000000000000000000014 /* Staging */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        \t\t000000000000000000000013 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tCURRENT_PROJECT_VERSION = "55";
        \t\t\t\tMARKETING_VERSION = "2.1.0";
        \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.example.inspect";
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t\t000000000000000000000014 /* Staging */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tCURRENT_PROJECT_VERSION = "56";
        \t\t\t\tMARKETING_VERSION = "2.1.0-rc1";
        \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.example.inspect.staging";
        \t\t\t};
        \t\t\tname = Staging;
        \t\t};
        \t\t000000000000000000000015 /* TestAppTests */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = 000000000000000000000016;
        \t\t\tbuildPhases = (
        \t\t\t);
        \t\t\tbuildRules = (
        \t\t\t);
        \t\t\tdependencies = (
        \t\t\t);
        \t\t\tname = TestAppTests;
        \t\t\tproductName = TestAppTests;
        \t\t\tproductType = "com.apple.product-type.bundle.unit-test";
        \t\t};
        \t\t000000000000000000000016 = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\t000000000000000000000017 /* Release */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        \t\t000000000000000000000017 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.example.inspectTests";
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t};
        \trootObject = 000000000000000000000001 /* Project object */;
        }
        """
        try pbxproj.write(to: projectDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let makeSchemeXML: (String, String) -> String = { blueprint, config in
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme version="1.7">
               <BuildAction>
                  <BuildActionEntries>
                     <BuildActionEntry>
                        <BuildableReference BlueprintName = "\(blueprint)">
                        </BuildableReference>
                     </BuildActionEntry>
                  </BuildActionEntries>
               </BuildAction>
               <ArchiveAction buildConfiguration = "\(config)">
               </ArchiveAction>
            </Scheme>
            """
        }

        try makeSchemeXML("TestApp", "Release")
            .write(to: schemesDir.appendingPathComponent("TestApp.xcscheme"), atomically: true, encoding: .utf8)
        try makeSchemeXML("TestApp", "Staging")
            .write(to: schemesDir.appendingPathComponent("TestApp-Staging.xcscheme"), atomically: true, encoding: .utf8)
        try makeSchemeXML("TestAppTests", "Release")
            .write(to: schemesDir.appendingPathComponent("TestAppTests.xcscheme"), atomically: true, encoding: .utf8)

        let result = try await XCodeTasks.inspectAllIosSchemes(workspaceRoot: root)
        #expect(result.scheme == "TestApp")
        #expect(result.bundleId == "com.example.inspect")
        #expect(result.version == "2.1.0")
        #expect(result.buildNumber == "55")

        let schemes = try #require(result.schemes)
        #expect(schemes.map(\.scheme) == ["TestApp", "TestApp-Staging"])

        #expect(schemes[0].configuration == "Release")
        #expect(schemes[0].bundleId == "com.example.inspect")
        #expect(schemes[0].version == "2.1.0")
        #expect(schemes[0].buildNumber == "55")

        #expect(schemes[1].configuration == "Staging")
        #expect(schemes[1].bundleId == "com.example.inspect.staging")
        #expect(schemes[1].version == "2.1.0-rc1")
        #expect(schemes[1].buildNumber == "56")

        let data = try JSONEncoder().encode(result)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let jsonSchemes = try #require(json["schemes"] as? [[String: Any]])
        #expect(jsonSchemes.count == 2)
        #expect(jsonSchemes[1]["scheme"] as? String == "TestApp-Staging")
        #expect(jsonSchemes[1]["bundleId"] as? String == "com.example.inspect.staging")
        #expect(jsonSchemes[1]["version"] as? String == "2.1.0-rc1")
    }

    @Test("AndroidTasks.inspectAndroidProject resolves all flavors when omitted and filters when specified")
    func inspectAndroidProjectAllAndFilteredFlavors() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let androidAppDir = root.appendingPathComponent("android/app")
        try FileManager.default.createDirectory(at: androidAppDir, withIntermediateDirectories: true)

        let gradle = """
        android {
            namespace "com.example.inspect"
            defaultConfig {
                applicationId "com.example.inspect"
                versionName "1.5.0"
                versionCode 12
            }
            productFlavors {
                staging {
                    applicationIdSuffix ".staging"
                    versionNameSuffix "-staging"
                    versionCode 13
                }
                prod {
                    versionName "2.0.0"
                    versionCode 20
                }
            }
        }
        """
        try gradle.write(to: androidAppDir.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)

        let allResult = try await AndroidTasks.inspectAndroidProject(in: root, flavor: nil)
        #expect(allResult.applicationId == "com.example.inspect")
        #expect(allResult.versionName == "1.5.0")
        #expect(allResult.versionCode == "12")
        #expect(allResult.flavors.count == 2)

        #expect(allResult.flavors[0] == AndroidTasks.AndroidFlavor(
            name: "staging",
            applicationId: "com.example.inspect.staging",
            applicationIdSuffix: ".staging",
            versionName: "1.5.0-staging",
            versionNameSuffix: "-staging",
            versionCode: "13"
        ))
        #expect(allResult.flavors[1] == AndroidTasks.AndroidFlavor(
            name: "prod",
            applicationId: "com.example.inspect",
            applicationIdSuffix: nil,
            versionName: "2.0.0",
            versionNameSuffix: nil,
            versionCode: "20"
        ))

        let filteredResult = try await AndroidTasks.inspectAndroidProject(in: root, flavor: "staging")
        #expect(filteredResult.applicationId == "com.example.inspect.staging")
        #expect(filteredResult.packageName == "com.example.inspect.staging")
        #expect(filteredResult.versionName == "1.5.0-staging")
        #expect(filteredResult.versionCode == "13")
        #expect(filteredResult.flavors.count == 1)
        #expect(filteredResult.flavors[0].name == "staging")
    }
}
