import Testing
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import appitool
import GooglePlayStoreAPI
import GooglePlayReportingAPI
import GooglePlayGamesConfigurationAPI
import GooglePlayIntegrityAPI
import GooglePlayCustomAppAPI
import GooglePlayGamesManagementAPI

@Suite("GooglePlayService Tests")
struct GooglePlayServiceTests {

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

    private var sampleServiceAccountJSON: String {
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
          "token_uri": "https://oauth2.googleapis.com/token",
          "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
          "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/test"
        }
        """
    }

    final class MockTransport: ClientTransport, @unchecked Sendable {
        var lastRequest: HTTPRequest?
        var lastOperationID: String?
        var statusCode: HTTPResponse.Status
        var responseBody: Data?

        init(statusCode: HTTPResponse.Status = .ok, responseBody: Data? = "{}".data(using: .utf8)) {
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

    @Test("Initializes GooglePlayService with raw Service Account JSON for all 6 Google Play APIs")
    func initWithRawJSON() throws {
        let mockTransport = MockTransport()
        let service = try GooglePlayService(
            key: sampleServiceAccountJSON,
            transport: mockTransport
        )

        #expect(service.client is GooglePlayStoreAPI.Client)
        #expect(service.reporting is GooglePlayReportingAPI.Client)
        #expect(service.games is GooglePlayGamesConfigurationAPI.Client)
        #expect(service.integrity is GooglePlayIntegrityAPI.Client)
        #expect(service.customApps is GooglePlayCustomAppAPI.Client)
        #expect(service.gamesManagement is GooglePlayGamesManagementAPI.Client)
    }

    @Test("Initializes GooglePlayService with a Service Account JSON file path")
    func initWithFilePath() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("sa_\(UUID().uuidString).json")
        try sampleServiceAccountJSON.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let mockTransport = MockTransport()
        let service = try GooglePlayService(
            key: tempFile.path,
            transport: mockTransport
        )

        #expect(service.client is GooglePlayStoreAPI.Client)
        #expect(service.reporting is GooglePlayReportingAPI.Client)
        #expect(service.games is GooglePlayGamesConfigurationAPI.Client)
        #expect(service.integrity is GooglePlayIntegrityAPI.Client)
        #expect(service.customApps is GooglePlayCustomAppAPI.Client)
        #expect(service.gamesManagement is GooglePlayGamesManagementAPI.Client)
    }

    @Test("Initializes GooglePlayService with Base64-encoded Service Account JSON")
    func initWithBase64JSON() throws {
        let base64 = Data(sampleServiceAccountJSON.utf8).base64EncodedString()
        let mockTransport = MockTransport()
        let service = try GooglePlayService(
            key: base64,
            transport: mockTransport
        )

        #expect(service.client is GooglePlayStoreAPI.Client)
        #expect(service.reporting is GooglePlayReportingAPI.Client)
        #expect(service.games is GooglePlayGamesConfigurationAPI.Client)
        #expect(service.integrity is GooglePlayIntegrityAPI.Client)
        #expect(service.customApps is GooglePlayCustomAppAPI.Client)
        #expect(service.gamesManagement is GooglePlayGamesManagementAPI.Client)
    }

    @Test("Initialization fails and throws when given invalid key data")
    func initFailsWithInvalidKey() {
        let mockTransport = MockTransport()
        #expect(throws: Error.self) {
            _ = try GooglePlayService(
                key: "CORRUPT_KEY_DATA",
                transport: mockTransport
            )
        }
    }
}
