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

    init(
        platform: Platform,
        distribution: BuildCommand.Distribution,
        projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        isDryRun: Bool = false,
        bundleId: String? = nil,
        slackUrl: String? = nil,
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil
    ) {
        self.platform = platform
        self.distribution = distribution
        self.projectDirectory = projectDirectory
        self.isDryRun = isDryRun
        self.startTime = Date()
        self.bundleId = bundleId
        self.slackUrl = slackUrl
        self.kokonoUrl = kokonoUrl
        self.kokonoPublicKey = kokonoPublicKey
    }
}
