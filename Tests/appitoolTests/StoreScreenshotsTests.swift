import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import OpenAPIRuntime
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import appitool
import AppStoreConnectAPI
import AppleServices
import GoogleServices

@Suite("Store Screenshots Tests", .serialized)
struct StoreScreenshotsTests {

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
          "project_id": "my-play-project",
          "private_key_id": "key_id_play",
          "private_key": "\(escapedKey)",
          "client_email": "play-sa@my-play-project.iam.gserviceaccount.com",
          "client_id": "1122334455",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "https://oauth2.googleapis.com/token"
        }
        """
    }

    private final class CapturingTransport: ClientTransport, @unchecked Sendable {
        struct CapturedRequest {
            let request: HTTPRequest
            let operationID: String
            let bodyData: Data?
        }

        private let lock = NSLock()
        private var responses: [(status: HTTPResponse.Status, body: Data?)]
        private(set) var capturedRequests: [CapturedRequest] = []

        init(responses: [(status: HTTPResponse.Status, body: Data?)]) {
            self.responses = responses
        }

        convenience init(statusCode: HTTPResponse.Status, responseBody: Data? = nil) {
            self.init(responses: [(statusCode, responseBody)])
        }

        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            var collected: Data? = nil
            if let body {
                var data = Data()
                for try await chunk in body {
                    data.append(contentsOf: chunk)
                }
                collected = data
            }

            let nextResponse: (status: HTTPResponse.Status, body: Data?) = lock.withLock {
                capturedRequests.append(CapturedRequest(request: request, operationID: operationID, bodyData: collected))
                if responses.count > 1 {
                    return responses.removeFirst()
                }
                return responses.first ?? (.ok, nil)
            }

            let response = HTTPResponse(status: nextResponse.status)
            let outBody = nextResponse.body.map { HTTPBody($0) }
            return (response, outBody)
        }
    }

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        struct RecordedRequest {
            let method: String
            let url: URL
            let headers: [String: String]
            let body: Data?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var requestHandler: ((RecordedRequest) throws -> (Int, Data))?
        nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

        static func reset(handler: @escaping (RecordedRequest) throws -> (Int, Data)) {
            lock.withLock {
                recorded = []
                requestHandler = handler
            }
        }

        static func takeRecordedRequests() -> [RecordedRequest] {
            lock.withLock {
                let copy = recorded
                recorded = []
                requestHandler = nil
                return copy
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: bufferSize)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                if !data.isEmpty {
                    bodyData = data
                }
            }

            let captured = RecordedRequest(
                method: request.httpMethod ?? "GET",
                url: request.url!,
                headers: request.allHTTPHeaderFields ?? [:],
                body: bodyData
            )

            let currentHandler: ((RecordedRequest) throws -> (Int, Data))? = Self.lock.withLock {
                Self.recorded.append(captured)
                return Self.requestHandler
            }

            guard let currentHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }

            do {
                let (statusCode, data) = try currentHandler(captured)
                let response = HTTPURLResponse(
                    url: captured.url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeMockedURLSession(
        handler: @escaping (MockURLProtocol.RecordedRequest) throws -> (Int, Data)
    ) -> URLSession {
        MockURLProtocol.reset(handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeAppleService(
        transport: CapturingTransport,
        urlSession: URLSession = .shared
    ) throws -> AppStoreService {
        let key = P256.Signing.PrivateKey()
        return try AppStoreService(
            keyId: "TEST_KID",
            issuerId: "TEST_ISS",
            key: key.pemRepresentation,
            transport: transport,
            urlSession: urlSession
        )
    }

    private func makeGoogleService(
        transport: CapturingTransport,
        uploadHandler: @escaping (MockURLProtocol.RecordedRequest) throws -> (Int, Data)
    ) throws -> GooglePlayService {
        let session = makeMockedURLSession { req in
            if req.url.host == "oauth2.googleapis.com" {
                let tokenJSON = #"{"access_token":"test_play_token","expires_in":3600,"token_type":"Bearer"}"#
                return (200, Data(tokenJSON.utf8))
            }
            return try uploadHandler(req)
        }
        return try GooglePlayService(
            key: sampleServiceAccountJSON,
            transport: transport,
            urlSession: session
        )
    }

    private func decodeJSON(_ data: Data?) throws -> [String: Any] {
        let rawData = try #require(data)
        let obj = try JSONSerialization.jsonObject(with: rawData)
        return try #require(obj as? [String: Any])
    }

    // MARK: - ScreenshotFileResolver Tests

    @Test("ScreenshotFileResolver resolves files and naturally sorted directories, deduplicates, and rejects invalid inputs")
    func fileResolverBehavior() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appitool-screenshots-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img10 = tempDir.appendingPathComponent("10.jpeg")
        let img2 = tempDir.appendingPathComponent("2.JPG")
        let img1 = tempDir.appendingPathComponent("1.png")
        let hidden = tempDir.appendingPathComponent(".hidden.png")
        let ignored = tempDir.appendingPathComponent("notes.txt")
        let emptyFile = tempDir.appendingPathComponent("empty.png")

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: img1)
        try Data([0xFF, 0xD8, 0xFF]).write(to: img2)
        try Data([0xFF, 0xD8, 0xEE]).write(to: img10)
        try Data([0x89, 0x50]).write(to: hidden)
        try Data("hello".utf8).write(to: ignored)
        try Data().write(to: emptyFile)

        // Direct files + deduplication
        let direct = try ScreenshotFileResolver.resolveImageFiles(from: [img2.path, img1.path, img2.path])
        #expect(direct.map(\.lastPathComponent) == ["2.JPG", "1.png"])
        #expect(ScreenshotFileResolver.mimeType(for: img1) == "image/png")
        #expect(ScreenshotFileResolver.mimeType(for: img2) == "image/jpeg")
        #expect(ScreenshotFileResolver.mimeType(for: img10) == "image/jpeg")

        // Remove empty.png so directory scan succeeds cleanly and tests natural sort + skip hidden/non-image
        try FileManager.default.removeItem(at: emptyFile)
        let dirResolved = try ScreenshotFileResolver.resolveImageFiles(from: [tempDir.path])
        #expect(dirResolved.map(\.lastPathComponent) == ["1.png", "2.JPG", "10.jpeg"])

        // Error cases
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveImageFiles(from: [tempDir.appendingPathComponent("missing.png").path])
        }
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveImageFiles(from: [ignored.path])
        }

        let emptyDir = tempDir.appendingPathComponent("emptyDir")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveImageFiles(from: [emptyDir.path])
        }
    }

    // MARK: - AppleTypeMapper Screenshot Tests

    @Test("AppleTypeMapper parses platforms and screenshot display type aliases and rejects invalid inputs")
    func appleScreenshotTypeMapping() throws {
        #expect(try AppleTypeMapper.parsePlatform("ios") == .IOS)
        #expect(try AppleTypeMapper.parsePlatform("macos") == .MAC_OS)
        #expect(try AppleTypeMapper.parsePlatform("tv") == .TV_OS)
        #expect(try AppleTypeMapper.parsePlatform("visionos") == .VISION_OS)
        #expect(throws: AppStoreServiceError.self) {
            _ = try AppleTypeMapper.parsePlatform("android")
        }

        #expect(try AppleTypeMapper.parseScreenshotDisplayType("iphone-67") == .APP_IPHONE_67)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("iphone-6.9") == .APP_IPHONE_67)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("APP_IPHONE_65") == .APP_IPHONE_65)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("ipad-pro-129") == .APP_IPAD_PRO_3GEN_129)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("mac") == .APP_DESKTOP)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("watch-ultra") == .APP_WATCH_ULTRA)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("apple-tv") == .APP_APPLE_TV)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("vision-pro") == .APP_APPLE_VISION_PRO)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("imessage-iphone-67") == .IMESSAGE_APP_IPHONE_67)

        #expect(throws: AppStoreServiceError.self) {
            _ = try AppleTypeMapper.parseScreenshotDisplayType("unknown-display")
        }
    }

    // MARK: - Apple AppStoreService+Screenshots Tests

    @Test("resolveAppStoreVersion selects editable versions first and enforces requireEditable")
    func resolveAppStoreVersionSelection() async throws {
        let versionsJSON = """
        {
            "data": [
                {
                    "type": "appStoreVersions",
                    "id": "v-live",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": "1.0.0",
                        "appVersionState": "READY_FOR_DISTRIBUTION"
                    }
                },
                {
                    "type": "appStoreVersions",
                    "id": "v-edit",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": "1.1.0",
                        "appVersionState": "PREPARE_FOR_SUBMISSION"
                    }
                }
            ],
            "links": { "self": "https://api.appstoreconnect.apple.com/v1/apps/1/appStoreVersions" }
        }
        """.data(using: .utf8)!

        let service1 = try makeAppleService(transport: CapturingTransport(statusCode: .ok, responseBody: versionsJSON))
        let editable = try await service1.resolveAppStoreVersion(appId: "1", requireEditable: true)
        #expect(editable.id == "v-edit")
        #expect(editable.attributes?.versionString == "1.1.0")

        let onlyLiveJSON = """
        {
            "data": [
                {
                    "type": "appStoreVersions",
                    "id": "v-live",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": "1.0.0",
                        "appVersionState": "READY_FOR_DISTRIBUTION"
                    }
                }
            ],
            "links": { "self": "https://api.appstoreconnect.apple.com/v1/apps/1/appStoreVersions" }
        }
        """.data(using: .utf8)!

        let serviceReadOnly = try makeAppleService(transport: CapturingTransport(statusCode: .ok, responseBody: onlyLiveJSON))
        let fallback = try await serviceReadOnly.resolveAppStoreVersion(appId: "1", requireEditable: false)
        #expect(fallback.id == "v-live")

        let serviceStrict = try makeAppleService(transport: CapturingTransport(statusCode: .ok, responseBody: onlyLiveJSON))
        do {
            _ = try await serviceStrict.resolveAppStoreVersion(appId: "1", requireEditable: true)
            Issue.record("Expected AppStoreServiceError.notFound when requireEditable is true and no editable version exists")
        } catch AppStoreServiceError.notFound {
            // Expected
        }
    }

    @Test("uploadScreenshot performs reserve, chunked upload, MD5 commit, and polls until COMPLETE")
    func appleUploadScreenshotPipeline() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("appitool-apple-ss-\(UUID().uuidString).png")
        let payloadBytes = Data("123456789".utf8) // 9 bytes split into 5 + 4
        try payloadBytes.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let expectedMD5 = Insecure.MD5.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()

        let createResponse = """
        {
            "data": {
                "type": "appScreenshots",
                "id": "ss-100",
                "attributes": {
                    "fileSize": 9,
                    "fileName": "\(tempFile.lastPathComponent)",
                    "uploadOperations": [
                        {
                            "method": "PUT",
                            "url": "https://upload.example.apple.com/chunk1",
                            "offset": 0,
                            "length": 5,
                            "requestHeaders": [
                                { "name": "Content-Type", "value": "image/png" },
                                { "name": "X-Chunk", "value": "1" }
                            ]
                        },
                        {
                            "method": "PUT",
                            "url": "https://upload.example.apple.com/chunk2",
                            "offset": 5,
                            "length": 4,
                            "requestHeaders": [
                                { "name": "Content-Type", "value": "image/png" },
                                { "name": "X-Chunk", "value": "2" }
                            ]
                        }
                    ],
                    "assetDeliveryState": { "state": "AWAITING_UPLOAD" }
                }
            },
            "links": { "self": "https://api.appstoreconnect.apple.com/v1/appScreenshots/ss-100" }
        }
        """.data(using: .utf8)!

        let patchResponse = """
        {
            "data": {
                "type": "appScreenshots",
                "id": "ss-100",
                "attributes": {
                    "fileSize": 9,
                    "fileName": "\(tempFile.lastPathComponent)",
                    "sourceFileChecksum": "\(expectedMD5)",
                    "assetDeliveryState": { "state": "UPLOAD_COMPLETE" }
                }
            },
            "links": { "self": "https://api.appstoreconnect.apple.com/v1/appScreenshots/ss-100" }
        }
        """.data(using: .utf8)!

        let getCompleteResponse = """
        {
            "data": {
                "type": "appScreenshots",
                "id": "ss-100",
                "attributes": {
                    "fileSize": 9,
                    "fileName": "\(tempFile.lastPathComponent)",
                    "sourceFileChecksum": "\(expectedMD5)",
                    "imageAsset": {
                        "templateUrl": "https://is1-ssl.mzstatic.com/{w}x{h}bb.png",
                        "width": 1290,
                        "height": 2796
                    },
                    "assetDeliveryState": { "state": "COMPLETE" }
                }
            },
            "links": { "self": "https://api.appstoreconnect.apple.com/v1/appScreenshots/ss-100" }
        }
        """.data(using: .utf8)!

        let transport = CapturingTransport(responses: [
            (.created, createResponse),
            (.ok, patchResponse),
            (.ok, getCompleteResponse),
        ])
        let session = makeMockedURLSession { _ in (200, Data()) }
        defer { _ = MockURLProtocol.takeRecordedRequests() }

        let service = try makeAppleService(transport: transport, urlSession: session)
        let uploaded = try await service.uploadScreenshot(
            screenshotSetId: "set-1",
            fileUrl: tempFile,
            waitForProcessing: true,
            pollInterval: 0.01,
            processingTimeout: 5
        )

        #expect(uploaded.id == "ss-100")
        #expect(uploaded.attributes?.assetDeliveryState?.state == .COMPLETE)
        #expect(uploaded.attributes?.imageAsset?.width == 1290)
        #expect(uploaded.attributes?.imageAsset?.height == 2796)

        #expect(transport.capturedRequests.count == 3)
        #expect(transport.capturedRequests[0].operationID == "appScreenshots_createInstance")
        let createBody = try decodeJSON(transport.capturedRequests[0].bodyData)
        let createData = try #require(createBody["data"] as? [String: Any])
        let createAttrs = try #require(createData["attributes"] as? [String: Any])
        #expect(createAttrs["fileSize"] as? Int == 9)
        #expect(createAttrs["fileName"] as? String == tempFile.lastPathComponent)

        #expect(transport.capturedRequests[1].operationID == "appScreenshots_updateInstance")
        let patchBody = try decodeJSON(transport.capturedRequests[1].bodyData)
        let patchData = try #require(patchBody["data"] as? [String: Any])
        let patchAttrs = try #require(patchData["attributes"] as? [String: Any])
        #expect(patchAttrs["sourceFileChecksum"] as? String == expectedMD5)
        #expect(patchAttrs["uploaded"] as? Bool == true)

        #expect(transport.capturedRequests[2].operationID == "appScreenshots_getInstance")

        let chunkRequests = MockURLProtocol.takeRecordedRequests()
        #expect(chunkRequests.count == 2)
        #expect(chunkRequests[0].method == "PUT")
        #expect(chunkRequests[0].url.absoluteString == "https://upload.example.apple.com/chunk1")
        #expect(chunkRequests[0].headers["X-Chunk"] == "1")
        #expect(String(data: chunkRequests[0].body ?? Data(), encoding: .utf8) == "12345")

        #expect(chunkRequests[1].method == "PUT")
        #expect(chunkRequests[1].url.absoluteString == "https://upload.example.apple.com/chunk2")
        #expect(chunkRequests[1].headers["X-Chunk"] == "2")
        #expect(String(data: chunkRequests[1].body ?? Data(), encoding: .utf8) == "6789")
    }

    @Test("deleteScreenshot returns true on 204 and false on 404")
    func appleDeleteScreenshot() async throws {
        let transport204 = CapturingTransport(statusCode: .noContent)
        let service204 = try makeAppleService(transport: transport204)
        #expect(try await service204.deleteScreenshot(id: "ss-9") == true)
        #expect(transport204.capturedRequests.first?.operationID == "appScreenshots_deleteInstance")
        #expect(transport204.capturedRequests.first?.request.path == "/v1/appScreenshots/ss-9")

        // App Store Connect always returns a JSON error document on 404; the generated client requires it.
        let notFoundJSON = """
        {
            "errors": [
                {
                    "id": "ERR_404",
                    "status": "404",
                    "code": "NOT_FOUND",
                    "title": "The specified resource does not exist",
                    "detail": "There is no resource of type 'appScreenshots' with id 'ss-missing'"
                }
            ]
        }
        """.data(using: .utf8)!
        let transport404 = CapturingTransport(statusCode: .notFound, responseBody: notFoundJSON)
        let service404 = try makeAppleService(transport: transport404)
        #expect(try await service404.deleteScreenshot(id: "ss-missing") == false)
    }

    // MARK: - GooglePlayImageType & GooglePlayService+Images Tests

    @Test("GooglePlayImageType parses CLI keys, aliases, and exact API strings")
    func googlePlayImageTypeParsing() throws {
        #expect(try GooglePlayImageType.parse("phone") == .phoneScreenshots)
        #expect(try GooglePlayImageType.parse("phoneScreenshots") == .phoneScreenshots)
        #expect(try GooglePlayImageType.parse("tablet7") == .sevenInchScreenshots)
        #expect(try GooglePlayImageType.parse("tablet10") == .tenInchScreenshots)
        #expect(try GooglePlayImageType.parse("tv") == .tvScreenshots)
        #expect(try GooglePlayImageType.parse("wear") == .wearScreenshots)
        #expect(try GooglePlayImageType.parse("icon") == .icon)
        #expect(try GooglePlayImageType.parse("feature-graphic") == .featureGraphic)
        #expect(try GooglePlayImageType.parse("tv-banner") == .tvBanner)

        #expect(throws: GooglePlayImageError.self) {
            _ = try GooglePlayImageType.parse("invalid-type")
        }
    }

    @Test("GooglePlayService edit session uploads media, commits, validates, and rolls back on error")
    func googlePlayImagesAndEditLifecycle() async throws {
        let tempImg = FileManager.default.temporaryDirectory
            .appendingPathComponent("appitool-play-ss-\(UUID().uuidString).png")
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        try pngBytes.write(to: tempImg)
        defer { try? FileManager.default.removeItem(at: tempImg) }

        // 1. Upload & commit inside withEditSession
        let editCreatedJSON = #"{"id":"edit-42","expiryTimeSeconds":"9999999"}"#.data(using: .utf8)!
        let editCommittedJSON = #"{"id":"edit-42"}"#.data(using: .utf8)!
        let transportUpload = CapturingTransport(responses: [
            (.ok, editCreatedJSON),
            (.ok, editCommittedJSON),
        ])

        let serviceUpload = try makeGoogleService(transport: transportUpload) { req in
            let responseJSON = #"{"image":{"id":"gp-img-1","url":"https://play.googleusercontent.com/1","sha1":"s1","sha256":"s256"}}"#
            return (200, Data(responseJSON.utf8))
        }
        defer { _ = MockURLProtocol.takeRecordedRequests() }

        let uploaded = try await serviceUpload.withEditSession(
            packageName: "com.example.app",
            commit: true
        ) { editId in
            try await serviceUpload.uploadImage(
                packageName: "com.example.app",
                editId: editId,
                language: "en-US",
                imageType: .phoneScreenshots,
                fileUrl: tempImg
            )
        }

        #expect(uploaded.id == "gp-img-1")
        #expect(uploaded.url == "https://play.googleusercontent.com/1")
        #expect(transportUpload.capturedRequests.map(\.operationID) == [
            "androidpublisher.edits.insert",
            "androidpublisher.edits.commit",
        ])

        let httpRequests = MockURLProtocol.takeRecordedRequests()
        let uploadReq = try #require(httpRequests.first(where: { $0.url.host == "androidpublisher.googleapis.com" }))
        #expect(uploadReq.method == "POST")
        #expect(uploadReq.url.path == "/upload/androidpublisher/v3/applications/com.example.app/edits/edit-42/listings/en-US/phoneScreenshots")
        #expect(uploadReq.url.query == "uploadType=media")
        #expect(uploadReq.headers["Content-Type"] == "image/png")
        #expect(uploadReq.headers["Authorization"] == "Bearer test_play_token")
        #expect(uploadReq.body == pngBytes)

        // 2. Rollback deletes edit when closure throws
        let transportRollback = CapturingTransport(responses: [
            (.ok, editCreatedJSON),
            (.ok, nil),
        ])
        let serviceRollback = try makeGoogleService(transport: transportRollback) { _ in (200, Data()) }
        do {
            _ = try await serviceRollback.withEditSession(packageName: "com.example.app", commit: true) { _ in
                throw GooglePlayImageError.invalidResponse("Simulated failure")
            }
            Issue.record("Expected simulated error to be rethrown")
        } catch GooglePlayImageError.invalidResponse {
            // Expected
        }
        #expect(transportRollback.capturedRequests.map(\.operationID) == [
            "androidpublisher.edits.insert",
            "androidpublisher.edits.delete",
        ])
    }

    // MARK: - CLI Parsing & CI Guard Tests

    @Test("GoogleCommand and AppleCommand parse all screenshots subcommands without option collisions")
    func cliScreenshotCommandParsing() throws {
        // Google subcommands
        _ = try appitool.parseAsRoot(["google", "screenshots", "types"])

        let gList = try #require(
            try appitool.parseAsRoot(["google", "screenshots", "list", "--package-name", "com.example.app", "--locale", "en-US", "-t", "phone"]) as? GoogleScreenshotsListCommand
        )
        #expect(gList.app.packageName == "com.example.app")
        #expect(gList.locale == "en-US")
        #expect(gList.type == "phone")

        let gUpload = try #require(
            try appitool.parseAsRoot([
                "google", "screenshots", "upload",
                "--package-name", "com.example.app",
                "--locale", "tr-TR",
                "-t", "feature-graphic",
                "--replace",
                "--validate-only",
                "--changes-not-sent-for-review",
                "--dry-run",
                "./banner.png",
            ]) as? GoogleScreenshotsUploadCommand
        )
        #expect(gUpload.locale == "tr-TR")
        #expect(gUpload.type == "feature-graphic")
        #expect(gUpload.replace == true)
        #expect(gUpload.validateOnly == true)
        #expect(gUpload.changesNotSentForReview == true)
        #expect(gUpload.dryRun == true)
        #expect(gUpload.paths == ["./banner.png"])

        let gDelete = try #require(
            try appitool.parseAsRoot([
                "--ci", "google", "screenshots", "delete",
                "--locale", "en-US", "-t", "phone", "--all",
            ]) as? GoogleScreenshotsDeleteCommand
        )
        #expect(gDelete.isDestructive == true)
        #expect(gDelete.destructiveCommandDescription == "google screenshots delete")
        #expect(gDelete.ciFlagOverride == true)
        #expect(gDelete.all == true)

        // Apple subcommands
        _ = try appitool.parseAsRoot(["apple", "screenshots", "types"])

        let aList = try #require(
            try appitool.parseAsRoot([
                "apple", "screenshots", "list",
                "-b", "com.example.app",
                "--app-version", "1.2.0",
                "-p", "ios",
                "--locale", "en-US",
                "-t", "iphone-67",
            ]) as? AppleScreenshotsListCommand
        )
        #expect(aList.app.bundleId == "com.example.app")
        #expect(aList.app.appVersion == "1.2.0")
        #expect(aList.app.platform == "ios")
        #expect(aList.locale == "en-US")
        #expect(aList.type == "iphone-67")

        let aUpload = try #require(
            try appitool.parseAsRoot([
                "apple", "screenshots", "upload",
                "--app-id", "673000111",
                "--app-version", "2.0.0",
                "--locale", "en-US",
                "-t", "iphone-67",
                "--replace",
                "--no-wait-processing",
                "--dry-run",
                "./shots/",
            ]) as? AppleScreenshotsUploadCommand
        )
        #expect(aUpload.app.appId == "673000111")
        #expect(aUpload.app.appVersion == "2.0.0")
        #expect(aUpload.locale == "en-US")
        #expect(aUpload.type == "iphone-67")
        #expect(aUpload.replace == true)
        #expect(aUpload.waitProcessing == false)
        #expect(aUpload.dryRun == true)
        #expect(aUpload.paths == ["./shots/"])

        let aDelete = try #require(
            try appitool.parseAsRoot([
                "apple", "screenshots", "delete",
                "--id", "ss-1",
                "--ci",
            ]) as? AppleScreenshotsDeleteCommand
        )
        #expect(aDelete.isDestructive == true)
        #expect(aDelete.destructiveCommandDescription == "apple screenshots delete")
        #expect(aDelete.id == "ss-1")
        #expect(aDelete.ciFlagOverride == true)

        let gDownload = try #require(
            try appitool.parseAsRoot([
                "google", "screenshots", "download",
                "--package-name", "com.example.app",
                "--locale", "en-US",
                "-t", "phone",
                "-o", "/tmp/shots",
                "--dry-run",
            ]) as? GoogleScreenshotsDownloadCommand
        )
        #expect(gDownload.app.packageName == "com.example.app")
        #expect(gDownload.locale == "en-US")
        #expect(gDownload.type == "phone")
        #expect(gDownload.output == "/tmp/shots")
        #expect(gDownload.dryRun == true)

        let aDownload = try #require(
            try appitool.parseAsRoot([
                "apple", "screenshots", "download",
                "-b", "com.example.app",
                "--app-version", "1.2.0",
                "--platform", "ios",
                "--locale", "tr",
                "-t", "iphone-67",
                "-o", "/tmp/apple-shots",
                "--dry-run",
            ]) as? AppleScreenshotsDownloadCommand
        )
        #expect(aDownload.app.bundleId == "com.example.app")
        #expect(aDownload.app.appVersion == "1.2.0")
        #expect(aDownload.app.platform == "ios")
        #expect(aDownload.locale == "tr")
        #expect(aDownload.type == "iphone-67")
        #expect(aDownload.output == "/tmp/apple-shots")
        #expect(aDownload.dryRun == true)
    }

    // MARK: - Screenshot Download Helpers & Path Tests

    @Test("AppitoolPaths resolves per-project screenshot directories and sanitizes unsafe characters")
    func appitoolPathsScreenshotsLayout() {
        let appleDir = AppitoolPaths.screenshotsDirectory(project: "com.example.app", store: "apple")
        #expect(appleDir.path == AppitoolPaths.rootDirectory
            .appendingPathComponent("screenshots")
            .appendingPathComponent("com.example.app")
            .appendingPathComponent("apple").path)

        let googleDir = AppitoolPaths.screenshotsDirectory(project: "com.example.app", store: "google")
        #expect(googleDir.path == AppitoolPaths.rootDirectory
            .appendingPathComponent("screenshots")
            .appendingPathComponent("com.example.app")
            .appendingPathComponent("google").path)

        let sanitized = AppitoolPaths.screenshotsDirectory(project: "../evil/app", store: "apple")
        #expect(sanitized.deletingLastPathComponent().lastPathComponent == "__evil_app")
    }

    @Test("ScreenshotFileResolver formats order-prefixed filenames without double prefixing and detects formats")
    func downloadFilenameAndFormatDetection() {
        #expect(
            ScreenshotFileResolver.orderPrefixedFilename(
                index: 1,
                totalCount: 5,
                originalName: "home_screen.png",
                fileExtension: "png"
            ) == "01_home_screen.png"
        )
        #expect(
            ScreenshotFileResolver.orderPrefixedFilename(
                index: 2,
                totalCount: 5,
                originalName: "01_home_screen.png",
                fileExtension: "png"
            ) == "02_home_screen.png"
        )
        #expect(
            ScreenshotFileResolver.orderPrefixedFilename(
                index: 12,
                totalCount: 12,
                originalName: "05-details.jpeg",
                fileExtension: "jpg"
            ) == "12_details.jpg"
        )
        #expect(
            ScreenshotFileResolver.orderPrefixedFilename(
                index: 3,
                totalCount: 4,
                originalName: nil,
                fileExtension: "png"
            ) == "03.png"
        )

        #expect(ScreenshotFileResolver.detectImageExtension(contentType: nil, data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == "png")
        #expect(ScreenshotFileResolver.detectImageExtension(contentType: nil, data: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(
            ScreenshotFileResolver.detectImageExtension(
                contentType: nil,
                data: Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
            ) == "webp"
        )
        #expect(ScreenshotFileResolver.detectImageExtension(contentType: "image/jpeg; charset=utf-8", data: Data([1, 2, 3])) == "jpg")
        #expect(ScreenshotFileResolver.detectImageExtension(contentType: nil, data: Data([1, 2, 3]), fallback: "png") == "png")
    }

    @Test("AppStoreService resolves ImageAsset template URLs and downloads screenshot bytes")
    func appleScreenshotDownloadURLAndFetch() async throws {
        let pngResolved = AppStoreService.resolveScreenshotDownloadURL(
            templateUrl: "https://is1-ssl.mzstatic.com/image/thumb/Purple/{w}x{h}bb.{f}",
            width: 1290,
            height: 2796,
            fileName: "home.PNG"
        )
        #expect(pngResolved?.url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Purple/1290x2796bb.png")
        #expect(pngResolved?.fileExtension == "png")

        let jpgResolved = AppStoreService.resolveScreenshotDownloadURL(
            templateUrl: "https://is1-ssl.mzstatic.com/image/thumb/Purple/{w}x{h}bb.{f}",
            width: 1290,
            height: 2796,
            fileName: "banner.jpeg"
        )
        #expect(jpgResolved?.url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Purple/1290x2796bb.jpg")
        #expect(jpgResolved?.fileExtension == "jpg")

        #expect(AppStoreService.resolveScreenshotDownloadURL(templateUrl: nil, width: 100, height: 100, fileName: "a.png") == nil)
        #expect(AppStoreService.resolveScreenshotDownloadURL(templateUrl: "https://ex.com/{w}x{h}.{f}", width: nil, height: 100, fileName: "a.png") == nil)

        let expectedBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let session = makeMockedURLSession { _ in (200, expectedBytes) }
        defer { _ = MockURLProtocol.takeRecordedRequests() }

        let service = try makeAppleService(transport: CapturingTransport(statusCode: .ok), urlSession: session)
        let downloaded = try await service.downloadScreenshotData(from: try #require(pngResolved?.url))
        #expect(downloaded.data == expectedBytes)

        let requests = MockURLProtocol.takeRecordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Purple/1290x2796bb.png")
    }

    @Test("GooglePlayService rewrites CDN URLs to full resolution =s0 and downloads image bytes")
    func googlePlayFullResolutionURLAndFetch() async throws {
        #expect(
            GooglePlayService.fullResolutionImageURL(from: "https://play-lh.googleusercontent.com/abc123=w500-h500")?.absoluteString
                == "https://play-lh.googleusercontent.com/abc123=s0"
        )
        #expect(
            GooglePlayService.fullResolutionImageURL(from: "https://lh3.googleusercontent.com/xyz987")?.absoluteString
                == "https://lh3.googleusercontent.com/xyz987=s0"
        )
        #expect(
            GooglePlayService.fullResolutionImageURL(from: "https://example.com/custom.png")?.absoluteString
                == "https://example.com/custom.png"
        )

        let expectedBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let service = try makeGoogleService(transport: CapturingTransport(statusCode: .ok)) { _ in
            (200, expectedBytes)
        }
        defer { _ = MockURLProtocol.takeRecordedRequests() }

        let targetURL = try #require(
            GooglePlayService.fullResolutionImageURL(from: "https://play-lh.googleusercontent.com/abc123=h300-rw")
        )
        let downloaded = try await service.downloadImageData(from: targetURL)
        #expect(downloaded.data == expectedBytes)

        let requests = MockURLProtocol.takeRecordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].url.absoluteString == "https://play-lh.googleusercontent.com/abc123=s0")
    }

    // MARK: - Symmetrical Bulk Upload Batch Discovery & CLI Tests

    @Test("ScreenshotFileResolver.resolveUploadBatches discovers <locale>/<type>/ trees, filters, and sorts naturally")
    func uploadBatchDiscoveryFiltersAndSorting() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("appitool-upload-batches-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appleRoot = root.appendingPathComponent("apple")
        let enIphoneDir = appleRoot.appendingPathComponent("en-US/iphone-67")
        let enIpadDir = appleRoot.appendingPathComponent("en-US/ipad-pro-129")
        let trIphoneDir = appleRoot.appendingPathComponent("tr/iphone-67")
        let emptyMiscDir = appleRoot.appendingPathComponent("tr/empty-folder")
        for dir in [enIphoneDir, enIpadDir, trIphoneDir, emptyMiscDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let dummyPng = Data([0x89, 0x50, 0x4E, 0x47])
        try dummyPng.write(to: enIphoneDir.appendingPathComponent("10_last.png"))
        try dummyPng.write(to: enIphoneDir.appendingPathComponent("2_second.png"))
        try dummyPng.write(to: enIphoneDir.appendingPathComponent("1_first.png"))
        try dummyPng.write(to: enIpadDir.appendingPathComponent("01_ipad.png"))
        try dummyPng.write(to: trIphoneDir.appendingPathComponent("01_tr.png"))

        // 1. Default directory bulk scan (empty paths, no filters)
        let (sourceRoot, allBatches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [],
            defaultDirectory: { appleRoot },
            localeFilter: nil,
            typeFilter: nil,
            defaultFlatType: nil,
            storeDisplayName: "App Store Connect",
            downloadHintCommand: "appitool apple screenshots download",
            parseType: AppleTypeMapper.parseScreenshotDisplayType
        )
        #expect(sourceRoot?.path == appleRoot.standardizedFileURL.path)
        #expect(allBatches.count == 3)
        #expect(allBatches[0].locale == "en-US")
        // `ipad-pro-129` maps to the current 12.9"/13" (3rd+ gen) slot; the 2nd-gen slot is `ipad-pro-129-2gen`.
        #expect(allBatches[0].type == .APP_IPAD_PRO_3GEN_129)
        #expect(allBatches[1].locale == "en-US")
        #expect(allBatches[1].type == .APP_IPHONE_67)
        #expect(allBatches[1].files.map(\.lastPathComponent) == ["1_first.png", "2_second.png", "10_last.png"])
        #expect(allBatches[2].locale == "tr")
        #expect(allBatches[2].type == .APP_IPHONE_67)

        // 2. Filtering by case-insensitive locale and alias display type
        let (_, filteredBatches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [],
            defaultDirectory: { appleRoot },
            localeFilter: "EN-us",
            typeFilter: "APP_IPHONE_67",
            defaultFlatType: nil,
            storeDisplayName: "App Store Connect",
            downloadHintCommand: "appitool apple screenshots download",
            parseType: AppleTypeMapper.parseScreenshotDisplayType
        )
        #expect(filteredBatches.count == 1)
        #expect(filteredBatches[0].locale == "EN-us")
        #expect(filteredBatches[0].type == .APP_IPHONE_67)
        #expect(filteredBatches[0].files.count == 3)

        // 3. Single 1-level <locale>/ path with locale filter
        let enLocaleDir = appleRoot.appendingPathComponent("en-US")
        let (singleRoot, localeBatches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [enLocaleDir.path],
            defaultDirectory: { appleRoot },
            localeFilter: "en-US",
            typeFilter: nil,
            defaultFlatType: nil,
            storeDisplayName: "App Store Connect",
            downloadHintCommand: "appitool apple screenshots download",
            parseType: AppleTypeMapper.parseScreenshotDisplayType
        )
        #expect(singleRoot?.path == enLocaleDir.standardizedFileURL.path)
        #expect(localeBatches.count == 2)
        #expect(localeBatches.allSatisfy { $0.locale == "en-US" })

        // 4. Flat directory with Google defaultFlatType (.phoneScreenshots)
        let googleFlatDir = root.appendingPathComponent("flat-google")
        try fm.createDirectory(at: googleFlatDir, withIntermediateDirectories: true)
        try dummyPng.write(to: googleFlatDir.appendingPathComponent("01.png"))
        let (flatRoot, flatBatches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [googleFlatDir.path],
            defaultDirectory: { root.appendingPathComponent("unused") },
            localeFilter: "tr-TR",
            typeFilter: nil,
            defaultFlatType: GooglePlayImageType.phoneScreenshots,
            storeDisplayName: "Google Play",
            downloadHintCommand: "appitool google screenshots download",
            parseType: GooglePlayImageType.parse
        )
        #expect(flatRoot == nil)
        #expect(flatBatches.count == 1)
        #expect(flatBatches[0].locale == "tr-TR")
        #expect(flatBatches[0].type == .phoneScreenshots)
        #expect(flatBatches[0].files.map(\.lastPathComponent) == ["01.png"])

        // 5. Explicit single file with Google defaultFlatType
        let singleFile = googleFlatDir.appendingPathComponent("01.png")
        let (_, fileBatches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [singleFile.path],
            defaultDirectory: { root.appendingPathComponent("unused") },
            localeFilter: "en-US",
            typeFilter: "feature-graphic",
            defaultFlatType: GooglePlayImageType.phoneScreenshots,
            storeDisplayName: "Google Play",
            downloadHintCommand: "appitool google screenshots download",
            parseType: GooglePlayImageType.parse
        )
        #expect(fileBatches.count == 1)
        #expect(fileBatches[0].type == .featureGraphic)
    }

    @Test("ScreenshotFileResolver.resolveUploadBatches reports clear errors on missing dirs, flags, and bad type folders")
    func uploadBatchDiscoveryErrors() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("appitool-upload-errors-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let dummyPng = Data([0x89, 0x50, 0x4E, 0x47])

        // 1. Missing default directory
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveUploadBatches(
                paths: [],
                defaultDirectory: { root.appendingPathComponent("does-not-exist") },
                localeFilter: nil,
                typeFilter: nil,
                defaultFlatType: nil,
                storeDisplayName: "App Store Connect",
                downloadHintCommand: "appitool apple screenshots download",
                parseType: AppleTypeMapper.parseScreenshotDisplayType
            )
        }

        // 2. Flat directory missing -l, --locale
        let flatDir = root.appendingPathComponent("flat")
        try fm.createDirectory(at: flatDir, withIntermediateDirectories: true)
        try dummyPng.write(to: flatDir.appendingPathComponent("01.png"))
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveUploadBatches(
                paths: [flatDir.path],
                defaultDirectory: { root },
                localeFilter: nil,
                typeFilter: "iphone-67",
                defaultFlatType: nil,
                storeDisplayName: "App Store Connect",
                downloadHintCommand: "appitool apple screenshots download",
                parseType: AppleTypeMapper.parseScreenshotDisplayType
            )
        }

        // 3. Flat directory on Apple missing -t, --type
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveUploadBatches(
                paths: [flatDir.path],
                defaultDirectory: { root },
                localeFilter: "en-US",
                typeFilter: nil,
                defaultFlatType: nil,
                storeDisplayName: "App Store Connect",
                downloadHintCommand: "appitool apple screenshots download",
                parseType: AppleTypeMapper.parseScreenshotDisplayType
            )
        }

        // 4. Unrecognized type folder containing PNG/JPEG
        let badTree = root.appendingPathComponent("bad-tree/en-US/not-a-real-type")
        try fm.createDirectory(at: badTree, withIntermediateDirectories: true)
        try dummyPng.write(to: badTree.appendingPathComponent("01.png"))
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveUploadBatches(
                paths: [],
                defaultDirectory: { root.appendingPathComponent("bad-tree") },
                localeFilter: nil,
                typeFilter: nil,
                defaultFlatType: nil,
                storeDisplayName: "App Store Connect",
                downloadHintCommand: "appitool apple screenshots download",
                parseType: AppleTypeMapper.parseScreenshotDisplayType
            )
        }

        // 5. Empty match when locale filter matches nothing
        let validTree = root.appendingPathComponent("valid-tree/en-US/iphone-67")
        try fm.createDirectory(at: validTree, withIntermediateDirectories: true)
        try dummyPng.write(to: validTree.appendingPathComponent("01.png"))
        #expect(throws: CommandError.self) {
            _ = try ScreenshotFileResolver.resolveUploadBatches(
                paths: [],
                defaultDirectory: { root.appendingPathComponent("valid-tree") },
                localeFilter: "ja",
                typeFilter: nil,
                defaultFlatType: nil,
                storeDisplayName: "App Store Connect",
                downloadHintCommand: "appitool apple screenshots download",
                parseType: AppleTypeMapper.parseScreenshotDisplayType
            )
        }
    }

    @Test("Upload commands accept zero positional paths and optional locale/type filters")
    func uploadCommandsSymmetricalCLIParsing() throws {
        let appleZero = try #require(
            try appitool.parseAsRoot(["apple", "screenshots", "upload"]) as? AppleScreenshotsUploadCommand
        )
        #expect(appleZero.locale == nil)
        #expect(appleZero.type == nil)
        #expect(appleZero.paths.isEmpty)
        #expect(appleZero.replace == false)
        #expect(appleZero.waitProcessing == true)

        let appleFiltered = try #require(
            try appitool.parseAsRoot(["apple", "screenshots", "upload", "--locale", "en-US", "--replace", "--dry-run"]) as? AppleScreenshotsUploadCommand
        )
        #expect(appleFiltered.locale == "en-US")
        #expect(appleFiltered.type == nil)
        #expect(appleFiltered.paths.isEmpty)
        #expect(appleFiltered.replace == true)
        #expect(appleFiltered.dryRun == true)

        let googleZero = try #require(
            try appitool.parseAsRoot(["google", "screenshots", "upload"]) as? GoogleScreenshotsUploadCommand
        )
        #expect(googleZero.locale == nil)
        #expect(googleZero.type == nil)
        #expect(googleZero.paths.isEmpty)
        #expect(googleZero.replace == false)

        let googleFiltered = try #require(
            try appitool.parseAsRoot(["google", "screenshots", "upload", "-t", "tablet7", "--replace", "--validate-only", "./shots"]) as? GoogleScreenshotsUploadCommand
        )
        #expect(googleFiltered.locale == nil)
        #expect(googleFiltered.type == "tablet7")
        #expect(googleFiltered.paths == ["./shots"])
        #expect(googleFiltered.replace == true)
        #expect(googleFiltered.validateOnly == true)
    }
}
