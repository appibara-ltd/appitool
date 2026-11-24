import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Platform of a Firebase App.
package enum FirebaseAppPlatform: String, Sendable, CaseIterable {
    case ios = "IOS"
    case android = "ANDROID"
    case web = "WEB"

    /// Collection segment of the app resource (`iosApps`, `androidApps`, `webApps`).
    var collection: String {
        switch self {
        case .ios: return "iosApps"
        case .android: return "androidApps"
        case .web: return "webApps"
        }
    }
}

/// A Firebase App in a project (`FirebaseAppInfo` / `IosApp` / `AndroidApp` / `WebApp`).
package struct FirebaseAppSummary: Sendable, Equatable, Decodable {
    /// Firebase App ID, e.g. `1:123456789:ios:abc123`.
    package let appId: String
    package let displayName: String?
    /// `IOS`, `ANDROID`, or `WEB`.
    package let platform: String?
    /// Bundle ID (iOS), package name (Android), or web ID (web).
    package let namespace: String?
    /// `ACTIVE` or `DELETED`.
    package let state: String?

    package init(appId: String, displayName: String?, platform: String?, namespace: String?, state: String?) {
        self.appId = appId
        self.displayName = displayName
        self.platform = platform
        self.namespace = namespace
        self.state = state
    }
}

/// Fields for creating a Firebase App (`projects.{iosApps|androidApps|webApps}.create`).
package struct FirebaseAppCreateRequest: Sendable, Equatable {
    package var platform: FirebaseAppPlatform
    package var displayName: String?
    /// iOS bundle ID or Android package name (ignored for web).
    package var identifier: String?
    /// iOS only.
    package var appStoreId: String?
    /// iOS only.
    package var teamId: String?
    /// Android only (hex, with or without colons).
    package var sha1Hashes: [String]
    /// Android only (hex, with or without colons).
    package var sha256Hashes: [String]

    package init(
        platform: FirebaseAppPlatform,
        displayName: String? = nil,
        identifier: String? = nil,
        appStoreId: String? = nil,
        teamId: String? = nil,
        sha1Hashes: [String] = [],
        sha256Hashes: [String] = []
    ) {
        self.platform = platform
        self.displayName = displayName
        self.identifier = identifier
        self.appStoreId = appStoreId
        self.teamId = teamId
        self.sha1Hashes = sha1Hashes
        self.sha256Hashes = sha256Hashes
    }

    /// JSON body of the create request.
    package func body() -> [String: Any] {
        var body: [String: Any] = [:]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        switch platform {
        case .ios:
            if let identifier { body["bundleId"] = identifier }
            if let appStoreId, !appStoreId.isEmpty { body["appStoreId"] = appStoreId }
            if let teamId, !teamId.isEmpty { body["teamId"] = teamId }
        case .android:
            if let identifier { body["packageName"] = identifier }
            if !sha1Hashes.isEmpty { body["sha1Hashes"] = sha1Hashes.map(FirebaseShaCertificate.normalize) }
            if !sha256Hashes.isEmpty { body["sha256Hashes"] = sha256Hashes.map(FirebaseShaCertificate.normalize) }
        case .web:
            break
        }
        return body
    }
}

/// A SHA certificate fingerprint registered on a Firebase Android app.
package struct FirebaseShaCertificate: Sendable, Equatable, Decodable {
    package enum CertType: String, Sendable, Decodable {
        case sha1 = "SHA_1"
        case sha256 = "SHA_256"
        case unspecified = "SHA_CERTIFICATE_TYPE_UNSPECIFIED"
    }

    /// `projects/{project}/androidApps/{appId}/sha/{shaId}`.
    package let name: String?
    package let shaHash: String
    package let certType: CertType?

    package init(name: String?, shaHash: String, certType: CertType?) {
        self.name = name
        self.shaHash = shaHash
        self.certType = certType
    }

    /// Lowercase hex without colons (the form Firebase stores).
    package static func normalize(_ hash: String) -> String {
        hash.lowercased().filter(\.isHexDigit)
    }
}

package struct FirebaseAppsError: LocalizedError, Sendable, Equatable {
    package let status: Int?
    package let message: String

    package var errorDescription: String? {
        if let status { return "Firebase Management API error (HTTP \(status)): \(message)" }
        return message
    }
}

extension FirebaseService {
    // MARK: - Firebase Apps (Firebase Management API)

    private static let managementBase = "https://firebase.googleapis.com/v1beta1"

    /// Lists every Firebase App of a project, all platforms and pages (`GET projects/{project}:searchApps`).
    package func listApps(project: String, showDeleted: Bool = false) async throws -> [FirebaseAppSummary] {
        struct Response: Decodable {
            let apps: [FirebaseAppSummary]?
            let nextPageToken: String?
        }
        var apps: [FirebaseAppSummary] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "\(Self.managementBase)/projects/\(Self.encodeSegment(project)):searchApps")
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if showDeleted { query.append(URLQueryItem(name: "showDeleted", value: "true")) }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components?.queryItems = query
            let data = try await managementRequest("GET", components?.url?.absoluteString ?? "")
            let page = try JSONDecoder().decode(Response.self, from: data)
            apps += page.apps ?? []
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while pageToken != nil
        return Self.uniqueApps(apps)
    }

    /// `searchApps` can return the same app more than once (e.g. on several pages); keep the first of each App ID.
    package static func uniqueApps(_ apps: [FirebaseAppSummary]) -> [FirebaseAppSummary] {
        var seen: Set<String> = []
        return apps.filter { seen.insert($0.appId).inserted }
    }

    /// Creates a Firebase App and waits for the long-running operation to finish.
    package func createApp(project: String, request: FirebaseAppCreateRequest) async throws -> FirebaseAppSummary {
        let url = "\(Self.managementBase)/projects/\(Self.encodeSegment(project))/\(request.platform.collection)"
        let body = try JSONSerialization.data(withJSONObject: request.body())
        let operation = try await managementRequest("POST", url, body: body)
        let response = try await waitForManagementOperation(operation)
        return try Self.parseCreatedApp(response, platform: request.platform)
    }

    /// Removes a Firebase App (`POST …/{iosApps|androidApps|webApps}/{appId}:remove`) and waits for the operation.
    /// Without `immediate`, the app can be restored for 30 days; `validateOnly` checks the request without removing.
    package func removeApp(project: String, platform: FirebaseAppPlatform, appId: String, immediate: Bool, validateOnly: Bool) async throws {
        let url = "\(Self.managementBase)/projects/\(Self.encodeSegment(project))/\(platform.collection)/\(Self.encodeSegment(appId)):remove"
        var body: [String: Any] = ["allowMissing": false]
        if immediate { body["immediate"] = true }
        if validateOnly { body["validateOnly"] = true }
        let operation = try await managementRequest("POST", url, body: try JSONSerialization.data(withJSONObject: body))
        _ = try await waitForManagementOperation(operation, requireResponse: false)
    }

    // MARK: - Android App SHA Certificates

    /// SHA certificate fingerprints registered on an Android app (`GET …/androidApps/{appId}/sha`).
    package func listShaCertificates(project: String, appId: String) async throws -> [FirebaseShaCertificate] {
        struct Response: Decodable { let certificates: [FirebaseShaCertificate]? }
        let data = try await managementRequest("GET", shaCollectionURL(project: project, appId: appId))
        return try JSONDecoder().decode(Response.self, from: data).certificates ?? []
    }

    /// Registers a SHA-1 or SHA-256 fingerprint on an Android app (`POST …/androidApps/{appId}/sha`).
    package func addShaCertificate(project: String, appId: String, hash: String, type: FirebaseShaCertificate.CertType) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["shaHash": FirebaseShaCertificate.normalize(hash), "certType": type.rawValue])
        _ = try await managementRequest("POST", shaCollectionURL(project: project, appId: appId), body: body)
    }

    /// Removes a registered fingerprint by its resource name (`DELETE v1beta1/{name}`).
    package func deleteShaCertificate(name: String) async throws {
        _ = try await managementRequest("DELETE", "\(Self.managementBase)/\(name)")
    }

    private func shaCollectionURL(project: String, appId: String) -> String {
        "\(Self.managementBase)/projects/\(Self.encodeSegment(project))/androidApps/\(Self.encodeSegment(appId))/sha"
    }

    /// Maps a created `IosApp` / `AndroidApp` / `WebApp` (an operation's `response`) to a summary.
    package static func parseCreatedApp(_ data: Data, platform: FirebaseAppPlatform) throws -> FirebaseAppSummary {
        struct App: Decodable {
            let appId: String?
            let displayName: String?
            let bundleId: String?
            let packageName: String?
            let webId: String?
            let state: String?
        }
        let app = try JSONDecoder().decode(App.self, from: data)
        guard let appId = app.appId, !appId.isEmpty else {
            throw FirebaseAppsError(status: nil, message: "The created app has no app ID in the API response.")
        }
        return FirebaseAppSummary(
            appId: appId,
            displayName: app.displayName,
            platform: platform.rawValue,
            namespace: app.bundleId ?? app.packageName ?? app.webId,
            state: app.state
        )
    }

    /// Polls `GET v1beta1/{operation}` until `done`, then returns the operation's `response` JSON.
    private func waitForManagementOperation(
        _ operationData: Data,
        requireResponse: Bool = true,
        maxAttempts: Int = 40,
        delaySeconds: UInt64 = 2
    ) async throws -> Data {
        var current = operationData
        for attempt in 1...maxAttempts {
            guard let json = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
                throw FirebaseAppsError(status: nil, message: "Unexpected operation response from the Firebase Management API.")
            }
            if (json["done"] as? Bool) == true {
                if let error = json["error"] as? [String: Any] {
                    let code = error["code"] as? Int
                    throw FirebaseAppsError(status: nil, message: "\(error["message"] as? String ?? "Operation failed")\(code.map { " (code \($0))" } ?? "")")
                }
                guard let response = json["response"] else {
                    if !requireResponse { return Data("{}".utf8) }
                    throw FirebaseAppsError(status: nil, message: "The operation finished without a response.")
                }
                return try JSONSerialization.data(withJSONObject: response)
            }
            guard let name = json["name"] as? String, !name.isEmpty else {
                throw FirebaseAppsError(status: nil, message: "The Firebase Management API returned an operation without a name.")
            }
            guard attempt < maxAttempts else { break }
            try await _Concurrency.Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            current = try await managementRequest("GET", "\(Self.managementBase)/\(name)")
        }
        throw FirebaseAppsError(status: nil, message: "Timed out waiting for Firebase to create the app; check the Firebase console.")
    }

    private func managementRequest(_ method: String, _ urlString: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw FirebaseAppsError(status: nil, message: "Invalid Firebase Management API URL: \(urlString)")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try await getAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FirebaseAppsError(status: nil, message: "Invalid HTTP response from \(url.path)")
        }
        guard (200...299).contains(http.statusCode) else {
            throw FirebaseAppsError(status: http.statusCode, message: Self.googleErrorMessage(data) ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    /// `error.message` of a Google API error body.
    package static func googleErrorMessage(_ data: Data) -> String? {
        struct Body: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error?.message
    }

    private static func encodeSegment(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:?#")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
