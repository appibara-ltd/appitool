import Testing
import Foundation
import HTTPTypes
import OpenAPIRuntime
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import appitool
import AppleServices

@Suite("AppStoreConnectAuthMiddleware Tests")
struct AppStoreConnectAuthMiddlewareTests {

    // Helper to generate a fresh test key
    private func generateTestKey() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }

    // MARK: - Key Parsing Tests

    @Test("Base64 string format validation with and without padding")
    func base64FormatValidation() {
        // Valid Base64 with padding
        #expect(AppStoreConnectAuthMiddleware.isBase64Encoded("SGVsbG8gV29ybGQ="))
        #expect(AppStoreConnectAuthMiddleware.isBase64Encoded("YWI=="))

        // Valid Base64 without padding (should still validate successfully)
        #expect(AppStoreConnectAuthMiddleware.isBase64Encoded("SGVsbG8gV29ybGQ"))
        #expect(AppStoreConnectAuthMiddleware.isBase64Encoded("YWI"))

        // Invalid / empty
        #expect(!AppStoreConnectAuthMiddleware.isBase64Encoded(""))
        #expect(!AppStoreConnectAuthMiddleware.isBase64Encoded("   "))
    }

    @Test("Parses private key directly from standard PEM string")
    func parseFromStandardPEM() throws {
        let key = generateTestKey()
        let pem = key.pemRepresentation

        let parsed = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: pem)
        #expect(parsed.rawRepresentation == key.rawRepresentation)
    }

    @Test("Parses private key from PEM string with escaped newlines and surrounding quotes")
    func parseFromQuotedPEMWithEscapes() throws {
        let key = generateTestKey()
        let rawPEM = key.pemRepresentation
        let escapedQuoted = "\"\(rawPEM.replacingOccurrences(of: "\n", with: "\\n"))\""

        let parsed = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: escapedQuoted)
        #expect(parsed.rawRepresentation == key.rawRepresentation)
    }

    @Test("Parses private key from Base64 encoded PEM string")
    func parseFromBase64EncodedPEM() throws {
        let key = generateTestKey()
        let pemData = Data(key.pemRepresentation.utf8)
        let base64PEM = pemData.base64EncodedString()

        let parsed = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: base64PEM)
        #expect(parsed.rawRepresentation == key.rawRepresentation)

        // Test with unpadded Base64
        let unpaddedBase64 = base64PEM.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let parsedUnpadded = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: unpaddedBase64)
        #expect(parsedUnpadded.rawRepresentation == key.rawRepresentation)
    }

    @Test("Parses private key from Base64 encoded raw DER bytes")
    func parseFromBase64DERBytes() throws {
        let key = generateTestKey()
        let base64DER = key.derRepresentation.base64EncodedString()

        let parsed = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: base64DER)
        #expect(parsed.rawRepresentation == key.rawRepresentation)
    }

    @Test("Parses private key from a .p8 file on disk")
    func parseFromDiskFile() throws {
        let key = generateTestKey()
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("AuthKey_\(UUID().uuidString).p8")

        try key.pemRepresentation.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Test parsePrivateKey from file path
        let parsed = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: tempFile.path)
        #expect(parsed.rawRepresentation == key.rawRepresentation)

        // Test middleware init with file path
        let middleware = try AppStoreConnectAuthMiddleware(
            keyId: "TEST_KID",
            issuerId: "TEST_ISS",
            key: tempFile.path
        )
        #expect(middleware.keyId == "TEST_KID")
        #expect(middleware.issuerId == "TEST_ISS")
    }

    @Test("Parses private key from tilde (~) and backslash tilde (~\\) file paths")
    func parseFromTildePath() throws {
        let key = generateTestKey()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let fileName = "AuthKey_tilde_\(UUID().uuidString).p8"
        let realFile = homeDir.appendingPathComponent(fileName)

        try key.pemRepresentation.write(to: realFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: realFile) }

        // Test parsePrivateKey with ~/
        let parsedUnix = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: "~/\(fileName)")
        #expect(parsedUnix.rawRepresentation == key.rawRepresentation)

        // Test parsePrivateKey with ~\
        let parsedWin = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: "~\\\(fileName)")
        #expect(parsedWin.rawRepresentation == key.rawRepresentation)

        // Test middleware init with ~/ and ~\
        let mwUnix = try AppStoreConnectAuthMiddleware(keyId: "K", issuerId: "I", key: "~/\(fileName)")
        #expect(mwUnix.keyId == "K")

        let mwWin = try AppStoreConnectAuthMiddleware(keyId: "K", issuerId: "I", key: "~\\\(fileName)")
        #expect(mwWin.keyId == "K")
    }

    @Test("Parses private key with surrounding single quotes")
    func parseFromSingleQuotedPEM() throws {
        let key = generateTestKey()
        let singleQuoted = "'\(key.pemRepresentation)'"

        let parsed = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: singleQuoted)
        #expect(parsed.rawRepresentation == key.rawRepresentation)
    }

    @Test("Throws error when parsing invalid private key data")
    func parseInvalidKeyThrows() {
        #expect(throws: Error.self) {
            _ = try AppStoreConnectAuthMiddleware.parsePrivateKey(from: "INVALID_KEY_DATA_HERE")
        }
    }


    // MARK: - JWT Generation & Token Management Tests

    @Test("Generates valid ES256 JWT token with correct header and claims")
    func jwtTokenGenerationAndStructure() throws {
        let key = generateTestKey()
        let middleware = try AppStoreConnectAuthMiddleware(
            keyId: "MOCK_KEY_ID_123",
            issuerId: "MOCK_ISSUER_456",
            key: key.pemRepresentation
        )

        let token = try middleware.validToken()
        let segments = token.components(separatedBy: ".")
        #expect(segments.count == 3, "JWT must consist of header.payload.signature")

        // Decode Header
        let headerBase64 = base64URLToBase64(segments[0])
        guard let headerData = Data(base64Encoded: headerBase64),
              let headerJson = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            Issue.record("Failed to decode JWT header")
            return
        }
        #expect(headerJson["alg"] as? String == "ES256")
        #expect(headerJson["kid"] as? String == "MOCK_KEY_ID_123")
        #expect(headerJson["typ"] as? String == "JWT")

        // Decode Payload
        let payloadBase64 = base64URLToBase64(segments[1])
        guard let payloadData = Data(base64Encoded: payloadBase64),
              let payloadJson = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            Issue.record("Failed to decode JWT payload")
            return
        }
        #expect(payloadJson["iss"] as? String == "MOCK_ISSUER_456")
        #expect(payloadJson["aud"] as? String == "appstoreconnect-v1")
        #expect(payloadJson["iat"] is Int)
        #expect(payloadJson["exp"] is Int)

        let iat = payloadJson["iat"] as! Int
        let exp = payloadJson["exp"] as! Int
        #expect(exp > iat)
    }

    @Test("Caches generated token for subsequent calls within validity period")
    func tokenCaching() throws {
        let key = generateTestKey()
        let middleware = try AppStoreConnectAuthMiddleware(
            keyId: "KEY_ID",
            issuerId: "ISSUER_ID",
            key: key.pemRepresentation,
            tokenLifetime: 600
        )

        let token1 = try middleware.validToken()
        let token2 = try middleware.validToken()

        #expect(token1 == token2, "TokenCache should return the identical cached token")
    }

    @Test("Refreshes and regenerates token when cached token has expired")
    func tokenRenewalWhenExpired() throws {
        let key = generateTestKey()
        // Negative token lifetime ensures it is immediately considered expired
        let middleware = try AppStoreConnectAuthMiddleware(
            keyId: "KEY_EXP",
            issuerId: "ISSUER_EXP",
            key: key.pemRepresentation,
            tokenLifetime: -100
        )

        let token1 = try middleware.validToken()
        let token2 = try middleware.validToken()

        #expect(!token1.isEmpty)
        #expect(!token2.isEmpty)
    }


    // MARK: - ClientMiddleware Intercept Tests

    @Test("Intercept injects Bearer authorization header into outgoing HTTP request")
    func interceptInjectsAuthorizationHeader() async throws {
        let key = generateTestKey()
        let middleware = try AppStoreConnectAuthMiddleware(
            keyId: "KEY_ID_INTERCEPT",
            issuerId: "ISSUER_ID_INTERCEPT",
            key: key.pemRepresentation
        )

        let initialRequest = HTTPRequest(method: .get, scheme: "https", authority: "api.appstoreconnect.apple.com", path: "/v1/apps")
        let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!

        final class CapturedBox: @unchecked Sendable {
            var request: HTTPRequest?
        }
        let box = CapturedBox()
        let mockResponse = HTTPResponse(status: .ok)

        let (response, _) = try await middleware.intercept(
            initialRequest,
            body: nil,
            baseURL: baseURL,
            operationID: "apps_getCollection"
        ) { req, body, url in
            box.request = req
            return (mockResponse, nil)
        }

        #expect(response.status == .ok)
        let interceptedRequest = box.request
        #expect(interceptedRequest != nil)

        let authHeader = interceptedRequest?.headerFields[.authorization]
        #expect(authHeader != nil)
        #expect(authHeader?.hasPrefix("Bearer ") == true)

        let token = String(authHeader!.dropFirst(7))
        #expect(token.components(separatedBy: ".").count == 3)
    }


    // MARK: - Private Test Helper

    private func base64URLToBase64(_ base64URL: String) -> String {
        var base64 = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return base64
    }
}
