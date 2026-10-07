import Foundation
import Subprocess

/// A suite of atomic Android project operations, inspection, and identifier resolutions.
public enum AndroidTasks {

    /// Represents an Android product flavor.
    public struct AndroidFlavor: Sendable, Codable, Equatable {
        public let name: String
        public let applicationId: String?
        public let applicationIdSuffix: String?

        public init(name: String, applicationId: String? = nil, applicationIdSuffix: String? = nil) {
            self.name = name
            self.applicationId = applicationId
            self.applicationIdSuffix = applicationIdSuffix
        }
    }

    /// Result of Android identifier resolution.
    public struct AndroidIdentifiersResult: Sendable, Codable, Equatable {
        public let androidRoot: String
        public let appBuildGradlePath: String?
        public let manifestPath: String?
        public let namespace: String?
        public let applicationId: String?
        public let packageName: String?
        public let versionName: String?
        public let versionCode: String?
        public let flavors: [AndroidFlavor]

        public init(
            androidRoot: String,
            appBuildGradlePath: String?,
            manifestPath: String?,
            namespace: String?,
            applicationId: String?,
            packageName: String?,
            versionName: String? = nil,
            versionCode: String? = nil,
            flavors: [AndroidFlavor]
        ) {
            self.androidRoot = androidRoot
            self.appBuildGradlePath = appBuildGradlePath
            self.manifestPath = manifestPath
            self.namespace = namespace
            self.applicationId = applicationId
            self.packageName = packageName
            self.versionName = versionName
            self.versionCode = versionCode
            self.flavors = flavors
        }
    }

    /// Finds the Android root directory under the given workspace root.
    public static func findAndroidRoot(in workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        let fm = FileManager.default
        let candidates = [
            workspaceRoot.appendingPathComponent("android"),
            workspaceRoot
        ]

        for candidate in candidates {
            if fm.fileExists(atPath: candidate.appendingPathComponent("app/build.gradle").path) ||
               fm.fileExists(atPath: candidate.appendingPathComponent("app/build.gradle.kts").path) ||
               fm.fileExists(atPath: candidate.appendingPathComponent("settings.gradle").path) ||
               fm.fileExists(atPath: candidate.appendingPathComponent("settings.gradle.kts").path) {
                return candidate
            }
        }
        return nil
    }

    /// Checks if an Android project exists under the given workspace root.
    public static func hasAndroidProject(in workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> Bool {
        return findAndroidRoot(in: workspaceRoot) != nil
    }

    /// Parses namespace, defaultConfig applicationId, versionName, versionCode, and product flavors from `build.gradle` or `build.gradle.kts` content.
    public static func parseAppBuildGradle(content: String) -> (namespace: String?, applicationId: String?, versionName: String?, versionCode: String?, flavors: [AndroidFlavor]) {
        var namespace: String? = nil
        var applicationId: String? = nil
        var versionName: String? = nil
        var versionCode: String? = nil
        var flavors: [AndroidFlavor] = []

        // Match namespace
        let nsPattern = #"namespace\s*=?\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: nsPattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            namespace = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Match defaultConfig applicationId, versionName, and versionCode
        let defaultConfigPattern = #"defaultConfig\s*\{([^}]+)\}"#
        if let regex = try? NSRegularExpression(pattern: defaultConfigPattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            let defaultConfigContent = String(content[range])
            let appIdPattern = #"applicationId\s*=?\s*["']([^"']+)["']"#
            if let appRegex = try? NSRegularExpression(pattern: appIdPattern),
               let appMatch = appRegex.firstMatch(in: defaultConfigContent, range: NSRange(defaultConfigContent.startIndex..., in: defaultConfigContent)),
               let appRange = Range(appMatch.range(at: 1), in: defaultConfigContent) {
                applicationId = String(defaultConfigContent[appRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Match versionName in defaultConfig (supports direct string, assignment, or ternary like: project.hasProperty('versionName') ? ... : "1.0.0")
            let vnPattern = #"versionName\s*(?:=|\s)\s*(?:.*:\s*)?["']([^"']+)["']"#
            if let vnRegex = try? NSRegularExpression(pattern: vnPattern),
               let vnMatch = vnRegex.firstMatch(in: defaultConfigContent, range: NSRange(defaultConfigContent.startIndex..., in: defaultConfigContent)),
               let vnRange = Range(vnMatch.range(at: 1), in: defaultConfigContent) {
                versionName = String(defaultConfigContent[vnRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Match versionCode in defaultConfig (supports direct int, assignment, or ternary)
            let vcPattern = #"versionCode\s*(?:=|\s)\s*(?:.*:\s*)?(\d+)"#
            if let vcRegex = try? NSRegularExpression(pattern: vcPattern),
               let vcMatch = vcRegex.firstMatch(in: defaultConfigContent, range: NSRange(defaultConfigContent.startIndex..., in: defaultConfigContent)),
               let vcRange = Range(vcMatch.range(at: 1), in: defaultConfigContent) {
                versionCode = String(defaultConfigContent[vcRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Fallback: general applicationId
        if applicationId == nil {
            let appIdPattern = #"applicationId\s*=?\s*["']([^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: appIdPattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                let candidate = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.contains("$") {
                    applicationId = candidate
                }
            }
        }

        // Fallback: general versionName if not found in defaultConfig
        if versionName == nil {
            let vnPattern = #"versionName\s*(?:=|\s)\s*(?:.*:\s*)?["']([^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: vnPattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                versionName = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Fallback: general versionCode if not found in defaultConfig
        if versionCode == nil {
            let vcPattern = #"versionCode\s*(?:=|\s)\s*(?:.*:\s*)?(\d+)"#
            if let regex = try? NSRegularExpression(pattern: vcPattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                versionCode = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Match productFlavors
        let flavorsBlockPattern = #"productFlavors\s*\{([\s\S]*?)\n\s*\}"#
        if let regex = try? NSRegularExpression(pattern: flavorsBlockPattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            let flavorBlock = String(content[range])
            let flavorRegexPattern = #"(?:create\(\s*["']([^"']+)["']\s*\)|([a-zA-Z0-9_]+))\s*\{([^}]*)\}"#
            if let flavorRegex = try? NSRegularExpression(pattern: flavorRegexPattern) {
                let matches = flavorRegex.matches(in: flavorBlock, range: NSRange(flavorBlock.startIndex..., in: flavorBlock))
                for m in matches {
                    let nameRange: Range<String.Index>?
                    if m.range(at: 1).location != NSNotFound {
                        nameRange = Range(m.range(at: 1), in: flavorBlock)
                    } else if m.range(at: 2).location != NSNotFound {
                        nameRange = Range(m.range(at: 2), in: flavorBlock)
                    } else {
                        nameRange = nil
                    }

                    guard let nRange = nameRange else { continue }
                    let flavorName = String(flavorBlock[nRange]).trimmingCharacters(in: .whitespacesAndNewlines)

                    var flavorAppId: String? = nil
                    var flavorSuffix: String? = nil

                    if m.range(at: 3).location != NSNotFound, let contentRange = Range(m.range(at: 3), in: flavorBlock) {
                        let fContent = String(flavorBlock[contentRange])
                        let fAppIdPattern = #"applicationId\s*=?\s*["']([^"']+)["']"#
                        if let r = try? NSRegularExpression(pattern: fAppIdPattern),
                           let fMatch = r.firstMatch(in: fContent, range: NSRange(fContent.startIndex..., in: fContent)),
                           let rRange = Range(fMatch.range(at: 1), in: fContent) {
                            flavorAppId = String(fContent[rRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let fSuffixPattern = #"applicationIdSuffix\s*=?\s*["']([^"']+)["']"#
                        if let r = try? NSRegularExpression(pattern: fSuffixPattern),
                           let fMatch = r.firstMatch(in: fContent, range: NSRange(fContent.startIndex..., in: fContent)),
                           let rRange = Range(fMatch.range(at: 1), in: fContent) {
                            flavorSuffix = String(fContent[rRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }

                    flavors.append(AndroidFlavor(name: flavorName, applicationId: flavorAppId, applicationIdSuffix: flavorSuffix))
                }
            }
        }

        return (namespace, applicationId, versionName, versionCode, flavors)
    }

    /// Parses package name from `AndroidManifest.xml` content.
    public static func parseAndroidManifest(content: String) -> String? {
        let pattern = #"package\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Resolves Android identifiers: namespace, applicationId, packageName, and product flavors.
    public static func getAndroidIdentifiers(
        workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> AndroidIdentifiersResult {
        let fm = FileManager.default
        guard let androidRoot = findAndroidRoot(in: workspaceRoot) else {
            throw NSError(
                domain: "AndroidTasks",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Android project not found (\(workspaceRoot.appendingPathComponent("android").path))."]
            )
        }

        let gradleCandidates = [
            androidRoot.appendingPathComponent("app/build.gradle"),
            androidRoot.appendingPathComponent("app/build.gradle.kts")
        ]
        var appBuildGradlePath: String? = nil
        var namespace: String? = nil
        var applicationId: String? = nil
        var versionName: String? = nil
        var versionCode: String? = nil
        var flavors: [AndroidFlavor] = []

        for candidate in gradleCandidates {
            if fm.fileExists(atPath: candidate.path) {
                appBuildGradlePath = candidate.path
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    let parsed = parseAppBuildGradle(content: content)
                    namespace = parsed.namespace
                    applicationId = parsed.applicationId
                    versionName = parsed.versionName
                    versionCode = parsed.versionCode
                    flavors = parsed.flavors
                }
                break
            }
        }

        let manifestCandidates = [
            androidRoot.appendingPathComponent("app/src/main/AndroidManifest.xml"),
            androidRoot.appendingPathComponent("src/main/AndroidManifest.xml")
        ]
        var manifestPath: String? = nil
        var packageName: String? = nil

        for candidate in manifestCandidates {
            if fm.fileExists(atPath: candidate.path) {
                manifestPath = candidate.path
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    packageName = parseAndroidManifest(content: content)
                }
                break
            }
        }

        if namespace == nil { namespace = packageName ?? applicationId }
        if packageName == nil { packageName = namespace }
        if applicationId == nil { applicationId = namespace ?? packageName }

        return AndroidIdentifiersResult(
            androidRoot: androidRoot.path,
            appBuildGradlePath: appBuildGradlePath,
            manifestPath: manifestPath,
            namespace: namespace,
            applicationId: applicationId,
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            flavors: flavors
        )
    }

    /// Model containing dynamically evaluated Android app information from Gradle.
    public struct GradleAppInfo: Sendable, Codable, Equatable {
        public let versionCode: String?
        public let versionName: String?
        public let applicationId: String?
        public let packageName: String?
        public let namespace: String?
        public let flavors: [AndroidFlavor]

        public init(
            versionCode: String?,
            versionName: String?,
            applicationId: String?,
            packageName: String? = nil,
            namespace: String? = nil,
            flavors: [AndroidFlavor] = []
        ) {
            self.versionCode = versionCode
            self.versionName = versionName
            self.applicationId = applicationId
            self.packageName = packageName
            self.namespace = namespace
            self.flavors = flavors
        }
    }

    /// Evaluates the Android project model dynamically by executing Gradle with a temporary init-script.
    /// This captures the runtime-evaluated `versionCode`, `versionName`, `applicationId`, `packageName`, `namespace`, and product flavors
    /// (e.g. when determined by properties, ternaries, or dynamic functions in Gradle).
    public static func evaluateAppInfoViaGradle(
        workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        offline: Bool = false
    ) async throws -> GradleAppInfo {
        guard let androidRoot = findAndroidRoot(in: workspaceRoot) else {
            throw NSError(
                domain: "AndroidTasks",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Android project not found (\(workspaceRoot.path))."]
            )
        }

        let gradlewCandidates = [
            androidRoot.appendingPathComponent("gradlew"),
            workspaceRoot.appendingPathComponent("gradlew")
        ]
        guard let gradlewUrl = gradlewCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(
                domain: "AndroidTasks",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Gradle wrapper executable ('gradlew') not found in \(androidRoot.path)."]
            )
        }

        // Ensure gradlew has executable permissions
        if !FileManager.default.isExecutableFile(atPath: gradlewUrl.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: gradlewUrl.path)
            let currentPermissions = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: currentPermissions | 0o755)], ofItemAtPath: gradlewUrl.path)
        }

        let fm = FileManager.default
        let tempScriptUrl = fm.temporaryDirectory.appendingPathComponent("appitool-info-\(UUID().uuidString).gradle")
        let scriptContent = """
        allprojects {
            afterEvaluate { project ->
                if (project.plugins.hasPlugin("com.android.application")) {
                    tasks.register("printAppInfo") {
                        doLast {
                            def androidExt = project.extensions.findByName("android")
                            def conf = androidExt?.defaultConfig
                            def ns = androidExt?.hasProperty("namespace") ? androidExt.namespace : ""
                            println "APPI_VERSION_CODE=${conf?.versionCode ?: ''}"
                            println "APPI_VERSION_NAME=${conf?.versionName ?: ''}"
                            println "APPI_APPLICATION_ID=${conf?.applicationId ?: ''}"
                            println "APPI_NAMESPACE=${ns ?: ''}"
                            if (androidExt?.productFlavors) {
                                androidExt.productFlavors.each { f ->
                                    println "APPI_FLAVOR=${f.name}|${f.applicationId ?: ''}|${f.applicationIdSuffix ?: ''}"
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        try scriptContent.write(to: tempScriptUrl, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tempScriptUrl) }

        var args = ["-q"]
        if offline {
            args.append("--offline")
        }
        args.append(contentsOf: ["-I", tempScriptUrl.path, "printAppInfo"])

        let result = try await Subprocess.run(
            .path(FilePath(gradlewUrl.path)),
            arguments: Arguments(args),
            workingDirectory: FilePath(androidRoot.path),
            output: .string(limit: 10 * 1024 * 1024),
            error: .combinedWithOutput
        )

        guard result.terminationStatus.isSuccess else {
            let code = switch result.terminationStatus {
            case .exited(let c): c
            case .signaled(let c): c
            }
            throw NSError(
                domain: "AndroidTasks",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Gradle evaluation failed (exit code \(code)): \(result.standardOutput)"]
            )
        }

        var versionCode: String?
        var versionName: String?
        var applicationId: String?
        var namespace: String?
        var flavors: [AndroidFlavor] = []

        for line in result.standardOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("APPI_VERSION_CODE=") {
                let val = String(trimmed.dropFirst("APPI_VERSION_CODE=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val != "null" { versionCode = val }
            } else if trimmed.hasPrefix("APPI_VERSION_NAME=") {
                let val = String(trimmed.dropFirst("APPI_VERSION_NAME=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val != "null" { versionName = val }
            } else if trimmed.hasPrefix("APPI_APPLICATION_ID=") {
                let val = String(trimmed.dropFirst("APPI_APPLICATION_ID=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val != "null" { applicationId = val }
            } else if trimmed.hasPrefix("APPI_NAMESPACE=") {
                let val = String(trimmed.dropFirst("APPI_NAMESPACE=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && val != "null" { namespace = val }
            } else if trimmed.hasPrefix("APPI_FLAVOR=") {
                let raw = String(trimmed.dropFirst("APPI_FLAVOR=".count))
                let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 1 && !parts[0].isEmpty {
                    let name = parts[0]
                    let fAppId = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                    let fSuffix = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
                    flavors.append(AndroidFlavor(name: name, applicationId: fAppId, applicationIdSuffix: fSuffix))
                }
            }
        }

        let packageName = applicationId ?? namespace

        return GradleAppInfo(
            versionCode: versionCode,
            versionName: versionName,
            applicationId: applicationId,
            packageName: packageName,
            namespace: namespace,
            flavors: flavors
        )
    }
}

