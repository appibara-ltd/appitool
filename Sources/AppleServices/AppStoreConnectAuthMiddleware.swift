import Foundation
import HTTPTypes
import OpenAPIRuntime

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A `ClientMiddleware` that injects App Store Connect API compliant ES256 JWT tokens into HTTP requests.
package struct AppStoreConnectAuthMiddleware: ClientMiddleware, Sendable {
    package let keyId: String
    package let issuerId: String
    private let privateKey: P256.Signing.PrivateKey
    private let tokenCache: TokenCache

    /// Token validity duration in seconds (Apple allows maximum 20 minutes / 1200 seconds).
    private let tokenLifetime: TimeInterval

    /// Initializes middleware with the private key (file path, raw PEM string, or Base64 encoded).
    package init(
        keyId: String,
        issuerId: String,
        key: String,
        tokenLifetime: TimeInterval = 19 * 60
    ) throws {
        self.keyId = keyId
        self.issuerId = issuerId
        self.privateKey = try Self.parsePrivateKey(from: key)
        self.tokenLifetime = tokenLifetime
        self.tokenCache = TokenCache()
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
        let token = try validToken()
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }

    // MARK: - Token Management

    /// Returns a valid cached JWT token or creates a new one if expired.
    package func validToken() throws -> String {
        try tokenCache.validToken {
            try generateJWT(now: Date())
        }
    }

    // MARK: - JWT Generation

    private struct JWTHeader: Encodable {
        let alg: String = "ES256"
        let kid: String
        let typ: String = "JWT"
    }

    private struct JWTPayload: Encodable {
        let iss: String
        let iat: Int
        let exp: Int
        let aud: String = "appstoreconnect-v1"
    }

    private func generateJWT(now: Date) throws -> (token: String, expiration: Date) {
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + Int(tokenLifetime)
        let expirationDate = Date(timeIntervalSince1970: TimeInterval(exp))

        let header = JWTHeader(kid: keyId)
        let payload = JWTPayload(iss: issuerId, iat: iat, exp: exp)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let headerData = try encoder.encode(header)
        let payloadData = try encoder.encode(payload)

        let headerBase64 = headerData.base64URLEncodedString()
        let payloadBase64 = payloadData.base64URLEncodedString()
        let signingInput = "\(headerBase64).\(payloadBase64)"

        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        let signatureBase64 = signature.rawRepresentation.base64URLEncodedString()

        let token = "\(signingInput).\(signatureBase64)"
        return (token, expirationDate)
    }

    // MARK: - Key Parsing & Format Detection

    /// Checks whether a given string is Base64 encoded (with or without padding).
    package static func isBase64Encoded(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let remainder = trimmed.count % 4
        let padded = remainder == 0 ? trimmed : trimmed + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) != nil
    }

    /// Automatically detects and parses the private key from:
    /// - A file path (e.g. `./AuthKey_XXX.p8` or `~/AuthKey_XXX.p8`)
    /// - Base64-encoded `.p8` file content (commonly used in .env / CI/CD)
    /// - Direct PEM formatted string (`-----BEGIN PRIVATE KEY-----`)
    /// - Raw DER binary encoded in Base64 (with or without padding)
    package static func parsePrivateKey(from raw: String) throws -> P256.Signing.PrivateKey {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip surrounding quotes if any (e.g. "..." or '...')
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Replace literal escaped newlines "\n" with real newlines
        trimmed = trimmed.replacingOccurrences(of: "\\n", with: "\n")

        // 1. Is it a file path on disk?
        var filePath = trimmed
        if filePath.hasPrefix("~/") || filePath.hasPrefix("~\\") {
            let subpath = String(filePath.dropFirst(2))
            filePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(subpath).path
        }
        if FileManager.default.fileExists(atPath: filePath) {
            let fileContent = try String(contentsOfFile: filePath, encoding: .utf8)
            return try parsePrivateKey(from: fileContent)
        }

        // 2. Is it a direct PEM string (contains PEM markers)?
        if trimmed.contains("-----BEGIN") {
            // Extract the base64 DER content between BEGIN and END markers
            if let derData = extractDERFromPEM(trimmed),
               let key = try? P256.Signing.PrivateKey(derRepresentation: derData) {
                return key
            }
            // Fallback to CryptoKit's standard PEM parser
            return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
        }

        // 3. Could it be Base64 encoded? (either Base64 of PEM string, or Base64 of raw DER bytes)
        let unpadded = trimmed.filter { !$0.isWhitespace }
        let remainder = unpadded.count % 4
        let paddedBase64 = remainder == 0 ? unpadded : unpadded + String(repeating: "=", count: 4 - remainder)

        if let decodedData = Data(base64Encoded: paddedBase64, options: [.ignoreUnknownCharacters]) {
            // 3a. Base64 of the entire .p8 file (decodes to PEM text)
            if let decodedString = String(data: decodedData, encoding: .utf8),
               decodedString.contains("-----BEGIN") {
                return try parsePrivateKey(from: decodedString)
            }

            // 3b. Base64 of raw PKCS#8 or SEC1 DER bytes
            if let keyFromDER = try? P256.Signing.PrivateKey(derRepresentation: decodedData) {
                return keyFromDER
            }
        }

        // 4. Fallback: attempt standard CryptoKit PEM parsing
        return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
    }

    /// Helper to extract raw DER data from a PEM-formatted string.
    private static func extractDERFromPEM(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        let base64Lines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !t.hasPrefix("-----")
        }
        let base64String = base64Lines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = base64String.count % 4
        let padded = remainder == 0 ? base64String : base64String + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
    }
}

// MARK: - Thread-Safe Token Cache

private final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedToken: String?
    private var tokenExpiration: Date = .distantPast

    func validToken(generate: () throws -> (token: String, expiration: Date)) throws -> String {
        try lock.withLock {
            let now = Date()
            // Refresh token if within 60 seconds of expiration
            if let cachedToken, now < tokenExpiration.addingTimeInterval(-60) {
                return cachedToken
            }

            let (newToken, expiration) = try generate()
            self.cachedToken = newToken
            self.tokenExpiration = expiration
            return newToken
        }
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
