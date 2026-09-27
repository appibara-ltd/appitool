import Foundation

/// A task that handles building and archiving iOS applications using `xcodebuild`
/// (comparable to Fastlane's `build_app` / `gym` action).
public struct XcodeBuildTask: Task {
    /// Export method options for IPA packaging.
    public enum ExportMethod: String, Sendable, CaseIterable {
        case appStore = "app-store"
        case adHoc = "ad-hoc"
        case enterprise = "enterprise"
        case development = "development"
    }

    /// Configuration input for `XcodeBuildTask`.
    public struct Input: Sendable {
        /// Path to the `.xcworkspace` file (if using a workspace).
        public let workspace: String?

        /// Path to the `.xcodeproj` file (if using a project directly).
        public let project: String?

        /// The scheme to build.
        public let scheme: String

        /// Build configuration (e.g., "Release", "Debug"). Defaults to "Release".
        public let configuration: String

        /// The destination specifier (e.g., "generic/platform=iOS").
        public let destination: String

        /// SDK to build against (e.g., "iphoneos").
        public let sdk: String?

        /// Directory where the xcarchive and exported artifacts will be stored.
        public let outputDirectory: String

        /// Optional custom name for the exported archive / IPA.
        public let outputName: String?

        /// Distribution method used for generating export options plist.
        public let exportMethod: ExportMethod

        /// Optional path to a custom `ExportOptions.plist` file.
        public let exportOptionsPlist: String?

        /// Apple Developer Team ID used for code signing / export.
        public let exportTeamId: String?

        /// Whether to clean the build folder before building. Defaults to `false`.
        public let clean: Bool

        /// Path to derived data directory.
        public let derivedDataPath: String?

        /// Additional arguments passed directly to `xcodebuild`.
        public let xcargs: [String]

        public init(
            workspace: String? = nil,
            project: String? = nil,
            scheme: String,
            configuration: String = "Release",
            destination: String = "generic/platform=iOS",
            sdk: String? = "iphoneos",
            outputDirectory: String,
            outputName: String? = nil,
            exportMethod: ExportMethod = .appStore,
            exportOptionsPlist: String? = nil,
            exportTeamId: String? = nil,
            clean: Bool = false,
            derivedDataPath: String? = nil,
            xcargs: [String] = []
        ) {
            self.workspace = workspace
            self.project = project
            self.scheme = scheme
            self.configuration = configuration
            self.destination = destination
            self.sdk = sdk
            self.outputDirectory = outputDirectory
            self.outputName = outputName
            self.exportMethod = exportMethod
            self.exportOptionsPlist = exportOptionsPlist
            self.exportTeamId = exportTeamId
            self.clean = clean
            self.derivedDataPath = derivedDataPath
            self.xcargs = xcargs
        }
    }

    /// Result containing generated artifacts from `XcodeBuildTask`.
    public struct Output: Sendable {
        /// Path to the generated `.xcarchive` directory.
        public let archivePath: String?

        /// Path to the exported `.ipa` file.
        public let ipaPath: String?

        /// Path to generated `.dSYM.zip` file (if symbols were exported).
        public let dsymPath: String?

        /// Directory containing all output artifacts.
        public let outputDirectory: String

        public init(
            archivePath: String? = nil,
            ipaPath: String? = nil,
            dsymPath: String? = nil,
            outputDirectory: String
        ) {
            self.archivePath = archivePath
            self.ipaPath = ipaPath
            self.dsymPath = dsymPath
            self.outputDirectory = outputDirectory
        }
    }

    /// Errors thrown during `XcodeBuildTask` execution.
    public enum XcodeBuildError: LocalizedError, Sendable {
        case missingWorkspaceOrProject
        case schemeNotFound(String)
        case archiveFailed(exitCode: Int32, output: String)
        case exportFailed(exitCode: Int32, output: String)
        case ipaNotFound(expectedPath: String)
        case notImplemented

        public var errorDescription: String? {
            switch self {
            case .missingWorkspaceOrProject:
                return "Either workspace or project path must be specified for xcodebuild."
            case .schemeNotFound(let scheme):
                return "Specified scheme '\(scheme)' was not found."
            case .archiveFailed(let code, let output):
                return "xcodebuild archive failed with exit code \(code): \(output)"
            case .exportFailed(let code, let output):
                return "xcodebuild -exportArchive failed with exit code \(code): \(output)"
            case .ipaNotFound(let path):
                return "Exported IPA file was not found at expected path: \(path)"
            case .notImplemented:
                return "XcodeBuildTask execution logic is not yet implemented."
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        // Boilerplate placeholder
        return Output(outputDirectory: input.outputDirectory)
    }
}
