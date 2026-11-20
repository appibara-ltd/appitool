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
import AppStoreConnectAPI
import AppleServices

@Suite("AppStoreService Tests")
struct AppStoreServiceTests {

    // Helper to generate a fresh test key
    private func generateTestKey() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }

    // Mock client transport that captures the request and returns a simulated response
    final class MockTransport: ClientTransport, @unchecked Sendable {
        private static let defaultEmptyAppsJSON = """
        {
            "data": [],
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/apps"
            }
        }
        """.data(using: .utf8)!

        var lastRequest: HTTPRequest?
        var lastOperationID: String?
        var statusCode: HTTPResponse.Status
        var responseBody: Data?

        init(statusCode: HTTPResponse.Status = .ok, responseBody: Data? = defaultEmptyAppsJSON) {
            self.statusCode = statusCode
            self.responseBody = responseBody
        }

        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            self.lastRequest = request
            self.lastOperationID = operationID

            let response = HTTPResponse(status: statusCode)
            let outBody = responseBody.map { HTTPBody($0) }
            return (response, outBody)
        }
    }

    // MARK: - Initialization Tests

    @Test("Initializes with raw private key string and custom transport")
    func initWithRawPrivateKeyString() async throws {
        let key = generateTestKey()
        let mockTransport = MockTransport()

        let service = try AppStoreService(
            keyId: "KEY_123",
            issuerId: "ISSUER_456",
            key: key.pemRepresentation,
            transport: mockTransport
        )

        // Verify service client successfully dispatches through mock transport
        _ = try await service.client.apps_getCollection(.init())
        #expect(mockTransport.lastRequest != nil)
    }

    @Test("Initializes with a .p8 key file path on disk")
    func initWithKeyFilePath() async throws {
        let key = generateTestKey()
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_\(UUID().uuidString).p8")
        try key.pemRepresentation.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let mockTransport = MockTransport()
        let service = try AppStoreService(
            keyId: "KEY_PATH",
            issuerId: "ISSUER_PATH",
            key: tempFile.path,
            transport: mockTransport
        )

        _ = try await service.client.apps_getCollection(.init())
        #expect(mockTransport.lastRequest != nil)
    }

    @Test("Initializes with a Base64 encoded private key string")
    func initWithBase64KeyString() async throws {
        let key = generateTestKey()
        let base64 = Data(key.pemRepresentation.utf8).base64EncodedString()
        let mockTransport = MockTransport()

        let service = try AppStoreService(
            keyId: "KEY_B64",
            issuerId: "ISSUER_B64",
            key: base64,
            transport: mockTransport
        )

        _ = try await service.client.apps_getCollection(.init())
        #expect(mockTransport.lastRequest != nil)
    }

    @Test("Initialization fails and throws when given an invalid private key")
    func initFailsWithInvalidKey() {
        let mockTransport = MockTransport()

        #expect(throws: Error.self) {
            _ = try AppStoreService(
                keyId: "KEY",
                issuerId: "ISSUER",
                key: "CORRUPT_KEY_DATA",
                transport: mockTransport
            )
        }
    }

    // MARK: - End-to-End Client Request Tests

    @Test("Client request through AppStoreService triggers auth middleware and attaches token")
    func clientRequestInjectsAuthToken() async throws {
        let key = generateTestKey()
        let emptyAppsJSON = """
        {
            "data": [],
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/apps"
            }
        }
        """.data(using: .utf8)!

        let mockTransport = MockTransport(statusCode: .ok, responseBody: emptyAppsJSON)
        let service = try AppStoreService(
            keyId: "TEST_KID_API",
            issuerId: "TEST_ISS_API",
            key: key.pemRepresentation,
            transport: mockTransport
        )

        let response = try await service.client.apps_getCollection(.init())

        #expect(mockTransport.lastRequest != nil)
        #expect(mockTransport.lastOperationID == "apps_getCollection")

        let authHeader = mockTransport.lastRequest?.headerFields[.authorization]
        #expect(authHeader != nil)
        #expect(authHeader?.hasPrefix("Bearer ") == true)

        switch response {
        case .ok(let okResponse):
            switch okResponse.body {
            case .json(let appsResponse):
                #expect(appsResponse.data.isEmpty)
            }
        default:
            Issue.record("Expected .ok response with empty apps list, got \(response)")
        }
    }

    @Test("Raw client request wraps AppStoreErrorMiddleware error in ClientError on HTTP 400")
    func clientRequestThrowsOnHttpError() async throws {
        let key = generateTestKey()
        let errorJSON = """
        {
            "errors": [
                {
                    "id": "ERR_1",
                    "status": "400",
                    "code": "ENTITY_ERROR",
                    "title": "Bad Request",
                    "detail": "Invalid parameter provided"
                }
            ]
        }
        """.data(using: .utf8)!

        let mockTransport = MockTransport(statusCode: .badRequest, responseBody: errorJSON)
        let service = try AppStoreService(
            keyId: "TEST_KID_API",
            issuerId: "TEST_ISS_API",
            key: key.pemRepresentation,
            transport: mockTransport
        )

        do {
            _ = try await service.client.apps_getCollection(.init())
            Issue.record("Expected ClientError wrapping AppStoreServiceError on HTTP 400")
        } catch let clientError as ClientError {
            guard case .apiError(let status, let message) = clientError.underlyingError as? AppStoreServiceError else {
                Issue.record("Expected underlying AppStoreServiceError.apiError, got \(clientError.underlyingError)")
                return
            }
            #expect(status == 400)
            #expect(message == "Bad Request (ENTITY_ERROR): Invalid parameter provided")
        } catch {
            Issue.record("Expected ClientError, got \(type(of: error)): \(error)")
        }
    }

    @Test("AppStoreService methods unwrap ClientError and throw typed AppStoreServiceError directly")
    func serviceMethodsThrowTypedAppStoreServiceErrorDirectly() async throws {
        let key = generateTestKey()
        let badRequestJSON = """
        {
            "errors": [
                {
                    "id": "ERR_1",
                    "status": "400",
                    "code": "ENTITY_ERROR",
                    "title": "Bad Request",
                    "detail": "Invalid parameter provided"
                }
            ]
        }
        """.data(using: .utf8)!

        let service400 = try AppStoreService(
            keyId: "TEST_KID_API",
            issuerId: "TEST_ISS_API",
            key: key.pemRepresentation,
            transport: MockTransport(statusCode: .badRequest, responseBody: badRequestJSON)
        )

        do {
            _ = try await service400.fetchApps()
            Issue.record("Expected AppStoreServiceError.apiError on HTTP 400")
        } catch AppStoreServiceError.apiError(let status, let message) {
            #expect(status == 400)
            #expect(message == "Bad Request (ENTITY_ERROR): Invalid parameter provided")
        } catch {
            Issue.record("Expected AppStoreServiceError, got \(type(of: error)): \(error)")
        }

        let serverErrorJSON = """
        {
            "errors": [
                {
                    "id": "ERR_500",
                    "status": "500",
                    "code": "INTERNAL_ERROR",
                    "title": "Internal Server Error",
                    "detail": "Temporary failure"
                }
            ]
        }
        """.data(using: .utf8)!

        let service500 = try AppStoreService(
            keyId: "TEST_KID_API",
            issuerId: "TEST_ISS_API",
            key: key.pemRepresentation,
            transport: MockTransport(statusCode: .internalServerError, responseBody: serverErrorJSON)
        )

        do {
            try await service500.commitBuildUploadFile(id: "file_1")
            Issue.record("Expected AppStoreServiceError.apiError on HTTP 500")
        } catch AppStoreServiceError.apiError(let status, let message) {
            #expect(status == 500)
            #expect(message == "Internal Server Error (INTERNAL_ERROR): Temporary failure")
        } catch {
            Issue.record("Expected AppStoreServiceError, got \(type(of: error)): \(error)")
        }
    }
}
