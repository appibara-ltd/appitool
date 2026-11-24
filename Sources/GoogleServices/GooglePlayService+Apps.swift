import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An app the service account can access (Play Developer Reporting API `App` resource).
package struct GooglePlayAccessibleApp: Codable, Sendable, Equatable {
    /// `apps/{app}`
    package var name: String?
    package var packageName: String?
    /// Title as set in Play Console (may not be reviewed / live yet).
    package var displayName: String?

    package init(name: String? = nil, packageName: String? = nil, displayName: String? = nil) {
        self.name = name
        self.packageName = packageName
        self.displayName = displayName
    }
}

extension GooglePlayService {
    // MARK: - Accessible Apps

    /// Lists every app accessible to the service account via the Play Developer Reporting API
    /// (`GET https://playdeveloperreporting.googleapis.com/v1beta1/apps:search`, all pages).
    ///
    /// Called over plain HTTP because the bundled Reporting API spec does not include `apps:search`. Requires the
    /// `playdeveloperreporting` scope (part of `GooglePlayAuthMiddleware.allScopes`) and the Play Developer Reporting API
    /// enabled in the service account's Google Cloud project.
    package func searchAccessibleApps() async throws -> [GooglePlayAccessibleApp] {
        struct Page: Decodable {
            let apps: [GooglePlayAccessibleApp]?
            let nextPageToken: String?
        }

        var apps: [GooglePlayAccessibleApp] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://playdeveloperreporting.googleapis.com/v1beta1/apps:search")!
            var query = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = query
            guard let url = components.url else {
                throw GooglePlayImageError.invalidResponse("Invalid apps:search URL.")
            }

            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "GET"
            request.setValue("Bearer \(try await getAccessToken())", forHTTPHeaderField: "Authorization")

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GooglePlayImageError.invalidResponse("Invalid HTTP response from apps:search.")
            }
            guard (200...299).contains(http.statusCode) else {
                let message = Self.parseGoogleErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                throw GooglePlayImageError.apiError(status: http.statusCode, message: message)
            }

            let page = try JSONDecoder().decode(Page.self, from: data)
            apps += page.apps ?? []
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
        } while pageToken != nil
        return apps
    }
}
