import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import FirebaseManagementAPI

/// Model representing a release in Firebase App Distribution.
package struct FirebaseAppDistributionRelease: Codable, Sendable {
    package let name: String?
    package let releaseNotes: ReleaseNotes?
    package let displayVersion: String?
    package let buildVersion: String?
    package let createTime: String?
    package let firebaseConsoleUri: String?
    package let testingUri: String?
    package let binaryDownloadUri: String?

    package struct ReleaseNotes: Codable, Sendable {
        package let text: String?

        package init(text: String? = nil) {
            self.text = text
        }
    }

    package init(
        name: String? = nil,
        releaseNotes: ReleaseNotes? = nil,
        displayVersion: String? = nil,
        buildVersion: String? = nil,
        createTime: String? = nil,
        firebaseConsoleUri: String? = nil,
        testingUri: String? = nil,
        binaryDownloadUri: String? = nil
    ) {
        self.name = name
        self.releaseNotes = releaseNotes
        self.displayVersion = displayVersion
        self.buildVersion = buildVersion
        self.createTime = createTime
        self.firebaseConsoleUri = firebaseConsoleUri
        self.testingUri = testingUri
        self.binaryDownloadUri = binaryDownloadUri
    }
}

/// Model representing a tester group in Firebase App Distribution.
package struct FirebaseAppDistributionGroup: Codable, Sendable {
    package let name: String?
    package let displayName: String?
    package let testerCount: Int?
    package let releaseCount: Int?
    package let inviteLinkCount: Int?

    package init(
        name: String? = nil,
        displayName: String? = nil,
        testerCount: Int? = nil,
        releaseCount: Int? = nil,
        inviteLinkCount: Int? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.testerCount = testerCount
        self.releaseCount = releaseCount
        self.inviteLinkCount = inviteLinkCount
    }
}

/// Unified service providing access to Firebase APIs:
/// - `management`: Firebase Management API (listing iOS/Android apps, retrieving bundle IDs, package names, metadata)
/// - App Distribution operations: binary upload, release listing/fetching, release notes, and distribution
package struct FirebaseService: Sendable {
    package static let sharedTransport = URLSessionTransport()

    /// The OpenAPI client for the Firebase Management API (firebase v1beta1).
    package let management: FirebaseManagementAPI.Client

    /// Middleware that unescapes `%2F` in request paths.
    /// Google Cloud AIP APIs use multi-segment resource names (e.g. `projects/123/apps/456`),
    /// which OpenAPI 3.0 path parameters percent-encode as `%2F`, causing Google servers to return 404.
    private struct PathUnescapeMiddleware: ClientMiddleware {
        func intercept(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String,
            next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
        ) async throws -> (HTTPResponse, HTTPBody?) {
            var req = request
            if let path = req.path {
                req.path = path.replacingOccurrences(of: "%2F", with: "/").replacingOccurrences(of: "%2f", with: "/")
            }
            return try await next(req, body, baseURL)
        }
    }

    package let authMiddleware: any ClientMiddleware

    package init(
        authMiddleware: any ClientMiddleware,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        self.authMiddleware = authMiddleware
        let unescapeMiddleware = PathUnescapeMiddleware()
        let middlewares: [any ClientMiddleware] = [unescapeMiddleware, authMiddleware]

        self.management = FirebaseManagementAPI.Client(
            serverURL: try FirebaseManagementAPI.Servers.Server1.url(),
            transport: transport,
            middlewares: middlewares
        )
    }

    /// Retrieves an OAuth 2.0 access token using the underlying GooglePlayAuthMiddleware if available.
    package func getAccessToken() async throws -> String {
        if let googleAuth = authMiddleware as? GooglePlayAuthMiddleware {
            return try await googleAuth.getAccessToken()
        }
        throw NSError(
            domain: "FirebaseService",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Authentication middleware does not support direct token retrieval."]
        )
    }

    /// Initializes `FirebaseService` using a Google Cloud Service Account key (file path, raw JSON, or Base64 string).
    package init(
        key: String,
        transport: any ClientTransport = Self.sharedTransport,
        urlSession: URLSession = .shared
    ) throws {
        let authMiddleware = try GooglePlayAuthMiddleware(
            key: key,
            scope: "https://www.googleapis.com/auth/cloud-platform",
            urlSession: urlSession
        )
        try self.init(authMiddleware: authMiddleware, transport: transport)
    }

    /// Instantiates `FirebaseService` using an explicitly provided Google Cloud Service Account key (`googleKey`).
    package static func makeService(googleKey: String? = nil) throws -> FirebaseService? {
        if let googleKey, !googleKey.isEmpty {
            return try FirebaseService(key: googleKey)
        }
        return nil
    }

    // MARK: - App Distribution Operations

    /// Uploads an APK, AAB, or IPA binary to Firebase App Distribution and waits until the release is processed.
    ///
    /// - Parameters:
    ///   - fileUrl: The local file URL of the binary to upload.
    ///   - firebaseAppId: The Firebase App ID (format: `1:1234567890:ios:abcdef...`).
    /// - Returns: The created or updated `FirebaseAppDistributionRelease` model.
    package func upload(
        fileUrl: URL,
        firebaseAppId: String
    ) async throws -> FirebaseAppDistributionRelease {
        let segments = firebaseAppId.split(separator: ":")
        let projectNumber = segments.count >= 2 ? String(segments[1]) : "-"
        let appResourceName = "projects/\(projectNumber)/apps/\(firebaseAppId)"

        let token = try await getAccessToken()
        let uploadEndpoint = "https://firebaseappdistribution.googleapis.com/upload/v1/\(appResourceName)/releases:upload"

        guard let url = URL(string: uploadEndpoint) else {
            throw NSError(
                domain: "FirebaseService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL: \(uploadEndpoint)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(fileUrl.lastPathComponent, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileUrl)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received during binary upload."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown upload error"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Upload failed with HTTP \(httpResponse.statusCode): \(errorMsg)"]
            )
        }

        // Decode operation name from GoogleLongrunningOperation response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opName = json["name"] as? String else {
            throw NSError(
                domain: "FirebaseService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse operation name from upload response."]
            )
        }

        return try await waitForRelease(operationName: opName)
    }

    /// Waits for a long-running release upload operation to complete.
    package func waitForRelease(
        operationName: String,
        maxRetries: Int = 30,
        delaySeconds: UInt64 = 3
    ) async throws -> FirebaseAppDistributionRelease {
        let token = try await getAccessToken()
        let opUrlString = "https://firebaseappdistribution.googleapis.com/v1/\(operationName)"

        guard let opUrl = URL(string: opUrlString) else {
            throw NSError(
                domain: "FirebaseService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid operation status URL: \(opUrlString)"]
            )
        }

        var request = URLRequest(url: opUrl)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for attempt in 1...maxRetries {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "FirebaseService",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while polling operation."]
                )
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw NSError(
                    domain: "FirebaseService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Operation polling failed (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
                )
            }

            // Parse raw JSON
            guard let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(
                    domain: "FirebaseService",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response from operation."]
                )
            }

            let isDone = (jsonDict["done"] as? Bool) == true
            if isDone {
                if let errorDict = jsonDict["error"] as? [String: Any] {
                    let errMsg = errorDict["message"] as? String ?? "Unknown error"
                    throw NSError(
                        domain: "FirebaseService",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Firebase processing operation failed: \(errMsg)"]
                    )
                }

                if let responseDict = jsonDict["response"] as? [String: Any],
                   let releaseDict = responseDict["release"] as? [String: Any] {
                    let releaseData = try JSONSerialization.data(withJSONObject: releaseDict)
                    let release = try JSONDecoder().decode(FirebaseAppDistributionRelease.self, from: releaseData)
                    return release
                }

                throw NSError(
                    domain: "FirebaseService",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Operation marked done but no release found in response."]
                )
            }

            if attempt < maxRetries {
                try await _Concurrency.Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }

        throw NSError(
            domain: "FirebaseService",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Firebase processing of operation: \(operationName)"]
        )
    }

    /// Lists releases for a Firebase app.
    ///
    /// - Parameters:
    ///   - firebaseAppId: The Firebase App ID (format: `1:1234567890:ios:abcdef...`).
    ///   - pageSize: Optional maximum number of releases to return (1-100).
    ///   - pageToken: Optional pagination token.
    ///   - orderBy: Optional sorting order (e.g. "createTime desc").
    /// - Returns: A tuple containing the array of `FirebaseAppDistributionRelease` and optional next page token.
    package func listReleases(
        firebaseAppId: String,
        pageSize: Int? = nil,
        pageToken: String? = nil,
        orderBy: String? = nil
    ) async throws -> (releases: [FirebaseAppDistributionRelease], nextPageToken: String?) {
        let segments = firebaseAppId.split(separator: ":")
        let projectNumber = segments.count >= 2 ? String(segments[1]) : "-"
        let appResourceName = "projects/\(projectNumber)/apps/\(firebaseAppId)"

        var urlComponents = URLComponents(string: "https://firebaseappdistribution.googleapis.com/v1/\(appResourceName)/releases")!
        var queryItems: [URLQueryItem] = []
        if let pageSize {
            queryItems.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
        }
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "orderBy", value: orderBy))
        }
        if !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw NSError(
                domain: "FirebaseService",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct releases URL."]
            )
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while listing releases."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to list releases (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        struct ListReleasesResponse: Codable {
            let releases: [FirebaseAppDistributionRelease]?
            let nextPageToken: String?
        }

        let decoded = try JSONDecoder().decode(ListReleasesResponse.self, from: data)
        return (decoded.releases ?? [], decoded.nextPageToken)
    }

    /// Retrieves a specific release by its full resource name or Firebase App ID and Release ID.
    ///
    /// - Parameter releaseName: The full release resource name (format: `projects/{project_number}/apps/{app_id}/releases/{release_id}`).
    /// - Returns: The retrieved `FirebaseAppDistributionRelease`.
    package func getRelease(
        releaseName: String
    ) async throws -> FirebaseAppDistributionRelease {
        guard let url = URL(string: "https://firebaseappdistribution.googleapis.com/v1/\(releaseName)") else {
            throw NSError(
                domain: "FirebaseService",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Invalid release URL for name: \(releaseName)"]
            )
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while retrieving release."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get release (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        return try JSONDecoder().decode(FirebaseAppDistributionRelease.self, from: data)
    }

    /// Adds or updates release notes on a specific release resource.
    ///
    /// - Parameters:
    ///   - releaseName: The full release resource name (format: `projects/{project_number}/apps/{app_id}/releases/{release_id}`).
    ///   - releaseNotes: The text content of the release notes.
    package func addReleaseNotes(
        releaseName: String,
        releaseNotes: String
    ) async throws {
        let token = try await getAccessToken()
        let patchEndpoint = "https://firebaseappdistribution.googleapis.com/v1/\(releaseName)?updateMask=releaseNotes.text"

        guard let url = URL(string: patchEndpoint) else {
            throw NSError(
                domain: "FirebaseService",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Invalid patch URL: \(patchEndpoint)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = [
            "releaseNotes": [
                "text": releaseNotes
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while updating release notes."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to update release notes (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }
    }

    /// Distributes a release to tester groups and/or individual tester emails.
    ///
    /// - Parameters:
    ///   - releaseName: The full release resource name (format: `projects/{project_number}/apps/{app_id}/releases/{release_id}`).
    ///   - groupAliases: Optional list of group aliases/IDs.
    ///   - testerEmails: Optional list of tester email addresses.
    package func distribute(
        releaseName: String,
        groupAliases: [String]? = nil,
        testerEmails: [String]? = nil
    ) async throws {
        let token = try await getAccessToken()
        let endpoint = "https://firebaseappdistribution.googleapis.com/v1/\(releaseName):distribute"

        guard let url = URL(string: endpoint) else {
            throw NSError(
                domain: "FirebaseService",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Invalid distribute URL: \(endpoint)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var bodyDict: [String: Any] = [:]
        if let groupAliases, !groupAliases.isEmpty {
            bodyDict["groupAliases"] = groupAliases
        }
        if let testerEmails, !testerEmails.isEmpty {
            bodyDict["testerEmails"] = testerEmails
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while distributing release."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to distribute release (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }
    }

    // MARK: - Tester Groups Operations

    private func extractProjectNumber(from project: String) -> String {
        if project.contains(":") {
            let segments = project.split(separator: ":")
            return segments.count >= 2 ? String(segments[1]) : project
        }
        return project
    }

    /// Lists tester groups for a project.
    ///
    /// - Parameters:
    ///   - project: Project number, ID, or Firebase App ID.
    ///   - pageSize: Optional page size (1-1000).
    ///   - pageToken: Optional pagination token.
    /// - Returns: A tuple containing the list of groups and optional next page token.
    package func listGroups(
        project: String,
        pageSize: Int? = nil,
        pageToken: String? = nil
    ) async throws -> (groups: [FirebaseAppDistributionGroup], nextPageToken: String?) {
        let projectNumber = extractProjectNumber(from: project)
        var urlComponents = URLComponents(string: "https://firebaseappdistribution.googleapis.com/v1/projects/\(projectNumber)/groups")!
        var queryItems: [URLQueryItem] = []
        if let pageSize {
            queryItems.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
        }
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw NSError(
                domain: "FirebaseService",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "Invalid list groups URL."]
            )
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while listing groups."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to list groups (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        struct ListGroupsResponse: Codable {
            let groups: [FirebaseAppDistributionGroup]?
            let nextPageToken: String?
        }

        let decoded = try JSONDecoder().decode(ListGroupsResponse.self, from: data)
        return (decoded.groups ?? [], decoded.nextPageToken)
    }

    /// Retrieves a specific tester group by project number/ID and group alias.
    ///
    /// - Parameters:
    ///   - project: Project number, ID, or Firebase App ID.
    ///   - groupAlias: The alias/ID of the group.
    /// - Returns: The retrieved `FirebaseAppDistributionGroup`, or `nil` if not found (HTTP 404).
    package func getGroup(
        project: String,
        groupAlias: String
    ) async throws -> FirebaseAppDistributionGroup? {
        let projectNumber = extractProjectNumber(from: project)
        let endpoint = "https://firebaseappdistribution.googleapis.com/v1/projects/\(projectNumber)/groups/\(groupAlias)"
        guard let url = URL(string: endpoint) else {
            throw NSError(
                domain: "FirebaseService",
                code: 18,
                userInfo: [NSLocalizedDescriptionKey: "Invalid group URL: \(endpoint)"]
            )
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while retrieving group."]
            )
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get group (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        return try JSONDecoder().decode(FirebaseAppDistributionGroup.self, from: data)
    }

    /// Creates a new tester group or returns the existing group if it already exists.
    ///
    /// - Parameters:
    ///   - project: Project number or project ID. If a Firebase App ID is passed (e.g. `1:1234567890:ios:...`), the project number will automatically be extracted.
    ///   - groupAlias: Unique identifier/alias for the group (e.g., `internal`, `qa-team`).
    ///   - displayName: Human-readable display name for the group (defaults to `groupAlias` if omitted).
    /// - Returns: The created or existing `FirebaseAppDistributionGroup`.
    package func createOrGetGroup(
        project: String,
        groupAlias: String,
        displayName: String? = nil
    ) async throws -> FirebaseAppDistributionGroup {
        let projectNumber = extractProjectNumber(from: project)
        let display = displayName ?? groupAlias

        // 1. Check if group exists directly via getGroup
        if let existing = try? await getGroup(project: projectNumber, groupAlias: groupAlias) {
            return existing
        }

        // 2. Also check in listGroups matching by alias or displayName (case-insensitive)
        if let (groups, _) = try? await listGroups(project: projectNumber, pageSize: 100) {
            if let matched = groups.first(where: {
                let aliasMatch = $0.name?.components(separatedBy: "/").last?.lowercased() == groupAlias.lowercased()
                let displayMatch = $0.displayName?.lowercased() == display.lowercased()
                return aliasMatch || displayMatch
            }) {
                return matched
            }
        }

        // 3. Format valid groupId: must be 4-63 lowercase alphanumeric or hyphens
        let cleanGroupId = groupAlias.lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        var urlString = "https://firebaseappdistribution.googleapis.com/v1/projects/\(projectNumber)/groups"
        if cleanGroupId.count >= 4 && cleanGroupId.count <= 63 {
            urlString += "?groupId=\(cleanGroupId)"
        }

        guard let url = URL(string: urlString) else {
            throw NSError(
                domain: "FirebaseService",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Invalid create group URL: \(urlString)"]
            )
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = [
            "displayName": display
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while creating group."]
            )
        }

        // If HTTP 409 Conflict (already exists), re-check getGroup
        if httpResponse.statusCode == 409 {
            if let existingGroup = try await getGroup(project: projectNumber, groupAlias: cleanGroupId) {
                return existingGroup
            }
            return FirebaseAppDistributionGroup(
                name: "projects/\(projectNumber)/groups/\(cleanGroupId)",
                displayName: display
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create group (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        return try JSONDecoder().decode(FirebaseAppDistributionGroup.self, from: data)
    }

    // MARK: - Firebase Authentication (Identity Toolkit API)

    /// Returns the `project_id` embedded in the underlying Google Service Account key, if available.
    package var serviceAccountProjectId: String? {
        (authMiddleware as? GooglePlayAuthMiddleware)?.projectId
    }

    /// Lists Firebase Authentication users in batches via Google Identity Toolkit v1 API.
    ///
    /// - Parameters:
    ///   - project: Firebase project ID or project number.
    ///   - maxResults: Maximum number of users to fetch per page (1-1000; defaults to 500).
    ///   - pageToken: Optional pagination token (`nextPageToken`).
    /// - Returns: A tuple containing the array of `FirebaseAuthUser` and optional `nextPageToken`.
    package func listAuthUsers(
        project: String,
        maxResults: Int = 500,
        pageToken: String? = nil
    ) async throws -> (users: [FirebaseAuthUser], nextPageToken: String?) {
        let clampedMax = max(1, min(maxResults, 1000))
        var urlComponents = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/projects/\(project)/accounts:batchGet")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "maxResults", value: String(clampedMax))
        ]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "nextPageToken", value: pageToken))
        }
        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            throw NSError(
                domain: "FirebaseService",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Identity Toolkit batchGet URL."]
            )
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while listing Firebase Auth users."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to list Firebase Auth users (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        struct BatchGetResponse: Codable {
            let users: [FirebaseAuthUser]?
            let nextPageToken: String?
        }

        let decoded = try JSONDecoder().decode(BatchGetResponse.self, from: data)
        return (decoded.users ?? [], decoded.nextPageToken)
    }

    /// Looks up specific Firebase Authentication users by exact email or UID (`localId`).
    ///
    /// - Parameters:
    ///   - project: Firebase project ID or project number.
    ///   - emails: Optional array of email addresses to look up.
    ///   - uids: Optional array of UIDs (`localId`) to look up.
    /// - Returns: Array of matching `FirebaseAuthUser` records.
    package func lookupAuthUsers(
        project: String,
        emails: [String]? = nil,
        uids: [String]? = nil
    ) async throws -> [FirebaseAuthUser] {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/projects/\(project)/accounts:lookup") else {
            throw NSError(
                domain: "FirebaseService",
                code: 24,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Identity Toolkit lookup URL."]
            )
        }

        var bodyDict: [String: Any] = [:]
        if let emails, !emails.isEmpty {
            bodyDict["email"] = emails
        }
        if let uids, !uids.isEmpty {
            bodyDict["localId"] = uids
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 25,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while looking up Firebase Auth users."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to look up Firebase Auth users (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        struct LookupResponse: Codable {
            let users: [FirebaseAuthUser]?
        }

        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        return decoded.users ?? []
    }

    /// Deletes a single Firebase Authentication user by UID (`localId`).
    ///
    /// - Parameters:
    ///   - project: Firebase project ID or project number.
    ///   - uid: The `localId` (UID) of the user to delete.
    package func deleteAuthUser(
        project: String,
        uid: String
    ) async throws {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/projects/\(project)/accounts:delete") else {
            throw NSError(
                domain: "FirebaseService",
                code: 26,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Identity Toolkit delete URL."]
            )
        }

        let bodyDict: [String: Any] = [
            "localId": uid
        ]

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 27,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while deleting Firebase Auth user."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to delete Firebase Auth user (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }
    }

    /// Deletes multiple Firebase Authentication users in batch by UIDs (`localId`).
    ///
    /// - Parameters:
    ///   - project: Firebase project ID or project number.
    ///   - uids: Array of `localId` (UID) strings to delete (up to 1000 per call).
    ///   - force: Whether to force-delete accounts even if not disabled (defaults to `true`).
    /// - Returns: An array of error messages for any accounts that failed to delete.
    package func deleteAuthUsers(
        project: String,
        uids: [String],
        force: Bool = true
    ) async throws -> [String] {
        guard !uids.isEmpty else { return [] }
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/projects/\(project)/accounts:batchDelete") else {
            throw NSError(
                domain: "FirebaseService",
                code: 28,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Identity Toolkit batchDelete URL."]
            )
        }

        let bodyDict: [String: Any] = [
            "localIds": uids,
            "force": force
        ]

        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FirebaseService",
                code: 29,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response received while batch deleting Firebase Auth users."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "FirebaseService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to batch delete Firebase Auth users (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        struct BatchDeleteResponse: Codable {
            struct ErrorInfo: Codable {
                let index: Int?
                let message: String?
            }
            let errors: [ErrorInfo]?
        }

        if let decoded = try? JSONDecoder().decode(BatchDeleteResponse.self, from: data),
           let errors = decoded.errors, !errors.isEmpty {
            return errors.compactMap { err in
                if let idx = err.index, idx < uids.count {
                    return "UID \(uids[idx]): \(err.message ?? "Unknown error")"
                }
                return err.message
            }
        }

        return []
    }
}

/// Model representing a user in Firebase Authentication (Identity Toolkit).
package struct FirebaseAuthUser: Codable, Sendable {
    package let localId: String
    package let email: String?
    package let emailVerified: Bool?
    package let displayName: String?
    package let phoneNumber: String?
    package let photoUrl: String?
    package let disabled: Bool?
    package let createdAt: String?
    package let lastLoginAt: String?
    package let providerUserInfo: [ProviderUserInfo]?

    package struct ProviderUserInfo: Codable, Sendable {
        package let providerId: String?
        package let displayName: String?
        package let email: String?
        package let federatedId: String?
        package let rawId: String?
    }

    /// Returns `true` if the user is an anonymous Firebase Auth user (no email, phone number, or linked identity providers).
    package var isAnonymous: Bool {
        let hasEmail = (email?.isEmpty == false)
        let hasPhone = (phoneNumber?.isEmpty == false)
        let hasProviders = (providerUserInfo?.isEmpty == false)
        return !hasEmail && !hasPhone && !hasProviders
    }
}


