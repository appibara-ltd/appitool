import ArgumentParser
import Foundation
import Rainbow

/// A task that handles building Android applications using Gradle (`gradlew`),
/// producing Android App Bundles (AAB) or APK artifacts.
public struct GradleTask: Task {
    /// Target artifact packaging format.
    public enum BuildFormat: String, Sendable, CaseIterable, ExpressibleByArgument {
        case aab
        case apk
    }

    /// Keystore signing configuration passed to Gradle via injected project properties.
    public struct SigningConfig: Sendable {
        public let storeFile: String
        public let storePassword: String
        public let keyAlias: String
        public let keyPassword: String

        public init(
            storeFile: String,
            storePassword: String,
            keyAlias: String,
            keyPassword: String
        ) {
            self.storeFile = storeFile
            self.storePassword = storePassword
            self.keyAlias = keyAlias
            self.keyPassword = keyPassword
        }
    }

    /// Configuration input for `GradleTask`.
    public struct Input: Sendable {
        /// Project directory containing `gradlew` (or the Android root directory).
        public let projectDirectory: String

        /// Gradle tasks to execute (e.g. `["bundleRelease"]` or `["assembleRelease"]`).
        /// If empty, automatically determined from `format`, `flavor`, and `buildType`.
        public let tasks: [String]

        /// Build type (e.g., "release", "debug"). Defaults to "release".
        public let buildType: String

        /// Product flavor (e.g., "production", "staging").
        public let flavor: String?

        /// Preferred build artifact format (.aab or .apk). Defaults to `.aab`.
        public let format: BuildFormat

        /// Custom output directory to collect generated artifacts into.
        public let outputDirectory: String?

        /// Custom base name for the output artifact (without file extension).
        public let artifactName: String?

        /// Keystore signing configuration.
        public let signing: SigningConfig?

        /// Gradle project properties passed via `-Pname=value` (e.g., versionCode, versionName).
        public let properties: [String: String]

        /// System properties passed via `-Dname=value` (e.g., caching, JVM arguments).
        public let systemProperties: [String: String]

        /// Additional CLI flags passed directly to Gradle (e.g., `["--build-cache", "--no-daemon"]`).
        public let flags: [String]

        /// Whether to invoke the `clean` task before building. Defaults to `false`.
        public let clean: Bool

        /// Whether to suppress printing Gradle commands and stdout. Defaults to `false`.
        public let silent: Bool

        /// Optional formatter command for Gradle output.
        public let formatter: String?

        /// Environment variables passed directly to the Gradle execution process. Defaults to nil (inherits process environment).
        public let environment: [String: String]?

        public init(
            projectDirectory: String,
            tasks: [String] = [],
            buildType: String = "release",
            flavor: String? = nil,
            format: BuildFormat = .aab,
            outputDirectory: String? = nil,
            artifactName: String? = nil,
            signing: SigningConfig? = nil,
            properties: [String: String] = [:],
            systemProperties: [String: String] = [:],
            flags: [String] = ["--build-cache", "--no-daemon"],
            clean: Bool = false,
            silent: Bool = false,
            formatter: String? = nil,
            environment: [String: String]? = nil
        ) {
            self.projectDirectory = projectDirectory
            self.tasks = tasks
            self.buildType = buildType
            self.flavor = flavor
            self.format = format
            self.outputDirectory = outputDirectory
            self.artifactName = artifactName
            self.signing = signing
            self.properties = properties
            self.systemProperties = systemProperties
            self.flags = flags
            self.clean = clean
            self.silent = silent
            self.formatter = formatter
            self.environment = environment
        }
    }

    /// Result containing generated Android build artifacts.
    public struct Output: Sendable {
        /// Primary Android App Bundle (.aab) artifact path, if produced.
        public let aabPath: String?

        /// Primary APK (.apk) artifact path, if produced.
        public let apkPath: String?

        /// All discovered output artifacts in the build directory.
        public let allArtifactPaths: [String]

        public init(
            aabPath: String? = nil,
            apkPath: String? = nil,
            allArtifactPaths: [String] = []
        ) {
            self.aabPath = aabPath
            self.apkPath = apkPath
            self.allArtifactPaths = allArtifactPaths
        }
    }

    /// Errors thrown during `GradleTask` execution.
    public enum GradleError: LocalizedError, Sendable {
        case gradlewNotFound(expectedPath: String)
        case buildFailed(exitCode: Int32, output: String)
        case artifactNotFound(expectedFormat: BuildFormat)

        public var errorDescription: String? {
            switch self {
            case .gradlewNotFound(let path):
                return "Gradle wrapper executable not found at: \(path)"
            case .buildFailed(let code, let output):
                return "Gradle build failed with exit code \(code): \(output)"
            case .artifactNotFound(let format):
                return "Expected .\(format.rawValue) artifact was not found after Gradle build."
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        let fm = FileManager.default

        // 1. Locate gradlew executable
        let (gradlewPath, workingDirectory) = try locateGradlew(in: input.projectDirectory)

        // 2. Ensure gradlew is executable
        try ensureExecutable(at: gradlewPath)

        // 3. Resolve Gradle task list
        var tasksToRun = input.tasks
        if tasksToRun.isEmpty {
            let taskName = Self.resolveTaskName(
                format: input.format,
                buildType: input.buildType,
                flavor: input.flavor
            )
            tasksToRun = [taskName]
        }

        if input.clean && !tasksToRun.contains("clean") {
            tasksToRun.insert("clean", at: 0)
        }

        // 4. Assemble system properties (-D...)
        var systemProps: [String: String] = [
            "org.gradle.daemon": "false",
            "org.gradle.caching": "true",
            "org.gradle.parallel": "true"
        ]
        for (k, v) in input.systemProperties {
            if k != "org.gradle.jvmargs" {
                systemProps[k] = v
            }
        }
        // Strictly forbid daemon
        systemProps["org.gradle.daemon"] = "false"

        // 5. Assemble project properties (-P...)
        var projectProps = input.properties
        if let signing = input.signing {
            projectProps["android.injected.signing.store.file"] = signing.storeFile
            projectProps["android.injected.signing.store.password"] = signing.storePassword
            projectProps["android.injected.signing.key.alias"] = signing.keyAlias
            projectProps["android.injected.signing.key.password"] = signing.keyPassword
        }

        // 6. Build command-line arguments (Flags & properties MUST precede tasks)
        var args: [String] = []

        var sanitizedFlags = input.flags.filter { $0 != "--daemon" }
        if !sanitizedFlags.contains("--no-daemon") {
            sanitizedFlags.insert("--no-daemon", at: 0)
        }
        args.append(contentsOf: sanitizedFlags)

        for (k, v) in systemProps.sorted(by: { $0.key < $1.key }) {
            args.append("-D\(k)=\(v)")
        }

        for (k, v) in projectProps.sorted(by: { $0.key < $1.key }) {
            args.append("-P\(k)=\(v)")
        }

        args.append(contentsOf: tasksToRun)

        if !input.silent {
            let displayTasks = tasksToRun.joined(separator: ", ")
            Log("🚀 Executing Gradle build: ".cyan.bold + "\(displayTasks)".bold)
            Log("   Working Dir: ".dim + "\(workingDirectory)".dim)
            if let signing = input.signing {
                Log("   Keystore:    ".dim + "\(signing.storeFile)".yellow)
                Log("   Key Alias:   ".dim + "\(signing.keyAlias)".yellow)
            }
        }

        // 7. Execute Gradle command
        let result = try await ProcessRunner.stream(
            gradlewPath,
            arguments: args,
            workingDirectory: workingDirectory,
            environment: input.environment,
            formatter: input.formatter,
            style: input.silent ? .silent : .rawStdout
        )

        guard result.exitCode == 0 else {
            throw GradleError.buildFailed(exitCode: result.exitCode, output: result.stdout)
        }

        // 8. Discover generated artifacts
        let discoveredArtifacts = discoverArtifacts(in: workingDirectory, format: input.format)

        guard let latestArtifact = discoveredArtifacts.first else {
            throw GradleError.artifactNotFound(expectedFormat: input.format)
        }

        // 9. Copy to output directory if specified
        var finalAabPath: String? = nil
        var finalApkPath: String? = nil
        var allCopiedPaths: [String] = []

        if let outputDir = input.outputDirectory {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

            let ext = input.format.rawValue
            let baseName = input.artifactName ?? URL(fileURLWithPath: latestArtifact).deletingPathExtension().lastPathComponent
            let destinationPath = URL(fileURLWithPath: outputDir).appendingPathComponent("\(baseName).\(ext)").path

            if fm.fileExists(atPath: destinationPath) {
                try? fm.removeItem(atPath: destinationPath)
            }

            try fm.copyItem(atPath: latestArtifact, toPath: destinationPath)
            try? fm.removeItem(atPath: latestArtifact)
            allCopiedPaths.append(destinationPath)

            switch input.format {
            case .aab:
                finalAabPath = destinationPath
            case .apk:
                finalApkPath = destinationPath
            }
        } else {
            switch input.format {
            case .aab:
                finalAabPath = latestArtifact
            case .apk:
                finalApkPath = latestArtifact
            }
            allCopiedPaths = discoveredArtifacts
        }

        return Output(
            aabPath: finalAabPath,
            apkPath: finalApkPath,
            allArtifactPaths: allCopiedPaths
        )
    }

    // MARK: - Task Name Resolution

    /// Resolves the Gradle task name given the format, build type, and flavor.
    /// Example: format `.aab`, buildType `"release"`, flavor `"production"` -> `"bundleProductionRelease"`
    public static func resolveTaskName(format: BuildFormat, buildType: String, flavor: String?) -> String {
        let action = format == .aab ? "bundle" : "assemble"
        let capitalizedType = buildType.prefix(1).uppercased() + buildType.dropFirst()

        if let flavor = flavor, !flavor.isEmpty {
            let capitalizedFlavor = flavor.prefix(1).uppercased() + flavor.dropFirst()
            return "\(action)\(capitalizedFlavor)\(capitalizedType)"
        } else {
            return "\(action)\(capitalizedType)"
        }
    }

    // MARK: - Executable & Path Resolution

    private func locateGradlew(in projectDirectory: String) throws -> (gradlewPath: String, workingDir: String) {
        let fm = FileManager.default
        let expanded = NSString(string: projectDirectory).expandingTildeInPath

        // Candidates to search
        let candidates = [
            URL(fileURLWithPath: expanded).appendingPathComponent("gradlew").path,
            URL(fileURLWithPath: expanded).appendingPathComponent("android").appendingPathComponent("gradlew").path,
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("android").appendingPathComponent("gradlew").path,
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("gradlew").path
        ]

        for path in candidates {
            if fm.fileExists(atPath: path) {
                let workingDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                return (path, workingDir)
            }
        }

        throw GradleError.gradlewNotFound(expectedPath: "\(expanded)/gradlew")
    }

    private func ensureExecutable(at path: String) throws {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: path) {
            let attrs = try? fm.attributesOfItem(atPath: path)
            let currentPermissions = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let newPermissions = currentPermissions | 0o755
            try? fm.setAttributes([.posixPermissions: NSNumber(value: newPermissions)], ofItemAtPath: path)
        }
    }

    // MARK: - Artifact Discovery

    private func discoverArtifacts(in workingDirectory: String, format: BuildFormat) -> [String] {
        let fm = FileManager.default
        let ext = format.rawValue
        var candidates: [String] = []

        // Search primary build outputs folders first
        let primarySubdir = format == .aab ? "bundle" : "apk"
        let standardOutputs = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent("app")
            .appendingPathComponent("build")
            .appendingPathComponent("outputs")
            .appendingPathComponent(primarySubdir)

        if let enumerator = fm.enumerator(at: standardOutputs, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == ext {
                    candidates.append(fileURL.path)
                }
            }
        }

        // Fallback: search any build/outputs folder under working directory
        if candidates.isEmpty {
            let workingURL = URL(fileURLWithPath: workingDirectory)
            if let enumerator = fm.enumerator(at: workingURL, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == ext && fileURL.path.contains("/build/outputs/") {
                        candidates.append(fileURL.path)
                    }
                }
            }
        }

        // Sort artifacts descending by modification date (newest first)
        return candidates.compactMap { path -> (String, Date)? in
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let date = attrs[.modificationDate] as? Date else {
                return (path, Date.distantPast)
            }
            return (path, date)
        }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
