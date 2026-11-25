import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Default `URLSession` for direct HTTP calls made outside the store services (notifications, self-update).
///
/// Production always uses `URLSession.shared`. Tests replace it to route requests to in-process stubs.
enum HTTPDefaults {
    nonisolated(unsafe) static var urlSession: URLSession = .shared
}
