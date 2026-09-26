import Foundation
import FirebaseManagementAPI

/// Errors thrown by `GetFirebaseAppInfoTask`.
enum GetFirebaseAppInfoError: LocalizedError, Sendable {
    case missingAppId(platform: String)
    case unauthorized(String)
    case appNotFound(identifier: String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAppId(let platform):
            return "Missing Firebase App ID for \(platform). Provide --firebase-app-id or configure FIREBASE_\(platform.uppercased())_APP_ID in .env."
        case .unauthorized(let message):
            return "Firebase authorization failed: \(message)"
        case .appNotFound(let identifier):
            return "Firebase app not found for identifier: \(identifier)"
        case .apiError(let message):
            return "Firebase Management API request failed: \(message)"
        }
    }
}

/// A task that directly queries a single application by its App ID from the Firebase Management API
/// using OpenAPI generated schemas (`Components.Schemas.IosApp` or `Components.Schemas.AndroidApp`).
struct GetFirebaseAppInfoTask: Task {
    enum Platform: String, Sendable {
        case ios
        case android
    }

    struct Input: Sendable {
        let platform: Platform
        let firebaseAppId: String?

        init(platform: Platform, firebaseAppId: String? = nil) {
            self.platform = platform
            self.firebaseAppId = firebaseAppId
        }
    }

    enum Output: Sendable {
        case ios(Components.Schemas.IosApp)
        case android(Components.Schemas.AndroidApp)
    }

    init() {}

    @discardableResult
    func run(_ input: Input) async throws -> Output {
        guard let service = try FirebaseService.makeService() else {
            throw GetFirebaseAppInfoError.unauthorized("Missing Firebase credentials. Provide GOOGLE_KEY, GOOGLE_APPLICATION_CREDENTIALS, or FIREBASE_TOKEN in .env.")
        }

        switch input.platform {
        case .ios:
            let app = try await fetchIOSAppInfo(appId: input.firebaseAppId, service: service)
            return .ios(app)
        case .android:
            let app = try await fetchAndroidAppInfo(appId: input.firebaseAppId, service: service)
            return .android(app)
        }
    }

    // MARK: - Direct Single iOS App Fetch

    private func fetchIOSAppInfo(appId: String?, service: FirebaseService) async throws -> Components.Schemas.IosApp {
        let env = ProcessInfo.processInfo.environment
        guard let resolvedAppId = appId ?? env["FIREBASE_IOS_APP_ID"], !resolvedAppId.isEmpty else {
            throw GetFirebaseAppInfoError.missingAppId(platform: "iOS")
        }

        let projectNumber = extractProjectNumber(from: resolvedAppId)
        let response = try await service.management.firebase_period_projects_period_iosApps_period_get(.init(
            path: .init(projectsId: projectNumber, iosAppId: resolvedAppId)
        ))

        switch response {
        case .ok(let okResponse):
            guard case .json(let app) = okResponse.body else {
                throw GetFirebaseAppInfoError.apiError("Failed to decode JSON response for iOS App ID: \(resolvedAppId)")
            }
            return app

        case .undocumented(let statusCode, _):
            if statusCode == 404 {
                throw GetFirebaseAppInfoError.appNotFound(identifier: resolvedAppId)
            }
            throw GetFirebaseAppInfoError.apiError("Firebase API returned HTTP \(statusCode)")
        }
    }

    // MARK: - Direct Single Android App Fetch

    private func fetchAndroidAppInfo(appId: String?, service: FirebaseService) async throws -> Components.Schemas.AndroidApp {
        let env = ProcessInfo.processInfo.environment
        guard let resolvedAppId = appId ?? env["FIREBASE_ANDROID_APP_ID"], !resolvedAppId.isEmpty else {
            throw GetFirebaseAppInfoError.missingAppId(platform: "Android")
        }

        let projectNumber = extractProjectNumber(from: resolvedAppId)
        let response = try await service.management.firebase_period_projects_period_androidApps_period_get(.init(
            path: .init(projectsId: projectNumber, androidAppId: resolvedAppId)
        ))

        switch response {
        case .ok(let okResponse):
            guard case .json(let app) = okResponse.body else {
                throw GetFirebaseAppInfoError.apiError("Failed to decode JSON response for Android App ID: \(resolvedAppId)")
            }
            return app

        case .undocumented(let statusCode, _):
            if statusCode == 404 {
                throw GetFirebaseAppInfoError.appNotFound(identifier: resolvedAppId)
            }
            throw GetFirebaseAppInfoError.apiError("Firebase API returned HTTP \(statusCode)")
        }
    }

    private func extractProjectNumber(from appId: String) -> String {
        let segments = appId.split(separator: ":")
        return segments.count >= 2 ? String(segments[1]) : "-"
    }
}
