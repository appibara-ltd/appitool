import Foundation

/// Holds the shared mutable state and artifacts throughout a single flow lifecycle execution.
struct FlowContext: Sendable {
    enum Platform: String, Sendable {
        case ios
        case android

        var icon: String {
            switch self {
            case .ios: return "🍎"
            case .android: return "🤖"
            }
        }
    }

    let platform: Platform
    let distribution: BuildCommand.Distribution
    let projectDirectory: URL
    let isDryRun: Bool
    let startTime: Date

    // Tracking
    var currentStage: FlowStage?
    var stageDurations: [FlowStage: TimeInterval] = [:]

    // Configuration / Project Identifiers
    var bundleId: String? // Bundle ID (iOS) or Package Name (Android)
    var projectPath: URL?
    var workspacePath: String?
    var xcodeProjectPath: String?
    var scheme: String?
    var targetName: String?

    // Pre-build state
    var version: String?
    var buildNumber: String?

    // Build / Post-build state
    var artifactPaths: [URL] = []

    // Pre-release state
    var changelog: String?

    // Custom metadata dictionary for stages to pass data
    var metadata: [String: String] = [:]

    // Notification configuration
    var slackUrl: String?
    var kokonoUrl: String?
    var kokonoPublicKey: String?

    // Preconfigured flow preset
    var preset: (any FlowPreset)?

    init(
        platform: Platform,
        distribution: BuildCommand.Distribution,
        projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        isDryRun: Bool = false,
        bundleId: String? = nil,
        workspacePath: String? = nil,
        xcodeProjectPath: String? = nil,
        scheme: String? = nil,
        targetName: String? = nil,
        slackUrl: String? = nil,
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil,
        preset: (any FlowPreset)? = nil
    ) {
        self.platform = platform
        self.distribution = distribution
        self.projectDirectory = projectDirectory
        self.isDryRun = isDryRun
        self.startTime = Date()
        self.bundleId = bundleId
        self.workspacePath = workspacePath
        self.xcodeProjectPath = xcodeProjectPath
        self.scheme = scheme
        self.targetName = targetName
        self.slackUrl = slackUrl
        self.kokonoUrl = kokonoUrl
        self.kokonoPublicKey = kokonoPublicKey
        self.preset = preset
    }
}
