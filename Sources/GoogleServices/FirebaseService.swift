import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import FirebaseManagementAPI
import FirebaseAppDistributionAPI

/// Unified service providing access to Firebase APIs:
/// - `management`: Firebase Management API (listing iOS/Android apps, retrieving bundle IDs, package names, metadata)
/// - `appDistribution`: Firebase App Distribution API (querying releases, versions, and build numbers)
package struct FirebaseService: Sendable {
    package static let sharedTransport = URLSessionTransport()

    /// The OpenAPI client for the Firebase Management API (firebase v1beta1).
    package let management: FirebaseManagementAPI.Client

    /// The OpenAPI client for the Firebase App Distribution API (firebaseappdistribution v1).
    package let appDistribution: FirebaseAppDistributionAPI.Client

    /// Middleware that unescapes `%2F` in request paths.
    /// Google Cloud AIP APIs use multi-segment resource names (e.g. `projects/123/apps/456`),
    /// which OpenAPI 3.0 path parameters percent-encode as `%2F`, causing Google servers to return 404.
    private struct PathUnescapeMiddleware: ClientMiddleware {
        func intercept(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String,
            next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
        ) async throws -> (HTTPResponse, HTTPBody?) {
            var req = request
            if let path = req.path {
                req.path = path.replacingOccurrences(of: "%2F", with: "/").replacingOccurrences(of: "%2f", with: "/")
            }
            return try await next(req, body, baseURL)
        }
    }

    package init(
        authMiddleware: any ClientMiddleware,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        let unescapeMiddleware = PathUnescapeMiddleware()
        let middlewares: [any ClientMiddleware] = [unescapeMiddleware, authMiddleware]

        self.management = FirebaseManagementAPI.Client(
            serverURL: try FirebaseManagementAPI.Servers.Server1.url(),
            transport: transport,
            middlewares: middlewares
        )
        self.appDistribution = FirebaseAppDistributionAPI.Client(
            serverURL: try FirebaseAppDistributionAPI.Servers.Server1.url(),
            transport: transport,
            middlewares: middlewares
        )
    }

    /// Initializes `FirebaseService` using a Google Cloud Service Account key (file path, raw JSON, or Base64 string).
    package init(
        key: String,
        transport: any ClientTransport = Self.sharedTransport,
        urlSession: URLSession = .shared
    ) throws {
        let authMiddleware = try GooglePlayAuthMiddleware(
            key: key,
            scope: "https://www.googleapis.com/auth/cloud-platform",
            urlSession: urlSession
        )
        try self.init(authMiddleware: authMiddleware, transport: transport)
    }

    /// Initializes `FirebaseService` using a static OAuth 2.0 Bearer access token (e.g. from `FIREBASE_TOKEN`).
    package init(
        token: String,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        struct StaticBearerAuthMiddleware: ClientMiddleware, Sendable {
            let token: String
            func intercept(
                _ request: HTTPRequest,
                body: HTTPBody?,
                baseURL: URL,
                operationID: String,
                next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
            ) async throws -> (HTTPResponse, HTTPBody?) {
                var req = request
                req.headerFields[.authorization] = "Bearer \(token)"
                return try await next(req, body, baseURL)
            }
        }

        try self.init(authMiddleware: StaticBearerAuthMiddleware(token: token), transport: transport)
    }

    /// Instantiates `FirebaseService` using explicitly provided credentials (`token` or `googleKey`).
    package static func makeService(token: String? = nil, googleKey: String? = nil) throws -> FirebaseService? {
        if let token, !token.isEmpty {
            return try FirebaseService(token: token)
        }
        if let googleKey, !googleKey.isEmpty {
            return try FirebaseService(key: googleKey)
        }
        return nil
    }
}
