import Foundation
import Testing
@testable import appitool

@Suite("AndroidTasks Tests")
struct AndroidTasksTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidTasksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("resolvePackageName prioritizes defaultConfig applicationId over namespace and manifest package")
    func resolvePackageNamePriorityAndPaths() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let androidDir = root.appendingPathComponent("android")
        try write(
            """
            android {
                namespace "com.example.ns"
                defaultConfig {
                    applicationId "com.example.app"
                }
            }
            """,
            to: androidDir.appendingPathComponent("app/build.gradle")
        )
        try write(
            """
            <manifest package="com.example.manifest" />
            """,
            to: androidDir.appendingPathComponent("app/src/main/AndroidManifest.xml")
        )

        #expect(AndroidTasks.resolvePackageName(in: root) == "com.example.app")
        #expect(AndroidTasks.resolvePackageName(in: androidDir) == "com.example.app")
    }

    @Test("resolvePackageName skips $-interpolated values and falls back cleanly")
    func resolvePackageNameSkipsInterpolation() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let androidDir = root.appendingPathComponent("android")
        let gradleUrl = androidDir.appendingPathComponent("app/build.gradle.kts")
        try write(
            """
            android {
                namespace = "$DYNAMIC_NS"
                defaultConfig {
                    applicationId = "$MY_APP_ID"
                }
            }
            """,
            to: gradleUrl
        )
        try write(
            """
            <manifest package="com.example.manifest" />
            """,
            to: androidDir.appendingPathComponent("app/src/main/AndroidManifest.xml")
        )

        #expect(AndroidTasks.resolvePackageName(in: root) == "com.example.manifest")

        try write(
            """
            android {
                namespace = "com.example.ktsns"
                defaultConfig {
                    applicationId = "$MY_APP_ID"
                }
            }
            """,
            to: gradleUrl
        )

        #expect(AndroidTasks.resolvePackageName(in: root) == "com.example.ktsns")
    }

    @Test("resolvePackageName returns nil when no Android project exists")
    func resolvePackageNameMissingProject() throws {
        let emptyRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        #expect(AndroidTasks.resolvePackageName(in: emptyRoot) == nil)
    }

    @Test("resolveAppName resolves in priority order strings.xml -> settings.gradle(.kts) -> app.json")
    func resolveAppNamePriorityOrder() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let androidDir = root.appendingPathComponent("android")
        let stringsUrl = androidDir.appendingPathComponent("app/src/main/res/values/strings.xml")
        let settingsKtsUrl = androidDir.appendingPathComponent("settings.gradle.kts")
        let settingsUrl = androidDir.appendingPathComponent("settings.gradle")
        let appJsonUrl = root.appendingPathComponent("app.json")

        // Create app/build.gradle so findAndroidRoot locates androidDir reliably
        try write("android {}", to: androidDir.appendingPathComponent("app/build.gradle"))

        // 3. app.json fallback (including ../app.json lookup when passed androidDir)
        try write(#"{"name": "RnName", "displayName": "RnDisplay"}"#, to: appJsonUrl)
        #expect(AndroidTasks.resolveAppName(in: root) == "RnDisplay")
        #expect(AndroidTasks.resolveAppName(in: androidDir) == "RnDisplay")

        // app.json name when displayName is missing
        try write(#"{"name": "RnNameOnly"}"#, to: appJsonUrl)
        #expect(AndroidTasks.resolveAppName(in: root) == "RnNameOnly")

        // 2b. settings.gradle.kts overrides app.json
        try write(#"rootProject.name = "GradleKtsApp""#, to: settingsKtsUrl)
        #expect(AndroidTasks.resolveAppName(in: root) == "GradleKtsApp")

        // 2a. settings.gradle overrides settings.gradle.kts
        try write("rootProject.name = 'GradleGroovyApp'", to: settingsUrl)
        #expect(AndroidTasks.resolveAppName(in: root) == "GradleGroovyApp")

        // 1. strings.xml has highest priority
        try write(#"<resources><string name="app_name">StringsXmlApp</string></resources>"#, to: stringsUrl)
        #expect(AndroidTasks.resolveAppName(in: root) == "StringsXmlApp")
    }

    @Test("parseAppBuildGradle parses flavor versions, suffixes, and skips $-interpolated versionName")
    func parseAppBuildGradleFlavorVersionsAndSkipInterpolation() {
        let gradle = """
        android {
            namespace "com.example.ns"
            defaultConfig {
                applicationId "com.example.app"
                versionName "$DYNAMIC_VERSION"
                versionCode 10
            }
            productFlavors {
                staging {
                    applicationIdSuffix ".staging"
                    versionNameSuffix "-beta"
                    versionCode 11
                }
                create("prod") {
                    versionName = "2.5.0"
                    versionCode = 50
                }
            }
        }
        """

        let parsed = AndroidTasks.parseAppBuildGradle(content: gradle)
        #expect(parsed.applicationId == "com.example.app")
        #expect(parsed.versionName == nil)
        #expect(parsed.versionCode == "10")
        #expect(parsed.flavors.count == 2)

        #expect(parsed.flavors[0] == AndroidTasks.AndroidFlavor(
            name: "staging",
            applicationId: nil,
            applicationIdSuffix: ".staging",
            versionName: nil,
            versionNameSuffix: "-beta",
            versionCode: "11"
        ))
        #expect(parsed.flavors[1] == AndroidTasks.AndroidFlavor(
            name: "prod",
            applicationId: nil,
            applicationIdSuffix: nil,
            versionName: "2.5.0",
            versionNameSuffix: nil,
            versionCode: "50"
        ))
    }

    @Test("parseGradleAppInfoOutput and resolveEffectiveVersion handle flavor overrides and suffixes")
    func parseGradleAppInfoOutputAndResolveEffectiveVersion() {
        let output = """
        APPI_VERSION_CODE=100
        APPI_VERSION_NAME=2.0.0
        APPI_APPLICATION_ID=com.example.app
        APPI_NAMESPACE=com.example.ns
        APPI_FLAVOR=staging||.staging||-rc|101
        APPI_FLAVOR=pro|com.example.pro||3.1.0||300
        APPI_FLAVOR=legacy|com.example.legacy|.legacy
        """

        let defaultInfo = AndroidTasks.parseGradleAppInfoOutput(output, flavor: nil)
        #expect(defaultInfo.versionName == "2.0.0")
        #expect(defaultInfo.versionCode == "100")
        #expect(defaultInfo.packageName == "com.example.app")
        #expect(defaultInfo.flavors.count == 3)

        let stagingInfo = AndroidTasks.parseGradleAppInfoOutput(output, flavor: "STAGING")
        #expect(stagingInfo.versionName == "2.0.0-rc")
        #expect(stagingInfo.versionCode == "101")

        let proInfo = AndroidTasks.parseGradleAppInfoOutput(output, flavor: "pro")
        #expect(proInfo.versionName == "3.1.0")
        #expect(proInfo.versionCode == "300")

        let missingDefault = AndroidTasks.resolveEffectiveVersion(
            defaultVersionName: nil,
            defaultVersionCode: nil,
            flavors: defaultInfo.flavors,
            flavor: "staging"
        )
        #expect(missingDefault.versionName == nil)
        #expect(missingDefault.versionCode == "101")
    }
}
