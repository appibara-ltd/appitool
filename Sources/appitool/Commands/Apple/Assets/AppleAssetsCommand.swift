import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices

/// App Store product page assets: screenshots plus the product page header and search results images.
struct AppleAssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assets",
        abstract: "List, upload, download, and delete App Store screenshots, product page header, and search results images.",
        subcommands: [
            AppleAssetsListCommand.self,
            AppleAssetsUploadCommand.self,
            AppleAssetsDownloadCommand.self,
            AppleAssetsDeleteCommand.self,
            AppleAssetsTypesCommand.self,
            AppleAssetsSpecsCommand.self,
        ]
    )
}

/// Shared CLI options and resolution helpers for `apple assets` commands.
struct AppleAssetAppOptions: ParsableArguments, Sendable {
    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Target bundle identifier (defaults to APPLE_BUNDLE_ID in .env or local Xcode project).")
    var bundleId: String?

    @Option(name: .long, help: "App Store Connect App ID (numeric; takes precedence over --bundle-id).")
    var appId: String?

    @Option(name: .shortAndLong, help: "Target platform (ios, macos, tvos, visionos). Defaults to ios.")
    var platform: String = "ios"

    // Avoid `--version` because root `appitool` defines `version:` which ArgumentParser intercepts.
    @Option(name: .customLong("app-version"), help: "Target App Store version string (e.g. 1.2.0; auto-selects editable version when omitted).")
    var appVersion: String?

    func requireService() throws -> AppStoreService {
        try appleCredentials.requireService()
    }

    func parsedPlatform() throws -> Components.Schemas.Platform {
        try AppleTypeMapper.parsePlatform(platform)
    }

    func resolveBundleIdOrAppId() async -> (appId: String?, bundleId: String?) {
        if let explicitAppId = CLIValues.trimmedNonEmpty(appId) {
            return (explicitAppId, nil)
        }
        return (nil, await AppIdentifierResolver.iosBundleId(explicit: bundleId))
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
