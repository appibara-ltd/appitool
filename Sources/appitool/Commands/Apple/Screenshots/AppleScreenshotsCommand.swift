import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices

struct AppleScreenshotsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshots",
        abstract: "List, upload, and delete App Store Connect app screenshots.",
        subcommands: [
            AppleScreenshotsListCommand.self,
            AppleScreenshotsUploadCommand.self,
            AppleScreenshotsDownloadCommand.self,
            AppleScreenshotsDeleteCommand.self,
            AppleScreenshotsTypesCommand.self,
        ]
    )
}

/// Shared CLI options and resolution helpers for App Store Connect screenshot commands.
struct AppleScreenshotAppOptions: ParsableArguments, Sendable {
    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Target bundle identifier (defaults to APPLE_BUNDLE_ID in .env or local Xcode project).")
    var bundleId: String?

    @Option(name: .long, help: "App Store Connect App ID (numeric; takes precedence over --bundle-id).")
    var appId: String?

    @Option(name: .long, help: "Target platform (ios, macos, tvos, visionos). Defaults to ios.")
    var platform: String = "ios"

    // Avoid `--version` because root `appitool` defines `version:` which ArgumentParser intercepts.
    @Option(name: [.customShort("v"), .customLong("app-version")], help: "Target App Store version string (e.g. 1.2.0; auto-selects editable version when omitted).")
    var appVersion: String?

    func requireService() throws -> AppStoreService {
        try appleCredentials.requireService()
    }

    func parsedPlatform() throws -> Components.Schemas.Platform {
        try AppleTypeMapper.parsePlatform(platform)
    }

    func resolveBundleIdOrAppId() async -> (appId: String?, bundleId: String?) {
        if let explicitAppId = AppleCommandHelpers.trimmedNonEmpty(appId) {
            return (explicitAppId, nil)
        }
        if let explicitBundleId = AppleCommandHelpers.trimmedNonEmpty(bundleId) {
            return (nil, explicitBundleId)
        }
        if let envBundleId = AppleCommandHelpers.trimmedNonEmpty(EnvLoader.value(for: "APPLE_BUNDLE_ID")) {
            return (nil, envBundleId)
        }
        if XCodeTasks.hasIosProject(),
           let detected = try? await XCodeTasks.getIosIdentifiers(),
           let detectedBundle = AppleCommandHelpers.trimmedNonEmpty(detected.bundleId) {
            return (nil, detectedBundle)
        }
        return (nil, nil)
    }

    func resolveAppId(service: AppStoreService) async throws -> String {
        let candidate = await resolveBundleIdOrAppId()
        if let resolvedAppId = candidate.appId {
            return resolvedAppId
        }
        guard let targetBundleId = candidate.bundleId else {
            throw ValidationError(
                "Missing App Store Connect App ID or bundle identifier. Provide -b, --bundle-id, --app-id, set APPLE_BUNDLE_ID in .env, or run inside an Xcode project."
            )
        }
        let ids = try await service.resolveAppIds([targetBundleId])
        guard let first = ids.first else {
            throw AppStoreServiceError.notFound("App with bundle ID '\(targetBundleId)' was not found in App Store Connect.")
        }
        return first
    }
}
