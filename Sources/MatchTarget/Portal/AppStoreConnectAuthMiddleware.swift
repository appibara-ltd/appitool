import Foundation
import HTTPTypes
import OpenAPIRuntime

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A `ClientMiddleware` that injects App Store Connect API compliant ES256 JWT tokens into HTTP requests.
public struct AppStoreConnectAuthMiddleware: ClientMiddleware, Sendable {
    public let keyId: String
    public let issuerId: String
    private let privateKey: P256.Signing.PrivateKey
    private let tokenCache: TokenCache

    /// Token validity duration in seconds (Apple allows maximum 20 minutes / 1200 seconds).
    private let tokenLifetime: TimeInterval

    /// Initializes middleware with the private key (file path, raw PEM string, or Base64 encoded).
    public init(
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
    public func validToken() throws -> String {
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

    public static func isBase64Encoded(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let remainder = trimmed.count % 4
        let padded = remainder == 0 ? trimmed : trimmed + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) != nil
    }

    public static func parsePrivateKey(from raw: String) throws -> P256.Signing.PrivateKey {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        trimmed = trimmed.replacingOccurrences(of: "\\n", with: "\n")

        var filePath = trimmed
        if filePath.hasPrefix("~/") || filePath.hasPrefix("~\\") {
            let subpath = String(filePath.dropFirst(2))
            filePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(subpath).path
        }
        if FileManager.default.fileExists(atPath: filePath) {
            let fileContent = try String(contentsOfFile: filePath, encoding: .utf8)
            return try parsePrivateKey(from: fileContent)
        }

        if trimmed.contains("-----BEGIN") {
            if let derData = extractDERFromPEM(trimmed),
               let key = try? P256.Signing.PrivateKey(derRepresentation: derData) {
                return key
            }
            return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
        }

        let unpadded = trimmed.filter { !$0.isWhitespace }
        let remainder = unpadded.count % 4
        let paddedBase64 = remainder == 0 ? unpadded : unpadded + String(repeating: "=", count: 4 - remainder)

        if let decodedData = Data(base64Encoded: paddedBase64, options: [.ignoreUnknownCharacters]) {
            if let decodedString = String(data: decodedData, encoding: .utf8),
               decodedString.contains("-----BEGIN") {
                return try parsePrivateKey(from: decodedString)
            }

            if let keyFromDER = try? P256.Signing.PrivateKey(derRepresentation: decodedData) {
                return keyFromDER
            }
        }

        return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
    }

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
