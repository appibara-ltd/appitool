import Testing
import Foundation
import HTTPTypes
import OpenAPIRuntime
import CryptoExtras
@testable import appitool

// MARK: - Mock URL Protocol for Google OAuth Endpoint

private final class MockGoogleURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(url: String, handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.withLock { handlers[url] = handler }
    }

    static func unregister(url: String) {
        lock.withLock { _ = handlers.removeValue(forKey: url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestURL = request.url?.absoluteString ?? ""
        let handler = Self.lock.withLock { Self.handlers[requestURL] }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockGoogleURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests Suite

@Suite("GooglePlayAuthMiddleware Tests", .serialized)
struct GooglePlayAuthMiddlewareTests {

    private static let testRSAKeyPEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAxwIi0clkvVY5ADLcTDoO+PTOnBKzggUueuBIUroZdgBDu0Ar
    Q5eiOpC/e1Mcm7nMXhFbr/75l+h87wjoRAqEk6Bt3ZVoP5y3svI3F2p+rTmLMfet
    1R2l7sStipnZl2I+4wCJtILEKOaxO3+fu0EdOJMH/DobcRdZrdIlh2URkjMYA0j7
    VBUBcqHxDTzQQwiWhdTWptyFxGoksRYWNGim+hH2pOGC5z45IGab5xggvD9//V6a
    DEM/4KTwdRMrtdlh/AqAM3KNqAmVRHo8esICJVvadb6PcfQ5CFyz8OE7EY9f8DEH
    BUMyWusbVc7UOfAPFnQNyVeXUzuxV4GL7w5MkQIDAQABAoIBAQCI29EyULv08az1
    lASob20IjOLhtoK4sfOLEV7rdYw4+GmcBr86Fre8avskRr3v4lDHiExztnfTnlD8
    2jVRRaJzG+sybaNpy88RQz3b3qMLYf11+Y0UePU6RQvLu45Ga4wv9Ji/CQb50dyk
    vFoPHvKHi6X8McHZfmNwBItGl50D2uNKcg9mJp4bRHNAhwan4GLCrDC0zhf34+JW
    tddl9Z1sNCBiHORB3dnBVj4Y5LGA7oqgwHkGp1Y+LXs4QQo/t2fa9kOlXkxIXs15
    +x7QMr6+g6OMf7/ov0XhYmHFa7A2GgD+tjnbhjqD18/qSONxryE/3YsoYxn3E+pA
    pJaIh8YhAoGBAPql+yv0D4YWTogpH/gRZd2GfKcSZG2tFbdYmb3yLShovNk/nA2h
    8sRxNpuQJL5qyRCa7tIk7wNCit53aQyb4Zrp6bfawAYhENdqpUx/nZbX79pzkEMj
    SzoPhOWh/TQHybidxWlwvmmeV9KBWsmjkSvoqGJfmtPBTEU6W79PkxoFAoGBAMtB
    5UxHO8sHnD9utzulgLfd5RmjT+6GS9CbXJTPKP4HdRn/YBKdfnb+uyG7Xpwe3U2p
    DmFt1431bbTxFmFlDH1RpEijY/Ex9TK4H3pZ2p5Y+/pIQQRoBUJbQQz7pZ3+Eehj
    ee/59sVuMFEN1wjs8VkUbIjD3fHfciiBtsJKUBIdAoGAcMI487YRQcZJQBIYMrZI
    +FanP1YT3g9OxLPUPlJzpEkyJB3sq2le2KcB5Qv8q7lIiPLaW6mH6RSHeruHg8eg
    v9tZbH+5gUhg1jhA8uA6WgD9A26XyMxY7F7M761nRn/2bNp1VBEHaGZ2pdnRqQKv
    rWw2TEMsWPUNxdsSKUe4Kq0CgYBWp00+a9AOCryOPoFXqINr3+ngOEPHiPGhidq6
    hmcPhdZiswEebo6P5KGbC+qV3IK0rTI4Tz/qgYu37GCCPTZJ5xiG70GYfpfue5jP
    7KbLg1xJo6w0WLSFSao+Arrk1ICF9oLx0DtoiEWJCMF4SKvMMmzjEb35dC2TH1nv
    Ewd38QKBgA/hvHE3lwUcslPft3v/jBNaxOtOl3JK+OIDRk1J7ILEi4pDVMvbEJ50
    Hb9Zvy1e97OvjbpOUuAQkLR+y1WE+05NQm02FRpGH+F4x4JlfN1heULlnne3f6Uj
    ja3yzIwBAvLxcp6jMdSW+7bjxB3bwAU2e1Yqtzpqt3WTG5HxzOuK
    -----END RSA PRIVATE KEY-----
    """

    private func serviceAccountJSON(tokenURI: String = "https://oauth2.googleapis.com/token") -> String {
        let escapedKey = Self.testRSAKeyPEM.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {
          "type": "service_account",
          "project_id": "test-project-123",
          "private_key_id": "key_id_abc",
          "private_key": "\(escapedKey)",
          "client_email": "test-sa@test-project-123.iam.gserviceaccount.com",
          "client_id": "1122334455",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "\(tokenURI)",
          "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
          "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/test"
        }
        """
    }

    private var sampleServiceAccountJSON: String {
        serviceAccountJSON()
    }

    // MARK: - Basic Decoding and Parsing Tests

    @Test("Decodes GoogleServiceAccountKey from standard JSON")
    func decodeServiceAccountKey() throws {
        let data = sampleServiceAccountJSON.data(using: .utf8)!
        let key = try JSONDecoder().decode(GoogleServiceAccountKey.self, from: data)

        #expect(key.type == "service_account")
        #expect(key.projectId == "test-project-123")
        #expect(key.privateKeyId == "key_id_abc")
        #expect(key.clientEmail == "test-sa@test-project-123.iam.gserviceaccount.com")
        #expect(key.clientId == "1122334455")
        #expect(key.authUri == "https://accounts.google.com/o/oauth2/auth")
        #expect(key.tokenUri == "https://oauth2.googleapis.com/token")
        #expect(key.authProviderX509CertUrl == "https://www.googleapis.com/oauth2/v1/certs")
        #expect(key.clientX509CertUrl == "https://www.googleapis.com/robot/v1/metadata/x509/test")
    }

    @Test("GoogleServiceAccountKey memberwise initializer sets all properties")
    func serviceAccountKeyMemberwiseInit() {
        let key = GoogleServiceAccountKey(
            type: "service_account",
            projectId: "proj-1",
            privateKeyId: "pk-1",
            privateKey: "pk-data",
            clientEmail: "sa@proj.iam.gserviceaccount.com",
            clientId: "c-1",
            authUri: "https://auth",
            tokenUri: "https://token",
            authProviderX509CertUrl: "https://cert1",
            clientX509CertUrl: "https://cert2"
        )

        #expect(key.type == "service_account")
        #expect(key.projectId == "proj-1")
        #expect(key.privateKeyId == "pk-1")
        #expect(key.privateKey == "pk-data")
        #expect(key.clientEmail == "sa@proj.iam.gserviceaccount.com")
        #expect(key.clientId == "c-1")
        #expect(key.authUri == "https://auth")
        #expect(key.tokenUri == "https://token")
        #expect(key.authProviderX509CertUrl == "https://cert1")
        #expect(key.clientX509CertUrl == "https://cert2")
    }

    @Test("Parses service account from raw JSON and Base64-encoded JSON")
    func parseServiceAccountRawAndBase64() throws {
        // Raw JSON
        let fromRaw = try GooglePlayAuthMiddleware.parseServiceAccount(from: sampleServiceAccountJSON)
        #expect(fromRaw.clientEmail == "test-sa@test-project-123.iam.gserviceaccount.com")

        // Base64 encoded JSON
        let base64 = Data(sampleServiceAccountJSON.utf8).base64EncodedString()
        let fromBase64 = try GooglePlayAuthMiddleware.parseServiceAccount(from: base64)
        #expect(fromBase64.clientEmail == "test-sa@test-project-123.iam.gserviceaccount.com")

        // Unpadded Base64
        let unpadded = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fromUnpadded = try GooglePlayAuthMiddleware.parseServiceAccount(from: unpadded)
        #expect(fromUnpadded.clientEmail == "test-sa@test-project-123.iam.gserviceaccount.com")

        // Invalid string throws
        #expect(throws: Error.self) {
            _ = try GooglePlayAuthMiddleware.parseServiceAccount(from: "INVALID_JSON_CONTENT")
        }
    }

    @Test("Parses service account from file path on disk")
    func parseServiceAccountFromFilePath() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("sa_\(UUID().uuidString).json")
        try sampleServiceAccountJSON.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let parsed = try GooglePlayAuthMiddleware.parseServiceAccount(from: tempFile.path)
        #expect(parsed.clientEmail == "test-sa@test-project-123.iam.gserviceaccount.com")
    }

    @Test("Parses service account from tilde path in home directory")
    func parseServiceAccountFromTildePath() throws {
        let fileName = ".test_appitool_sa_\(UUID().uuidString).json"
        let homeFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fileName)
        try sampleServiceAccountJSON.write(to: homeFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: homeFile) }

        let tildePath = "~/" + fileName
        let parsed = try GooglePlayAuthMiddleware.parseServiceAccount(from: tildePath)
        #expect(parsed.clientEmail == "test-sa@test-project-123.iam.gserviceaccount.com")
    }

    @Test("Fails initialization when private key is not a valid RSA PEM")
    func initFailsWithInvalidRSAPrivateKey() {
        let invalidKeySA = sampleServiceAccountJSON.replacingOccurrences(
            of: Self.testRSAKeyPEM.replacingOccurrences(of: "\n", with: "\\n"),
            with: "-----BEGIN RSA PRIVATE KEY-----\\nINVALID_DATA\\n-----END RSA PRIVATE KEY-----"
        )
        #expect(throws: Error.self) {
            _ = try GooglePlayAuthMiddleware(key: invalidKeySA)
        }
    }

    @Test("Verifies all Google OAuth scope constants")
    func verifyOAuthScopeConstants() {
        #expect(!GooglePlayAuthMiddleware.defaultScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.publisherScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.reportingScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.gamesConfigurationScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.integrityScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.customAppScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.gamesManagementScope.isEmpty)
        #expect(!GooglePlayAuthMiddleware.allScopes.isEmpty)
        #expect(GooglePlayAuthMiddleware.defaultTokenURI == "https://oauth2.googleapis.com/token")
    }

    // MARK: - Intercept, Token Generation & Cache Tests

    @Test("Intercepts request and adds Bearer Authorization header")
    func interceptAddsBearerToken() async throws {
        let session = makeMockSession()
        let tokenURI = "https://oauth2.googleapis.com/token?test=\(UUID().uuidString)"

        MockGoogleURLProtocol.register(url: tokenURI) { request in
            #expect(request.httpMethod == "POST")
            let tokenJson = """
            {
              "access_token": "mock-access-token-12345",
              "expires_in": 3600,
              "token_type": "Bearer"
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(tokenJson.utf8))
        }
        defer { MockGoogleURLProtocol.unregister(url: tokenURI) }

        let middleware = try GooglePlayAuthMiddleware(
            key: serviceAccountJSON(tokenURI: tokenURI),
            urlSession: session
        )

        let testRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "androidpublisher.googleapis.com",
            path: "/androidpublisher/v3/applications/test"
        )
        let testBaseURL = URL(string: "https://androidpublisher.googleapis.com")!

        let (resp, _) = try await middleware.intercept(
            testRequest,
            body: nil,
            baseURL: testBaseURL,
            operationID: "testOperation"
        ) { forwardedReq, _, _ in
            #expect(forwardedReq.headerFields[.authorization] == "Bearer mock-access-token-12345")
            return (HTTPResponse(status: .ok), nil)
        }

        #expect(resp.status == .ok)
    }

    @Test("Reuses cached token on subsequent requests without calling network")
    func reusesCachedToken() async throws {
        let session = makeMockSession()
        let tokenURI = "https://oauth2.googleapis.com/token?test=\(UUID().uuidString)"

        final class Counter: @unchecked Sendable {
            nonisolated(unsafe) var count = 0
            private let lock = NSLock()
            func increment() { lock.withLock { count += 1 } }
            func get() -> Int { lock.withLock { count } }
        }
        let counter = Counter()

        MockGoogleURLProtocol.register(url: tokenURI) { request in
            counter.increment()
            let tokenJson = """
            {
              "access_token": "cached-token-abc",
              "expires_in": 3600,
              "token_type": "Bearer"
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(tokenJson.utf8))
        }
        defer { MockGoogleURLProtocol.unregister(url: tokenURI) }

        let middleware = try GooglePlayAuthMiddleware(
            key: serviceAccountJSON(tokenURI: tokenURI),
            urlSession: session
        )

        let testRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "androidpublisher.googleapis.com",
            path: "/test"
        )
        let testBaseURL = URL(string: "https://androidpublisher.googleapis.com")!

        // First call -> fetches from network
        _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op1") { req, _, _ in
            #expect(req.headerFields[.authorization] == "Bearer cached-token-abc")
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(counter.get() == 1)

        // Second call -> returns cached token, no new network request
        _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op2") { req, _, _ in
            #expect(req.headerFields[.authorization] == "Bearer cached-token-abc")
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(counter.get() == 1)
    }

    @Test("Refreshes token when cached token has expired")
    func refreshesExpiredToken() async throws {
        let session = makeMockSession()
        let tokenURI = "https://oauth2.googleapis.com/token?test=\(UUID().uuidString)"

        final class Counter: @unchecked Sendable {
            nonisolated(unsafe) var count = 0
            private let lock = NSLock()
            func increment() { lock.withLock { count += 1 } }
            func get() -> Int { lock.withLock { count } }
        }
        let counter = Counter()

        MockGoogleURLProtocol.register(url: tokenURI) { request in
            counter.increment()
            // Set expires_in to 10 seconds (well within the 60-second expiration buffer, so immediately considered expired)
            let tokenJson = """
            {
              "access_token": "token-num-\(counter.get())",
              "expires_in": 10,
              "token_type": "Bearer"
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(tokenJson.utf8))
        }
        defer { MockGoogleURLProtocol.unregister(url: tokenURI) }

        let middleware = try GooglePlayAuthMiddleware(
            key: serviceAccountJSON(tokenURI: tokenURI),
            urlSession: session
        )

        let testRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "androidpublisher.googleapis.com",
            path: "/test"
        )
        let testBaseURL = URL(string: "https://androidpublisher.googleapis.com")!

        // First call -> counter becomes 1
        _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op1") { req, _, _ in
            #expect(req.headerFields[.authorization] == "Bearer token-num-1")
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(counter.get() == 1)

        // Second call -> because expires_in is 10s (< 60s buffer), cache is invalidated and network is called again
        _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op2") { req, _, _ in
            #expect(req.headerFields[.authorization] == "Bearer token-num-2")
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(counter.get() == 2)
    }

    @Test("Throws error when token endpoint returns HTTP error response")
    func tokenEndpointReturnsHttpError() async throws {
        let session = makeMockSession()
        let tokenURI = "https://oauth2.googleapis.com/token?test=\(UUID().uuidString)"

        MockGoogleURLProtocol.register(url: tokenURI) { request in
            let errorJson = """
            {
              "error": "invalid_grant",
              "error_description": "Invalid JWT Signature."
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(errorJson.utf8))
        }
        defer { MockGoogleURLProtocol.unregister(url: tokenURI) }

        let middleware = try GooglePlayAuthMiddleware(
            key: serviceAccountJSON(tokenURI: tokenURI),
            urlSession: session
        )

        let testRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "androidpublisher.googleapis.com",
            path: "/test"
        )
        let testBaseURL = URL(string: "https://androidpublisher.googleapis.com")!

        await #expect(throws: Error.self) {
            _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op") { _, _, _ in
                (HTTPResponse(status: .ok), nil)
            }
        }
    }

    @Test("Throws error when token response is not valid JSON")
    func tokenEndpointReturnsMalformedResponse() async throws {
        let session = makeMockSession()
        let tokenURI = "https://oauth2.googleapis.com/token?test=\(UUID().uuidString)"

        MockGoogleURLProtocol.register(url: tokenURI) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("NON_JSON_RESPONSE".utf8))
        }
        defer { MockGoogleURLProtocol.unregister(url: tokenURI) }

        let middleware = try GooglePlayAuthMiddleware(
            key: serviceAccountJSON(tokenURI: tokenURI),
            urlSession: session
        )

        let testRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "androidpublisher.googleapis.com",
            path: "/test"
        )
        let testBaseURL = URL(string: "https://androidpublisher.googleapis.com")!

        await #expect(throws: Error.self) {
            _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op") { _, _, _ in
                (HTTPResponse(status: .ok), nil)
            }
        }
    }

    @Test("Throws error when network request fails")
    func networkRequestFails() async throws {
        let session = makeMockSession()
        let tokenURI = "https://oauth2.googleapis.com/token?test=\(UUID().uuidString)"

        MockGoogleURLProtocol.register(url: tokenURI) { _ in
            throw URLError(.timedOut)
        }
        defer { MockGoogleURLProtocol.unregister(url: tokenURI) }

        let middleware = try GooglePlayAuthMiddleware(
            key: serviceAccountJSON(tokenURI: tokenURI),
            urlSession: session
        )

        let testRequest = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: "androidpublisher.googleapis.com",
            path: "/test"
        )
        let testBaseURL = URL(string: "https://androidpublisher.googleapis.com")!

        await #expect(throws: Error.self) {
            _ = try await middleware.intercept(testRequest, body: nil, baseURL: testBaseURL, operationID: "op") { _, _, _ in
                (HTTPResponse(status: .ok), nil)
            }
        }
    }
}
