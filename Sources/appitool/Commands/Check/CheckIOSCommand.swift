import ArgumentParser
import Foundation
import AppleServices
import GoogleServices
import Rainbow

struct CheckIOSCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Checks iOS application and build information from distribution providers."
    )

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to adhoc.")
    var distribution: BuildCommand.Distribution = .adhoc

    @Option(name: .shortAndLong, help: "Target iOS bundle identifier (defaults to main target bundle ID from project).")
    var bundleId: String?

    @Option(name: .long, help: "Firebase App ID for iOS (defaults to FIREBASE_IOS_APP_ID in .env).")
    var firebaseAppId: String?

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    func execute() async throws {
        var targetBundleId = bundleId
        if targetBundleId == nil || targetBundleId?.isEmpty == true {
            if XCodeTasks.hasIosProject() {
                if let resolved = try? await XCodeTasks.getIosIdentifiers() {
                    targetBundleId = resolved.bundleId
                }
            }
        }

        switch distribution {
        case .adhoc:
            guard let resolvedAppId = firebaseAppId ?? EnvLoader.value(for: "FIREBASE_IOS_APP_ID"), !resolvedAppId.isEmpty else {
                throw CommandError("Missing Firebase App ID for iOS. Provide --firebase-app-id or configure FIREBASE_IOS_APP_ID in .env.")
            }

            let googleKey = googleCredentials.resolveKey()
            guard let service = try FirebaseService.makeService(googleKey: googleKey) else {
                throw CommandError("Missing Firebase credentials. Provide -g, --google-key or configure GOOGLE_KEY in .env.")
            }

            Log("Checking Firebase iOS App information...".dim)
            let appTask = GetFirebaseAppInfoTask()
            guard case .ios(let app) = try await appTask.run(.init(platform: .ios, firebaseAppId: resolvedAppId, service: service)) else {
                return
            }
            Log("\n" + "─── Firebase iOS App Information ───".cyan.bold)
            if let appId = app.appId {
                Log("App ID:        ".bold + "\(appId)".green)
            }
            if let resolvedBundleId = app.bundleId {
                Log("Bundle ID:     ".bold + "\(resolvedBundleId)".yellow)
            }
            if let displayName = app.displayName {
                Log("Display Name:  ".bold + "\(displayName)")
            }
            if let projectId = app.projectId {
                Log("Project ID:    ".bold + "\(projectId)")
            }
            if let appStoreId = app.appStoreId {
                Log("App Store ID:  ".bold + "\(appStoreId)")
            }
            if let teamId = app.teamId {
                Log("Team ID:       ".bold + "\(teamId)")
            }
            if let state = app.state {
                Log("State:         ".bold + "\(state.rawValue)")
            }

            let buildTask = GetLatestBuildNumberTask()
            if let buildInfo = try? await buildTask.run(.init(
                target: .ios(bundleId: targetBundleId ?? app.bundleId, firebaseAppId: resolvedAppId, firebaseService: service),
                distribution: .adhoc
            )) {
                Log("Latest Build:  ".bold + "v\(buildInfo.version) (\(buildInfo.buildNumber))".green.bold)
            }
            Log("────────────────────────────────────".cyan.dim + "\n")

        case .appstore:
            guard let targetBundleId, !targetBundleId.isEmpty else {
                throw CommandError("No bundle identifier specified. Provide -b, --bundle-id or ensure an Xcode project exists.")
            }

            let service = try appleCredentials.requireService()

            Log("Fetching latest build from App Store Connect for ".dim + "\(targetBundleId)".bold + "...".dim)
            let info = try await GetLatestBuildNumberTask().run(.init(
                target: .ios(bundleId: targetBundleId, service: service),
                distribution: .appstore
            ))
            Log("\n" + "─── App Store Connect Build Information ───".cyan.bold)
            Log("Bundle ID:     ".bold + "\(targetBundleId)".yellow)
            Log("Version:       ".bold + "\(info.version)".green)
            Log("Build Number:  ".bold + "\(info.buildNumber)".green.bold)
            Log("───────────────────────────────────────────".cyan.dim + "\n")

        case .development:
            Log("Development distribution has no remote information to check.".yellow)
        }
    }
}
