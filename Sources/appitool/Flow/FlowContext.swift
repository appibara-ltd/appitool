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
    var configuration: String?
    var targetName: String?

    // Match / Code Signing Configuration
    var matchGitUrl: String?
    var matchGitBranch: String?
    var matchGitToken: String?
    var matchPassword: String?
    var matchKeychainName: String?
    var matchKeychainPassword: String?
    var matchReadonly: Bool = true
    var teamId: String?
    var appleKeyId: String?
    var appleIssuerId: String?
    var appleKey: String?

    // Firebase Configuration
    var firebaseAppId: String?
    var googleKey: String?

    // Match / Code Signing Artifacts
    var installedCertificates: [String] = []
    var installedProfiles: [String: MatchTask.ProfileInfo] = [:]

    // Android Product Flavors
    var androidFlavors: [AndroidTasks.AndroidFlavor] = []

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

    // Build configuration
    var silent: Bool = false

    init(
        platform: Platform,
        distribution: BuildCommand.Distribution,
        projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        isDryRun: Bool = false,
        bundleId: String? = nil,
        workspacePath: String? = nil,
        xcodeProjectPath: String? = nil,
        scheme: String? = nil,
        configuration: String? = nil,
        targetName: String? = nil,
        matchGitUrl: String? = nil,
        matchGitBranch: String? = nil,
        matchGitToken: String? = nil,
        matchPassword: String? = nil,
        matchKeychainName: String? = nil,
        matchKeychainPassword: String? = nil,
        matchReadonly: Bool = true,
        teamId: String? = nil,
        appleKeyId: String? = nil,
        appleIssuerId: String? = nil,
        appleKey: String? = nil,
        firebaseAppId: String? = nil,
        googleKey: String? = nil,
        slackUrl: String? = nil,
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil,
        preset: (any FlowPreset)? = nil,
        silent: Bool = false,
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
        self.configuration = configuration
        self.targetName = targetName
        self.matchGitUrl = matchGitUrl
        self.matchGitBranch = matchGitBranch
        self.matchGitToken = matchGitToken
        self.matchPassword = matchPassword
        self.matchKeychainName = matchKeychainName
        self.matchKeychainPassword = matchKeychainPassword
        self.matchReadonly = matchReadonly
        self.teamId = teamId
        self.appleKeyId = appleKeyId
        self.appleIssuerId = appleIssuerId
        self.appleKey = appleKey
        self.firebaseAppId = firebaseAppId
        self.googleKey = googleKey
        self.slackUrl = slackUrl
        self.kokonoUrl = kokonoUrl
        self.kokonoPublicKey = kokonoPublicKey
        self.preset = preset
        self.silent = silent
    }
}
