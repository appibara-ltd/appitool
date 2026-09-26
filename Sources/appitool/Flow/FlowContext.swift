import Foundation

/// Holds the shared mutable state and artifacts throughout a single flow lifecycle execution.
struct FlowContext: Sendable {
    enum Platform: String, Sendable {
        case ios
        case android
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
    var appId: String? // Bundle ID (iOS) or Package Name (Android)
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
    var kokonoUrl: String?
    var kokonoPublicKey: String?

    init(
        platform: Platform,
        distribution: BuildCommand.Distribution,
        projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        isDryRun: Bool = false,
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil
    ) {
        self.platform = platform
        self.distribution = distribution
        self.projectDirectory = projectDirectory
        self.isDryRun = isDryRun
        self.startTime = Date()
        self.kokonoUrl = kokonoUrl
        self.kokonoPublicKey = kokonoPublicKey
    }
}
