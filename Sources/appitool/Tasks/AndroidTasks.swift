import Foundation

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
        public let flavors: [AndroidFlavor]

        public init(
            androidRoot: String,
            appBuildGradlePath: String?,
            manifestPath: String?,
            namespace: String?,
            applicationId: String?,
            packageName: String?,
            flavors: [AndroidFlavor]
        ) {
            self.androidRoot = androidRoot
            self.appBuildGradlePath = appBuildGradlePath
            self.manifestPath = manifestPath
            self.namespace = namespace
            self.applicationId = applicationId
            self.packageName = packageName
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

    /// Parses namespace, defaultConfig applicationId, and product flavors from `build.gradle` or `build.gradle.kts` content.
    public static func parseAppBuildGradle(content: String) -> (namespace: String?, applicationId: String?, flavors: [AndroidFlavor]) {
        var namespace: String? = nil
        var applicationId: String? = nil
        var flavors: [AndroidFlavor] = []

        // Match namespace
        let nsPattern = #"namespace\s*=?\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: nsPattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            namespace = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Match defaultConfig applicationId
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

        return (namespace, applicationId, flavors)
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
        var flavors: [AndroidFlavor] = []

        for candidate in gradleCandidates {
            if fm.fileExists(atPath: candidate.path) {
                appBuildGradlePath = candidate.path
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    let parsed = parseAppBuildGradle(content: content)
                    namespace = parsed.namespace
                    applicationId = parsed.applicationId
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
            flavors: flavors
        )
    }
}
