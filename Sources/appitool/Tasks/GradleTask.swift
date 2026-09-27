import Foundation

/// A task that handles building Android applications using Gradle (`gradlew`),
/// producing Android App Bundles (AAB) or APK artifacts.
public struct GradleTask: Task {
    /// Target artifact packaging format.
    public enum BuildFormat: String, Sendable, CaseIterable {
        case aab
        case apk
    }

    /// Configuration input for `GradleTask`.
    public struct Input: Sendable {
        /// Project directory containing `gradlew` (or the Android root directory).
        public let projectDirectory: String

        /// Gradle tasks to execute (e.g. `["bundleRelease"]` or `["assembleRelease"]`).
        public let tasks: [String]

        /// Build type (e.g., "release", "debug").
        public let buildType: String?

        /// Product flavor (e.g., "production", "staging").
        public let flavor: String?

        /// Preferred build artifact format (.aab or .apk). Defaults to `.aab`.
        public let format: BuildFormat

        /// Custom output directory to collect generated artifacts into.
        public let outputDirectory: String?

        /// Gradle project properties passed via `-Pname=value` (e.g., versionCode, versionName).
        public let properties: [String: String]

        /// Additional CLI flags passed directly to Gradle (e.g., `["--no-daemon", "--stacktrace"]`).
        public let flags: [String]

        /// Whether to invoke the `clean` task before building. Defaults to `false`.
        public let clean: Bool

        public init(
            projectDirectory: String,
            tasks: [String] = ["bundleRelease"],
            buildType: String? = "release",
            flavor: String? = nil,
            format: BuildFormat = .aab,
            outputDirectory: String? = nil,
            properties: [String: String] = [:],
            flags: [String] = ["--no-daemon", "--stacktrace"],
            clean: Bool = false
        ) {
            self.projectDirectory = projectDirectory
            self.tasks = tasks
            self.buildType = buildType
            self.flavor = flavor
            self.format = format
            self.outputDirectory = outputDirectory
            self.properties = properties
            self.flags = flags
            self.clean = clean
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
        case notImplemented

        public var errorDescription: String? {
            switch self {
            case .gradlewNotFound(let path):
                return "Gradle wrapper executable not found at: \(path)"
            case .buildFailed(let code, let output):
                return "Gradle build failed with exit code \(code): \(output)"
            case .artifactNotFound(let format):
                return "Expected .\(format.rawValue) artifact was not found after Gradle build."
            case .notImplemented:
                return "GradleTask execution logic is not yet implemented."
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        // Boilerplate placeholder
        return Output()
    }
}
