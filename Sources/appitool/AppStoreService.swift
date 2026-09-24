//
//  AppStoreService.swift
//  appitool
//
//  Created by Orkun Tümer on 24.09.2026.
//

import OpenAPIURLSession
import OpenAPIRuntime

struct AppStoreService: Sendable {
    private static let sharedTransport = URLSessionTransport()
    let client: Client

    /// Initializes AppStoreService with credentials using a .p8 key file path.
    init(
        keyId: String,
        issuerId: String,
        privateKeyPath: String,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        let authMiddleware = try AppStoreConnectAuthMiddleware(
            keyId: keyId,
            issuerId: issuerId,
            privateKeyPath: privateKeyPath
        )
        self.client = Client(
            serverURL: try Servers.Server1.url(),
            transport: transport,
            middlewares: [authMiddleware]
        )
    }

    /// Initializes AppStoreService with credentials using raw private key string (PEM or Base64).
    init(
        keyId: String,
        issuerId: String,
        privateKey: String,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        let authMiddleware = try AppStoreConnectAuthMiddleware(
            keyId: keyId,
            issuerId: issuerId,
            privateKey: privateKey
        )
        self.client = Client(
            serverURL: try Servers.Server1.url(),
            transport: transport,
            middlewares: [authMiddleware]
        )
    }

    /// Initializes AppStoreService with a pre-configured auth middleware.
    init(
        authMiddleware: AppStoreConnectAuthMiddleware,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        self.client = Client(
            serverURL: try Servers.Server1.url(),
            transport: transport,
            middlewares: [authMiddleware]
        )
    }
}
