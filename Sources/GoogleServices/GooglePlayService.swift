import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAPIURLSession
import OpenAPIRuntime
import GooglePlayStoreAPI
import GooglePlayReportingAPI
import GooglePlayGamesConfigurationAPI
import GooglePlayIntegrityAPI
import GooglePlayCustomAppAPI
import GooglePlayGamesManagementAPI

/// Unified service providing access to all Google Play Developer APIs:
/// - `client`: Publishing API (edits, tracks, releases, in-app products, reviews, users/permissions)
/// - `reporting`: Developer Reporting API (Android vitals, crash rates, ANR rates, anomalies, error reports)
/// - `games`: Games Services Publishing API (achievements, leaderboards, game configurations)
/// - `integrity`: Play Integrity API (verifying runtime app/device integrity tokens)
/// - `customApps`: Custom App Publishing API (publishing private enterprise apps)
/// - `gamesManagement`: Games Services Management API (testing/resetting achievements and leaderboards)
package struct GooglePlayService: Sendable {
    package static let sharedTransport = URLSessionTransport()

    /// The underlying authentication middleware.
    package let authMiddleware: GooglePlayAuthMiddleware

    /// Underlying URLSession used for direct binary media uploads.
    package let urlSession: URLSession

    /// The underlying OpenAPI client for the Google Play Developer Publishing API (androidpublisher v3).
    package let client: GooglePlayStoreAPI.Client

    /// The underlying OpenAPI client for the Google Play Developer Reporting API (playdeveloperreporting v1beta1).
    package let reporting: GooglePlayReportingAPI.Client

    /// The underlying OpenAPI client for the Google Play Games Services Publishing API (gamesConfiguration v1).
    package let games: GooglePlayGamesConfigurationAPI.Client

    /// The underlying OpenAPI client for the Google Play Integrity API (playintegrity v1).
    package let integrity: GooglePlayIntegrityAPI.Client

    /// The underlying OpenAPI client for the Google Play Custom App Publishing API (playcustomapp v1).
    package let customApps: GooglePlayCustomAppAPI.Client

    /// The underlying OpenAPI client for the Google Play Games Services Management API (gamesManagement v1).
    package let gamesManagement: GooglePlayGamesManagementAPI.Client

    /// Initializes GooglePlayService with credentials (key can be a service account JSON file path, raw JSON, or Base64-encoded JSON).
    /// Uses a single shared AuthMiddleware and token exchange for all Google Play APIs.
    package init(
        key: String,
        scope: String = GooglePlayAuthMiddleware.allScopes,
        transport: any ClientTransport = Self.sharedTransport,
        urlSession: URLSession = .shared
    ) throws {
        let authMiddleware = try GooglePlayAuthMiddleware(key: key, scope: scope, urlSession: urlSession)
        self.authMiddleware = authMiddleware
        self.urlSession = urlSession

        self.client = GooglePlayStoreAPI.Client(serverURL: try GooglePlayStoreAPI.Servers.Server1.url(), transport: transport, middlewares: [authMiddleware])
        self.reporting = GooglePlayReportingAPI.Client(serverURL: try GooglePlayReportingAPI.Servers.Server1.url(), transport: transport, middlewares: [authMiddleware])
        self.games = GooglePlayGamesConfigurationAPI.Client(serverURL: try GooglePlayGamesConfigurationAPI.Servers.Server1.url(), transport: transport, middlewares: [authMiddleware])
        self.integrity = GooglePlayIntegrityAPI.Client(serverURL: try GooglePlayIntegrityAPI.Servers.Server1.url(), transport: transport, middlewares: [authMiddleware])
        self.customApps = GooglePlayCustomAppAPI.Client(serverURL: try GooglePlayCustomAppAPI.Servers.Server1.url(), transport: transport, middlewares: [authMiddleware])
        self.gamesManagement = GooglePlayGamesManagementAPI.Client(serverURL: try GooglePlayGamesManagementAPI.Servers.Server1.url(), transport: transport, middlewares: [authMiddleware])
    }

    /// Obtains a valid OAuth 2.0 access token using the underlying GooglePlayAuthMiddleware.
    package func getAccessToken() async throws -> String {
        try await authMiddleware.getAccessToken()
    }

    /// Instantiates `GooglePlayService` using an explicitly provided Google Cloud Service Account key (`googleKey`).
    package static func makeService(googleKey: String? = nil) throws -> GooglePlayService? {
        if let googleKey, !googleKey.isEmpty {
            return try GooglePlayService(key: googleKey)
        }
        return nil
    }

}
