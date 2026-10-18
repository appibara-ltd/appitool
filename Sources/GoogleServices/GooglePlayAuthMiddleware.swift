import Foundation
import HTTPTypes
import OpenAPIRuntime
import CryptoExtras

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Represents the structure of a Google Cloud Service Account JSON key file.
package struct GoogleServiceAccountKey: Codable, Sendable {
    package let type: String?
    package let projectId: String?
    package let privateKeyId: String?
    package let privateKey: String
    package let clientEmail: String
    package let clientId: String?
    package let authUri: String?
    package let tokenUri: String?
    package let authProviderX509CertUrl: String?
    package let clientX509CertUrl: String?

    enum CodingKeys: String, CodingKey {
        case type
        case projectId = "project_id"
        case privateKeyId = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case clientId = "client_id"
        case authUri = "auth_uri"
        case tokenUri = "token_uri"
        case authProviderX509CertUrl = "auth_provider_x509_cert_url"
        case clientX509CertUrl = "client_x509_cert_url"
    }

    package init(
        type: String? = "service_account",
        projectId: String? = nil,
        privateKeyId: String? = nil,
        privateKey: String,
        clientEmail: String,
        clientId: String? = nil,
        authUri: String? = nil,
        tokenUri: String? = "https://oauth2.googleapis.com/token",
        authProviderX509CertUrl: String? = nil,
        clientX509CertUrl: String? = nil
    ) {
        self.type = type
        self.projectId = projectId
        self.privateKeyId = privateKeyId
        self.privateKey = privateKey
        self.clientEmail = clientEmail
        self.clientId = clientId
        self.authUri = authUri
        self.tokenUri = tokenUri
        self.authProviderX509CertUrl = authProviderX509CertUrl
        self.clientX509CertUrl = clientX509CertUrl
    }
}

/// A `ClientMiddleware` that injects OAuth 2.0 Bearer tokens into Google Play Developer API requests.
///
/// Supports authentication via:
/// 1. Google Service Account JSON file path (e.g. `./service-account.json` or `~/service-account.json`)
/// 2. Raw or Base64-encoded Service Account JSON string
/// 3. Pre-existing static OAuth 2.0 access token (e.g. from CI/CD or `gcloud auth print-access-token`)
package struct GooglePlayAuthMiddleware: ClientMiddleware, Sendable {

    /// The default OAuth scope for Google Play Android Developer API operations.
    package static let defaultScope = "https://www.googleapis.com/auth/androidpublisher"

    /// Alias for defaultScope specifically denoting Android Publisher API operations.
    package static let publisherScope = "https://www.googleapis.com/auth/androidpublisher"

    /// The OAuth scope for Google Play Developer Reporting API operations (vitals, anomalies, error reports).
    package static let reportingScope = "https://www.googleapis.com/auth/playdeveloperreporting"

    /// The OAuth scope for Google Play Games Services configuration and publishing operations.
    package static let gamesConfigurationScope = "https://www.googleapis.com/auth/androidpublisher"

    /// The OAuth scope for Google Play Integrity API operations.
    package static let integrityScope = "https://www.googleapis.com/auth/playintegrity"

    /// The OAuth scope for Google Play Custom App Publishing API operations.
    package static let customAppScope = "https://www.googleapis.com/auth/androidpublisher"

    /// The OAuth scope for Google Play Games Services Management API operations.
    package static let gamesManagementScope = "https://www.googleapis.com/auth/games"

    /// Combined OAuth scopes covering all Google Play developer operations.
    package static let allScopes = "\(publisherScope) \(reportingScope) \(integrityScope) \(gamesManagementScope)"

    /// The default Google OAuth 2.0 token endpoint.
    package static let defaultTokenURI = "https://oauth2.googleapis.com/token"

    private let tokenProvider: @Sendable () async throws -> String

    /// The Google Cloud / Firebase `project_id` parsed from the Service Account JSON, if available.
    package let projectId: String?

    // MARK: - Initializer

    /// Initializes middleware using a Service Account key (file path, raw JSON, or Base64-encoded JSON).
    package init(
        key: String,
        scope: String = defaultScope,
        urlSession: URLSession = .shared
    ) throws {
        let serviceAccount = try Self.parseServiceAccount(from: key)
        self.projectId = serviceAccount.projectId
        let rsaKey = try _RSA.Signing.PrivateKey(pemRepresentation: serviceAccount.privateKey)
        let tokenURI = serviceAccount.tokenUri ?? Self.defaultTokenURI
        let cache = GoogleTokenCache()

        self.tokenProvider = {
            try await cache.validToken {
                try await Self.requestAccessToken(
                    clientEmail: serviceAccount.clientEmail,
                    keyId: serviceAccount.privateKeyId,
                    rsaKey: rsaKey,
                    tokenURI: tokenURI,
                    scope: scope,
                    urlSession: urlSession
                )
            }
        }
    }

    /// Obtains a valid OAuth 2.0 access token for Google Cloud / Firebase APIs.
    package func getAccessToken() async throws -> String {
        try await tokenProvider()
    }

    // MARK: - ClientMiddleware

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        let token = try await tokenProvider()
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }

    // MARK: - Token Acquisition & JWT Creation

    private struct JWTHeader: Encodable {
        let alg: String = "RS256"
        let typ: String = "JWT"
        let kid: String?
    }

    private struct JWTClaims: Encodable {
        let iss: String
        let scope: String
        let aud: String
        let exp: Int
        let iat: Int
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    /// Generates an RS256 JWT assertion and exchanges it for a short-lived Google OAuth 2.0 access token.
    private static func requestAccessToken(
        clientEmail: String,
        keyId: String?,
        rsaKey: _RSA.Signing.PrivateKey,
        tokenURI: String,
        scope: String,
        urlSession: URLSession
    ) async throws -> (token: String, expiration: Date) {
        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 3600 // Google allows maximum 1 hour (3600 seconds)

        let header = JWTHeader(kid: keyId)
        let claims = JWTClaims(iss: clientEmail, scope: scope, aud: tokenURI, exp: exp, iat: iat)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let headerData = try encoder.encode(header)
        let claimsData = try encoder.encode(claims)

        let signingInput = "\(headerData.base64URLEncodedString()).\(claimsData.base64URLEncodedString())"
        let signature = try rsaKey.signature(for: Data(signingInput.utf8), padding: .insecurePKCS1v1_5)
        let assertion = "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"

        guard let requestURL = URL(string: tokenURI) else {
            throw URLError(.badURL)
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion
        ]
        let bodyString = parameters.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        urlRequest.httpBody = Data(bodyString.utf8)

        let (data, response) = try await urlSession.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GooglePlayAuthMiddleware", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to exchange assertion for access token: \(errorText)"])
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let validitySeconds = TimeInterval(tokenResponse.expiresIn ?? 3600)
        let expirationDate = now.addingTimeInterval(validitySeconds)

        return (tokenResponse.accessToken, expirationDate)
    }

    // MARK: - Parsing Helpers

    /// Parses a Google Service Account Key from either a file path, raw JSON, or Base64-encoded JSON.
    package static func parseServiceAccount(from raw: String) throws -> GoogleServiceAccountKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Is it a file path on disk?
        var filePath = trimmed
        if filePath.hasPrefix("~/") || filePath.hasPrefix("~\\") {
            let subpath = String(filePath.dropFirst(2))
            filePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(subpath).path
        }
        if FileManager.default.fileExists(atPath: filePath) {
            let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath))
            return try JSONDecoder().decode(GoogleServiceAccountKey.self, from: fileData)
        }

        // 2. Try direct JSON decoding
        if let directData = trimmed.data(using: .utf8),
           let key = try? JSONDecoder().decode(GoogleServiceAccountKey.self, from: directData) {
            return key
        }

        // 3. Try Base64 decoding
        let remainder = trimmed.count % 4
        let padded = remainder == 0 ? trimmed : trimmed + String(repeating: "=", count: 4 - remainder)
        if let decodedData = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
           let key = try? JSONDecoder().decode(GoogleServiceAccountKey.self, from: decodedData) {
            return key
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Provided string is neither a valid file path, valid JSON, nor valid Base64-encoded Service Account JSON.")
        )
    }
}

// MARK: - Thread-Safe Token Cache

private actor GoogleTokenCache {
    private var cachedToken: String?
    private var tokenExpiration: Date = .distantPast

    func validToken(generate: () async throws -> (token: String, expiration: Date)) async throws -> String {
        let now = Date()
        if let cachedToken, now < tokenExpiration.addingTimeInterval(-60) {
            return cachedToken
        }

        let (newToken, expiration) = try await generate()
        self.cachedToken = newToken
        self.tokenExpiration = expiration
        return newToken
    }
}

// MARK: - Base64URL Helper

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
