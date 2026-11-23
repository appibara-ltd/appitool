import Foundation

/// A suite of atomic Android project operations, inspection, and identifier resolutions.
public enum AndroidTasks {

    /// Represents an Android product flavor.
    public struct AndroidFlavor: Sendable, Codable, Equatable {
        public let name: String
        public let applicationId: String?
        public let applicationIdSuffix: String?
        public let versionName: String?
        public let versionNameSuffix: String?
        public let versionCode: String?

        public init(
            name: String,
            applicationId: String? = nil,
            applicationIdSuffix: String? = nil,
            versionName: String? = nil,
            versionNameSuffix: String? = nil,
            versionCode: String? = nil
        ) {
            self.name = name
            self.applicationId = applicationId
            self.applicationIdSuffix = applicationIdSuffix
            self.versionName = versionName
            self.versionNameSuffix = versionNameSuffix
            self.versionCode = versionCode
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
            let candidate = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && !candidate.contains("$") {
                namespace = candidate
            }
        }

        let matchNonInterpolated: (String, String) -> String? = { pattern, text in
            guard let candidate = firstRegexMatch(pattern, in: text),
                  !candidate.isEmpty,
                  !candidate.contains("$")
            else { return nil }
            return candidate
        }

        let appIdPattern = #"applicationId\s*=?\s*["']([^"']+)["']"#
        let vnPattern = #"\bversionName\b\s*(?:=|\s)\s*(?:.*:\s*)?["']([^"']+)["']"#
        let vcPattern = #"\bversionCode\b\s*(?:=|\s)\s*(?:.*:\s*)?(\d+)"#

        // Match defaultConfig applicationId, versionName, and versionCode
        let defaultConfigPattern = #"defaultConfig\s*\{([^}]+)\}"#
        if let regex = try? NSRegularExpression(pattern: defaultConfigPattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            let defaultConfigContent = String(content[range])
            applicationId = matchNonInterpolated(appIdPattern, defaultConfigContent)
            versionName = matchNonInterpolated(vnPattern, defaultConfigContent)
            versionCode = firstRegexMatch(vcPattern, in: defaultConfigContent)
        }

        // Fallback: general applicationId
        if applicationId == nil {
            applicationId = matchNonInterpolated(appIdPattern, content)
        }

        // Fallback: general versionName if not found in defaultConfig
        if versionName == nil {
            versionName = matchNonInterpolated(vnPattern, content)
        }

        // Fallback: general versionCode if not found in defaultConfig
        if versionCode == nil {
            versionCode = firstRegexMatch(vcPattern, in: content)
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
                    var flavorVersionName: String? = nil
                    var flavorVersionNameSuffix: String? = nil
                    var flavorVersionCode: String? = nil

                    if m.range(at: 3).location != NSNotFound, let contentRange = Range(m.range(at: 3), in: flavorBlock) {
                        let fContent = String(flavorBlock[contentRange])
                        flavorAppId = matchNonInterpolated(appIdPattern, fContent)
                        flavorSuffix = matchNonInterpolated(#"applicationIdSuffix\s*=?\s*["']([^"']+)["']"#, fContent)
                        flavorVersionName = matchNonInterpolated(vnPattern, fContent)
                        flavorVersionNameSuffix = matchNonInterpolated(#"\bversionNameSuffix\b\s*=?\s*["']([^"']+)["']"#, fContent)
                        flavorVersionCode = firstRegexMatch(vcPattern, in: fContent)
                    }

                    flavors.append(AndroidFlavor(
                        name: flavorName,
                        applicationId: flavorAppId,
                        applicationIdSuffix: flavorSuffix,
                        versionName: flavorVersionName,
                        versionNameSuffix: flavorVersionNameSuffix,
                        versionCode: flavorVersionCode
                    ))
                }
            }
        }

        return (namespace, applicationId, versionName, versionCode, flavors)
    }

    /// Parses package name from `AndroidManifest.xml` content.
    public static func parseAndroidManifest(content: String) -> String? {
        guard let pkg = firstRegexMatch(#"package\s*=\s*["']([^"']+)["']"#, in: content), !pkg.isEmpty else {
            return nil
        }
        return pkg
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

    /// Resolves the Android package name (prioritizing `applicationId`, then `namespace`, then `AndroidManifest.xml` `package`).
    public static func resolvePackageName(
        in workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> String? {
        guard let identifiers = try? getAndroidIdentifiers(workspaceRoot: workspaceRoot) else {
            return nil
        }
        let candidate = identifiers.applicationId ?? identifiers.packageName
        return (candidate?.isEmpty == false) ? candidate : nil
    }

    /// Attempts to extract the user-facing application name from Android resource files or project configuration.
    public static func resolveAppName(
        in workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> String? {
        let fm = FileManager.default
        let basePath = workspaceRoot.path
        let androidDir = findAndroidRoot(in: workspaceRoot)?.path
            ?? (fm.fileExists(atPath: "\(basePath)/app") ? basePath : "\(basePath)/android")

        // 1. Check strings.xml
        let stringsPath = "\(androidDir)/app/src/main/res/values/strings.xml"
        if let content = try? String(contentsOfFile: stringsPath, encoding: .utf8),
           let name = firstRegexMatch(#"<string\s+name=["']app_name["']>([^<]+)</string>"#, in: content),
           !name.isEmpty {
            return name
        }

        // 2. Check settings.gradle / settings.gradle.kts
        for settingsFile in ["settings.gradle", "settings.gradle.kts"] {
            let settingsPath = "\(androidDir)/\(settingsFile)"
            if let content = try? String(contentsOfFile: settingsPath, encoding: .utf8),
               let name = firstRegexMatch(#"rootProject\.name\s*=\s*['"]([^'"]+)['"]"#, in: content),
               !name.isEmpty {
                return name
            }
        }

        // 3. Check app.json (e.g. React Native / Expo)
        let rootDir = fm.fileExists(atPath: "\(basePath)/android")
            ? basePath
            : workspaceRoot.deletingLastPathComponent().path
        let appJsonPath = "\(rootDir)/app.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let displayName = json["displayName"] as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = json["name"] as? String, !name.isEmpty {
                return name
            }
        }

        return nil
    }

    private static func firstRegexMatch(_ pattern: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Applies optional flavor overrides (`versionName`, `versionNameSuffix`, `versionCode`) over `defaultConfig` values.
    internal static func resolveEffectiveVersion(
        defaultVersionName: String?,
        defaultVersionCode: String?,
        flavors: [AndroidFlavor],
        flavor: String?
    ) -> (versionName: String?, versionCode: String?) {
        let matchedFlavor: AndroidFlavor?
        if let rawFlavor = flavor?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFlavor.isEmpty {
            matchedFlavor = flavors.first { $0.name.caseInsensitiveCompare(rawFlavor) == .orderedSame }
        } else {
            matchedFlavor = nil
        }

        let effectiveCode = matchedFlavor?.versionCode ?? defaultVersionCode
        let baseName = matchedFlavor?.versionName ?? defaultVersionName
        let effectiveName: String?
        if let baseName, let suffix = matchedFlavor?.versionNameSuffix, !suffix.isEmpty {
            effectiveName = "\(baseName)\(suffix)"
        } else {
            effectiveName = baseName
        }

        return (versionName: effectiveName, versionCode: effectiveCode)
    }

    /// Computes effective `applicationId`, `versionName`, and `versionCode` for each flavor (filtering to `selectedFlavor` when provided).
    public static func resolveFlavorDetails(
        flavors: [AndroidFlavor],
        defaultApplicationId: String?,
        defaultVersionName: String?,
        defaultVersionCode: String?,
        selectedFlavor: String? = nil
    ) -> [AndroidFlavor] {
        let filtered: [AndroidFlavor]
        if let rawSelected = selectedFlavor?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawSelected.isEmpty
        {
            filtered = flavors.filter { $0.name.caseInsensitiveCompare(rawSelected) == .orderedSame }
        } else {
            filtered = flavors
        }

        return filtered.map { flavor in
            let baseAppId = flavor.applicationId ?? defaultApplicationId
            let effectiveAppId: String?
            if let baseAppId, let appIdSuffix = flavor.applicationIdSuffix, !appIdSuffix.isEmpty {
                effectiveAppId = "\(baseAppId)\(appIdSuffix)"
            } else {
                effectiveAppId = baseAppId
            }

            let effectiveVersion = resolveEffectiveVersion(
                defaultVersionName: defaultVersionName,
                defaultVersionCode: defaultVersionCode,
                flavors: [flavor],
                flavor: flavor.name
            )

            return AndroidFlavor(
                name: flavor.name,
                applicationId: effectiveAppId,
                applicationIdSuffix: flavor.applicationIdSuffix,
                versionName: effectiveVersion.versionName,
                versionNameSuffix: flavor.versionNameSuffix,
                versionCode: effectiveVersion.versionCode
            )
        }
    }

    /// Inspects an Android project (static regex + Gradle fallback when dynamic or unparsed flavors exist)
    /// and resolves per-flavor effective `applicationId`, `versionName`, and `versionCode`.
    public static func inspectAndroidProject(
        in workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        flavor: String? = nil
    ) async throws -> AndroidIdentifiersResult {
        let raw = try getAndroidIdentifiers(workspaceRoot: workspaceRoot)
        let requestedFlavor = flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRequestedFlavor = (requestedFlavor?.isEmpty == false)

        let missingRequestedFlavor: Bool
        if let req = requestedFlavor, !req.isEmpty {
            missingRequestedFlavor = !raw.flavors.contains { $0.name.caseInsensitiveCompare(req) == .orderedSame }
        } else {
            missingRequestedFlavor = false
        }

        let mentionsProductFlavors: Bool = {
            guard raw.flavors.isEmpty,
                  let path = raw.appBuildGradlePath,
                  let content = try? String(contentsOfFile: path, encoding: .utf8)
            else { return false }
            return content.contains("productFlavors")
        }()

        var baseAppId = raw.applicationId
        var baseNamespace = raw.namespace
        var basePackageName = raw.packageName
        var baseVersionName = raw.versionName
        var baseVersionCode = raw.versionCode
        var baseFlavors = raw.flavors

        let needsGradle = baseVersionName == nil
            || baseVersionCode == nil
            || baseAppId == nil
            || missingRequestedFlavor
            || mentionsProductFlavors

        if needsGradle {
            let evaluated: GradleAppInfo?
            do {
                evaluated = try await evaluateAppInfoViaGradle(
                    workspaceRoot: workspaceRoot,
                    offline: true,
                    flavor: nil
                )
            } catch {
                evaluated = try? await evaluateAppInfoViaGradle(
                    workspaceRoot: workspaceRoot,
                    offline: false,
                    flavor: nil
                )
            }

            if let evaluated {
                if let appId = evaluated.applicationId, !appId.isEmpty {
                    baseAppId = appId
                }
                if let ns = evaluated.namespace, !ns.isEmpty {
                    baseNamespace = ns
                }
                if let pkg = evaluated.packageName, !pkg.isEmpty {
                    basePackageName = pkg
                }
                if let vn = evaluated.versionName, !vn.isEmpty {
                    baseVersionName = vn
                }
                if let vc = evaluated.versionCode, !vc.isEmpty {
                    baseVersionCode = vc
                }
                if !evaluated.flavors.isEmpty {
                    baseFlavors = evaluated.flavors
                }
            }
        }

        let resolvedFlavors = resolveFlavorDetails(
            flavors: baseFlavors,
            defaultApplicationId: baseAppId,
            defaultVersionName: baseVersionName,
            defaultVersionCode: baseVersionCode,
            selectedFlavor: flavor
        )

        let finalAppId: String?
        let finalPackageName: String?
        let finalVersionName: String?
        let finalVersionCode: String?
        if hasRequestedFlavor, let matched = resolvedFlavors.first {
            finalAppId = matched.applicationId ?? baseAppId
            finalPackageName = matched.applicationId ?? basePackageName
            finalVersionName = matched.versionName ?? baseVersionName
            finalVersionCode = matched.versionCode ?? baseVersionCode
        } else {
            finalAppId = baseAppId
            finalPackageName = basePackageName
            finalVersionName = baseVersionName
            finalVersionCode = baseVersionCode
        }

        return AndroidIdentifiersResult(
            androidRoot: raw.androidRoot,
            appBuildGradlePath: raw.appBuildGradlePath,
            manifestPath: raw.manifestPath,
            namespace: baseNamespace,
            applicationId: finalAppId,
            packageName: finalPackageName,
            versionName: finalVersionName,
            versionCode: finalVersionCode,
            flavors: resolvedFlavors
        )
    }

    /// Resolves versionName and versionCode statically first, falling back to Gradle evaluation
    /// (`--offline` then online retry on failure) when values or the requested flavor are unresolved.
    public static func resolveProjectVersion(
        in workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        flavor: String? = nil,
        identifiers: AndroidIdentifiersResult? = nil
    ) async -> (versionName: String?, versionCode: String?) {
        let resolvedIdentifiers = identifiers ?? (try? getAndroidIdentifiers(workspaceRoot: workspaceRoot))
        let staticFlavors = resolvedIdentifiers?.flavors ?? []
        let staticEffective = resolveEffectiveVersion(
            defaultVersionName: resolvedIdentifiers?.versionName,
            defaultVersionCode: resolvedIdentifiers?.versionCode,
            flavors: staticFlavors,
            flavor: flavor
        )

        let requestedFlavor = flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let missingRequestedFlavor = requestedFlavor.map { req in
            !req.isEmpty && !staticFlavors.contains { $0.name.caseInsensitiveCompare(req) == .orderedSame }
        } ?? false

        var versionName = staticEffective.versionName
        var versionCode = staticEffective.versionCode

        if versionName == nil || versionCode == nil || missingRequestedFlavor {
            let evaluated: GradleAppInfo?
            do {
                evaluated = try await evaluateAppInfoViaGradle(
                    workspaceRoot: workspaceRoot,
                    offline: true,
                    flavor: flavor
                )
            } catch {
                evaluated = try? await evaluateAppInfoViaGradle(
                    workspaceRoot: workspaceRoot,
                    offline: false,
                    flavor: flavor
                )
            }

            if let evaluated {
                if let vName = evaluated.versionName, !vName.isEmpty {
                    versionName = vName
                }
                if let vCode = evaluated.versionCode, !vCode.isEmpty {
                    versionCode = vCode
                }
            }
        }

        return (versionName: versionName, versionCode: versionCode)
    }

    /// Evaluates the Android project model dynamically by executing Gradle with a temporary init-script.
    /// This captures the runtime-evaluated `versionCode`, `versionName`, `applicationId`, `packageName`, `namespace`, and product flavors
    /// (e.g. when determined by properties, ternaries, or dynamic functions in Gradle).
    public static func evaluateAppInfoViaGradle(
        workspaceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        offline: Bool = false,
        flavor: String? = nil
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
                                    def fAppId = f.hasProperty("applicationId") ? (f.applicationId ?: "") : ""
                                    def fAppIdSuffix = f.hasProperty("applicationIdSuffix") ? (f.applicationIdSuffix ?: "") : ""
                                    def fVn = f.hasProperty("versionName") ? (f.versionName ?: "") : ""
                                    def fVnSuffix = f.hasProperty("versionNameSuffix") ? (f.versionNameSuffix ?: "") : ""
                                    def fVc = f.hasProperty("versionCode") ? (f.versionCode ?: "") : ""
                                    println "APPI_FLAVOR=${f.name}|${fAppId}|${fAppIdSuffix}|${fVn}|${fVnSuffix}|${fVc}"
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

        let result = try await ProcessRunner.run(
            gradlewUrl.path,
            arguments: args,
            workingDirectory: androidRoot.path,
            combineOutput: true
        )

        guard result.isSuccess else {
            throw NSError(
                domain: "AndroidTasks",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Gradle evaluation failed (exit code \(result.exitCode)): \(result.stdout)"]
            )
        }

        return Self.parseGradleAppInfoOutput(result.stdout, flavor: flavor)
    }

    internal static func parseGradleAppInfoOutput(_ output: String, flavor: String? = nil) -> GradleAppInfo {
        var versionCode: String?
        var versionName: String?
        var applicationId: String?
        var namespace: String?
        var flavors: [AndroidFlavor] = []

        for line in output.components(separatedBy: .newlines) {
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
                let cleanField: (Int) -> String? = { idx in
                    guard parts.count > idx else { return nil }
                    let val = parts[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    return (!val.isEmpty && val != "null") ? val : nil
                }
                if let name = cleanField(0) {
                    flavors.append(AndroidFlavor(
                        name: name,
                        applicationId: cleanField(1),
                        applicationIdSuffix: cleanField(2),
                        versionName: cleanField(3),
                        versionNameSuffix: cleanField(4),
                        versionCode: cleanField(5)
                    ))
                }
            }
        }

        let effective = resolveEffectiveVersion(
            defaultVersionName: versionName,
            defaultVersionCode: versionCode,
            flavors: flavors,
            flavor: flavor
        )
        let packageName = applicationId ?? namespace

        return GradleAppInfo(
            versionCode: effective.versionCode,
            versionName: effective.versionName,
            applicationId: applicationId,
            packageName: packageName,
            namespace: namespace,
            flavors: flavors
        )
    }
}

