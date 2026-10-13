import Foundation
import HTTPTypes
import OpenAPIRuntime
import AppStoreConnectAPI

/// A `ClientMiddleware` that intercepts HTTP responses from App Store Connect API
/// and throws `AppStoreServiceError.apiError` for error status codes (>= 400),
/// parsing Apple's standard `ErrorResponse` payload.
package struct AppStoreErrorMiddleware: ClientMiddleware, Sendable {

    package init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)

        let statusCode = response.status.code
        // Status codes in the 2xx or 3xx range, or specific allowed codes (e.g. 404 for delete endpoints handled upstream)
        // Note: For operations like `deleteBundleId`, `deleteCertificate`, `deleteProfile`, Apple returns 404 if not found,
        // which the calling methods inspect to return `false`. Also `profiles_createInstance` inspects 409 Conflict to retry.
        // Therefore, we pass 404 and 409 through for operations where they are expected and handled,
        // OR we allow the caller to handle them, or only intercept client & server errors that shouldn't be silently handled.
        // However, to make all standard error switches uniform, if statusCode >= 400:
        // We buffer the body so it can be both inspected or re-emitted if needed.
        guard statusCode >= 400 else {
            return (response, responseBody)
        }

        // Allow 404 (Not Found) for delete/get checks if needed, or 409 (Conflict) for profile creation retry:
        if statusCode == 404 && operationID.contains("delete") {
            return (response, responseBody)
        }
        if statusCode == 409 && operationID == "profiles_createInstance" {
            return (response, responseBody)
        }

        var errorData: Data = Data()
        if let responseBody {
            errorData = try await Data(collecting: responseBody, upTo: 1024 * 1024)
        }

        let decodedErrors = try? JSONDecoder().decode(Components.Schemas.ErrorResponse.self, from: errorData)
        let message = AppStoreService.formatAppleErrors(decodedErrors?.errors)

        throw AppStoreServiceError.apiError(status: statusCode, message: message)
    }
}
