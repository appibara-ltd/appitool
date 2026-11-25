import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import OpenAPIRuntime
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Shared Test Credentials

enum TestCredentials {
    /// Throwaway RSA key used only by tests (never a real credential).
    static let rsaKeyPEM = """
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

    /// Service account JSON built from `rsaKeyPEM` (project `test-project`).
    static func serviceAccountJSON(projectId: String = "test-project") -> String {
        let escaped = rsaKeyPEM.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {
          "type": "service_account",
          "project_id": "\(projectId)",
          "private_key_id": "kid",
          "private_key": "\(escaped)",
          "client_email": "sa@\(projectId).iam.gserviceaccount.com",
          "client_id": "1",
          "token_uri": "https://oauth2.googleapis.com/token"
        }
        """
    }

    /// Fresh P-256 PEM usable as an App Store Connect `.p8` key.
    static func appleKeyPEM() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }
}

// MARK: - Recorded Request

struct StubRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
    /// OpenAPI operation ID when the request went through `StubTransport`.
    let operationID: String?

    var path: String { url.path }
    var query: String { url.query ?? "" }
    var bodyString: String { body.flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    func json() -> [String: Any] {
        guard let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return obj
    }
}

struct StubResponse: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String]

    init(_ status: Int = 200, _ body: Data = Data("{}".utf8), headers: [String: String] = ["Content-Type": "application/json"]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    init(_ status: Int = 200, json: String, headers: [String: String] = ["Content-Type": "application/json"]) {
        self.init(status, Data(json.utf8), headers: headers)
    }

    static func ok(_ json: String = "{}") -> StubResponse { StubResponse(200, json: json) }
    static func status(_ code: Int, _ json: String = "{}") -> StubResponse { StubResponse(code, json: json) }
}

typealias StubHandler = @Sendable (StubRequest) throws -> StubResponse

/// Thread-safe recorder for requests captured by a stub.
final class StubLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StubRequest] = []

    func append(_ request: StubRequest) { lock.withLock { items.append(request) } }
    var requests: [StubRequest] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
    func first(where predicate: (StubRequest) -> Bool) -> StubRequest? { requests.first(where: predicate) }
}

// MARK: - Router

/// Ordered route table: the first route whose method and path fragment match handles the request.
/// Routes registered with several responses return them in sequence (the last one repeats).
final class StubRouter: @unchecked Sendable {
    private struct Route {
        let method: String?
        let match: @Sendable (StubRequest) -> Bool
        var responses: [StubResponse]
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    let log = StubLog()
    var fallback: StubResponse = .status(404, #"{"error":{"code":404,"message":"no stub"}}"#)

    @discardableResult
    func on(_ method: String? = nil, _ fragment: String, _ responses: StubResponse...) -> StubRouter {
        on(method, where: { $0.url.absoluteString.contains(fragment) || ($0.operationID == fragment) }, responses)
    }

    @discardableResult
    func on(_ method: String? = nil, where match: @escaping @Sendable (StubRequest) -> Bool, _ responses: [StubResponse]) -> StubRouter {
        lock.withLock { routes.append(Route(method: method, match: match, responses: responses)) }
        return self
    }

    func handle(_ request: StubRequest) -> StubResponse {
        log.append(request)
        return lock.withLock {
            for index in routes.indices {
                let route = routes[index]
                if let method = route.method, method.uppercased() != request.method.uppercased() { continue }
                guard route.match(request) else { continue }
                if routes[index].responses.count > 1 {
                    return routes[index].responses.removeFirst()
                }
                return routes[index].responses.first ?? .ok()
            }
            return fallback
        }
    }

    var handler: StubHandler { { [self] in handle($0) } }
}

// MARK: - OpenAPI Transport Stub

/// `ClientTransport` that answers generated-client requests from a `StubRouter`.
final class StubTransport: ClientTransport, @unchecked Sendable {
    let router: StubRouter

    init(_ router: StubRouter = StubRouter()) {
        self.router = router
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var collected: Data?
        if let body {
            collected = try await Data(collecting: body, upTo: 50 * 1024 * 1024)
        }
        let rawPath = request.path ?? ""
        let url = URL(string: baseURL.absoluteString + rawPath) ?? baseURL
        var headers: [String: String] = [:]
        for field in request.headerFields { headers[field.name.canonicalName] = field.value }
        let stubRequest = StubRequest(method: request.method.rawValue, url: url, headers: headers, body: collected, operationID: operationID)
        let response = router.handle(stubRequest)
        var fields = HTTPFields()
        for (name, value) in response.headers {
            if let fieldName = HTTPField.Name(name) { fields[fieldName] = value }
        }
        return (HTTPResponse(status: .init(code: response.status), headerFields: fields), HTTPBody(response.body))
    }
}

// MARK: - URLSession Stub

/// URLProtocol that answers `URLSession` requests from the active handler.
/// Tests must use `HTTPStub.withSession` so only one handler is active at a time.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeHandler: StubHandler?

    static func setHandler(_ handler: StubHandler?) {
        lock.withLock { activeHandler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            // Read until EOF: streamed bodies (OpenAPI URLSessionTransport) are written concurrently, so
            // `hasBytesAvailable` can be false before the writer finishes; closing early crashes the writer.
            while true {
                let count = stream.read(buffer, maxLength: bufferSize)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            bodyData = data
        }
        let url = request.url!
        let stubRequest = StubRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: bodyData,
            operationID: nil
        )
        guard let handler = Self.lock.withLock({ Self.activeHandler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let response = try handler(stubRequest)
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Serializes access to `StubURLProtocol` across concurrently running suites.
actor HTTPStubGate {
    static let shared = HTTPStubGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum HTTPStub {
    /// Answers the Google OAuth token exchange; other requests fall through to `router`.
    static func googleTokenRoute(_ router: StubRouter) {
        router.on("POST", "oauth2.googleapis.com/token", .ok(#"{"access_token":"test-token","expires_in":3600,"token_type":"Bearer"}"#))
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Runs `body` with a stubbed `URLSession`; the handler is active only for the duration of the call.
    static func withSession<T>(_ router: StubRouter, _ body: (URLSession) async throws -> T) async throws -> T {
        await HTTPStubGate.shared.acquire()
        StubURLProtocol.setHandler(router.handler)
        do {
            let result = try await body(makeSession())
            StubURLProtocol.setHandler(nil)
            await HTTPStubGate.shared.release()
            return result
        } catch {
            StubURLProtocol.setHandler(nil)
            await HTTPStubGate.shared.release()
            throw error
        }
    }
}

// MARK: - Temporary Directories

enum TestFiles {
    static func makeTempDir(_ name: String = "appitool-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
