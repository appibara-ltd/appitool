//
//  AppStoreService.swift
//  appitool
//
//  Created by Orkun Tümer on 24.09.2026.
//

import OpenAPIURLSession
import OpenAPIRuntime
import AppStoreConnectAPI
import MatchTarget

/// Service providing access to the Apple App Store Connect API.
struct AppStoreService: Sendable {
    private static let sharedTransport = URLSessionTransport()

    /// The underlying OpenAPI client for the App Store Connect API.
    let client: Client

    /// Initializes AppStoreService with credentials (key can be a .p8 file path, raw PEM string, or Base64).
    init(
        keyId: String,
        issuerId: String,
        key: String,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        let authMiddleware = try AppStoreConnectAuthMiddleware(
            keyId: keyId,
            issuerId: issuerId,
            key: key
        )
        let configuration = Configuration(dateTranscoder: FlexibleDateTranscoder())
        self.client = Client(
            serverURL: try Servers.Server1.url(),
            configuration: configuration,
            transport: transport,
            middlewares: [authMiddleware]
        )
    }
}
