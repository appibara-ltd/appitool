import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Play Console user of a developer account (`developers/{developer}/users/{email}`).
package struct GooglePlayUser: Codable, Sendable, Equatable {
    package var name: String?
    package var email: String?
    package var accessState: String?
    package var developerAccountPermissions: [String]?
    package var expirationTime: String?
    package var grants: [GooglePlayGrant]?

    package init(
        name: String? = nil,
        email: String? = nil,
        accessState: String? = nil,
        developerAccountPermissions: [String]? = nil,
        expirationTime: String? = nil,
        grants: [GooglePlayGrant]? = nil
    ) {
        self.name = name
        self.email = email
        self.accessState = accessState
        self.developerAccountPermissions = developerAccountPermissions
        self.expirationTime = expirationTime
        self.grants = grants
    }

    /// `true` while the user has not accepted the invitation yet (or it expired).
    package var isInvitation: Bool {
        accessState == "INVITED" || accessState == "INVITATION_EXPIRED"
    }
}

/// Per-app permissions of a user (`developers/{developer}/users/{email}/grants/{package}`).
package struct GooglePlayGrant: Codable, Sendable, Equatable {
    package var name: String?
    package var packageName: String?
    package var appLevelPermissions: [String]?

    package init(name: String? = nil, packageName: String? = nil, appLevelPermissions: [String]? = nil) {
        self.name = name
        self.packageName = packageName
        self.appLevelPermissions = appLevelPermissions
    }
}

/// Play Console permission identifiers: the spec's values plus ones the live API returns that the spec lacks
/// (`CAN_VIEW_NON_FINANCIAL_DATA*`, `CAN_VIEW_APP_QUALITY*`, `CAN_MANAGE_DEEPLINKS*`, `CAN_*_CONNECTED_APPS_GLOBAL`).
package enum GooglePlayPermissions {
    package static let developerLevel: [String] = [
        "CAN_SEE_ALL_APPS", "CAN_VIEW_FINANCIAL_DATA_GLOBAL", "CAN_MANAGE_PERMISSIONS_GLOBAL", "CAN_EDIT_GAMES_GLOBAL",
        "CAN_PUBLISH_GAMES_GLOBAL", "CAN_REPLY_TO_REVIEWS_GLOBAL", "CAN_MANAGE_PUBLIC_APKS_GLOBAL", "CAN_MANAGE_TRACK_APKS_GLOBAL",
        "CAN_MANAGE_TRACK_USERS_GLOBAL", "CAN_MANAGE_PUBLIC_LISTING_GLOBAL", "CAN_MANAGE_DRAFT_APPS_GLOBAL",
        "CAN_CREATE_MANAGED_PLAY_APPS_GLOBAL", "CAN_CHANGE_MANAGED_PLAY_SETTING_GLOBAL", "CAN_MANAGE_ORDERS_GLOBAL",
        "CAN_MANAGE_APP_CONTENT_GLOBAL", "CAN_VIEW_NON_FINANCIAL_DATA_GLOBAL", "CAN_VIEW_APP_QUALITY_GLOBAL",
        "CAN_MANAGE_DEEPLINKS_GLOBAL", "CAN_VIEW_CONNECTED_APPS_GLOBAL", "CAN_EDIT_CONNECTED_APPS_GLOBAL",
    ]

    package static let appLevel: [String] = [
        "CAN_ACCESS_APP", "CAN_VIEW_FINANCIAL_DATA", "CAN_MANAGE_PERMISSIONS", "CAN_REPLY_TO_REVIEWS", "CAN_MANAGE_PUBLIC_APKS",
        "CAN_MANAGE_TRACK_APKS", "CAN_MANAGE_TRACK_USERS", "CAN_MANAGE_PUBLIC_LISTING", "CAN_MANAGE_DRAFT_APPS",
        "CAN_MANAGE_ORDERS", "CAN_MANAGE_APP_CONTENT", "CAN_VIEW_NON_FINANCIAL_DATA", "CAN_VIEW_APP_QUALITY",
        "CAN_MANAGE_DEEPLINKS",
    ]

    /// Normalizes `can-reply-to-reviews` / `CAN_REPLY_TO_REVIEWS` style input. Developer-level names may omit `_GLOBAL`.
    package static func parse(_ raw: [String], developerLevel: Bool) throws -> [String] {
        let valid = developerLevel ? self.developerLevel : appLevel
        return try raw.map { item in
            let upper = item.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "_")
            if valid.contains(upper) { return upper }
            if developerLevel, valid.contains(upper + "_GLOBAL") { return upper + "_GLOBAL" }
            throw GooglePlayImageError.invalidResponse(
                "Unknown \(developerLevel ? "developer-level" : "app-level") permission '\(item)'. Valid: \(valid.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") }.joined(separator: ", "))."
            )
        }
    }
}

extension GooglePlayService {
    // MARK: - Users & Grants
    //
    // Called over plain HTTP: the resource names contain slashes (`developers/{id}/users/{email}`), which the generated
    // client would percent-encode, and the spec merges these operations into a generic `{name}` path.

    private static let usersBaseURL = "https://androidpublisher.googleapis.com/androidpublisher/v3"

    private static func userPath(developerId: String, email: String) -> String {
        "developers/\(encodePathSegment(developerId))/users/\(encodePathSegment(email))"
    }

    /// Users list page size: the API currently rejects paging ("page_size parameter must be set to -1").
    static let usersPageSize = "-1"

    /// Lists all users of a developer account (follows `nextPageToken` should Google enable paging later).
    package func listUsers(developerId: String) async throws -> [GooglePlayUser] {
        struct Page: Decodable {
            let users: [GooglePlayUser]?
            let nextPageToken: String?
        }
        var users: [GooglePlayUser] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: Self.usersPageSize)]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await usersRequest(
                method: "GET",
                path: "developers/\(Self.encodePathSegment(developerId))/users",
                query: query,
                body: nil as GooglePlayUser?
            )
            let page = try JSONDecoder().decode(Page.self, from: data)
            users += page.users ?? []
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
        } while pageToken != nil
        return users
    }

    /// Invites a user to the developer account.
    @discardableResult
    package func createUser(developerId: String, email: String, permissions: [String], expirationTime: String?) async throws -> GooglePlayUser {
        let body = GooglePlayUser(email: email, developerAccountPermissions: permissions, expirationTime: expirationTime)
        let data = try await usersRequest(
            method: "POST",
            path: "developers/\(Self.encodePathSegment(developerId))/users",
            body: body
        )
        return try JSONDecoder().decode(GooglePlayUser.self, from: data)
    }

    /// Updates developer-level permissions and/or the expiration time (only fields passed are changed).
    @discardableResult
    package func updateUser(developerId: String, email: String, permissions: [String]?, expirationTime: String?) async throws -> GooglePlayUser {
        var mask: [String] = []
        var body = GooglePlayUser()
        if let permissions {
            mask.append("developerAccountPermissions")
            body.developerAccountPermissions = permissions
        }
        if let expirationTime {
            mask.append("expirationTime")
            body.expirationTime = expirationTime
        }
        let data = try await usersRequest(
            method: "PATCH",
            path: Self.userPath(developerId: developerId, email: email),
            query: [URLQueryItem(name: "updateMask", value: mask.joined(separator: ","))],
            body: body
        )
        return try JSONDecoder().decode(GooglePlayUser.self, from: data)
    }

    /// Removes a user (or a pending invitation) from the developer account.
    package func deleteUser(developerId: String, email: String) async throws {
        _ = try await usersRequest(method: "DELETE", path: Self.userPath(developerId: developerId, email: email), body: nil as GooglePlayUser?)
    }

    /// Grants app-level permissions to a user for one app.
    @discardableResult
    package func createGrant(developerId: String, email: String, packageName: String, permissions: [String]) async throws -> GooglePlayGrant {
        let data = try await usersRequest(
            method: "POST",
            path: Self.userPath(developerId: developerId, email: email) + "/grants",
            body: GooglePlayGrant(packageName: packageName, appLevelPermissions: permissions)
        )
        return try JSONDecoder().decode(GooglePlayGrant.self, from: data)
    }

    /// Replaces the app-level permissions of an existing grant.
    @discardableResult
    package func updateGrant(developerId: String, email: String, packageName: String, permissions: [String]) async throws -> GooglePlayGrant {
        let data = try await usersRequest(
            method: "PATCH",
            path: Self.userPath(developerId: developerId, email: email) + "/grants/\(Self.encodePathSegment(packageName))",
            query: [URLQueryItem(name: "updateMask", value: "appLevelPermissions")],
            body: GooglePlayGrant(appLevelPermissions: permissions)
        )
        return try JSONDecoder().decode(GooglePlayGrant.self, from: data)
    }

    /// Removes a user's access to one app.
    package func deleteGrant(developerId: String, email: String, packageName: String) async throws {
        _ = try await usersRequest(
            method: "DELETE",
            path: Self.userPath(developerId: developerId, email: email) + "/grants/\(Self.encodePathSegment(packageName))",
            body: nil as GooglePlayGrant?
        )
    }

    /// Sends an authenticated JSON request to the Play Developer API and returns the response body.
    private func usersRequest<Body: Encodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Data {
        guard var components = URLComponents(string: "\(Self.usersBaseURL)/\(path)") else {
            throw GooglePlayImageError.invalidResponse("Invalid Play Developer API path: \(path)")
        }
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))))
            }
        }
        guard let url = components.url else {
            throw GooglePlayImageError.invalidResponse("Invalid Play Developer API URL for \(path)")
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try await getAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GooglePlayImageError.invalidResponse("Invalid HTTP response from \(path)")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.parseGoogleErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw GooglePlayImageError.apiError(status: http.statusCode, message: message)
        }
        return data
    }
}
