// The Swift Programming Language
// https://docs.swift.org/swift-book

import ArgumentParser
import Foundation

@main
struct appitool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A utility for Appibara tools.",
        version: "0.1.0"
    )

    @Option(help: "App Store Connect Key ID.")
    var keyId: String?

    @Option(help: "App Store Connect Issuer ID.")
    var issuerId: String?

    @Option(help: "Path to .p8 private key file.")
    var privateKeyPath: String?

    func run() async throws {
        if let keyId, let issuerId, let privateKeyPath {
            let appStoreService = try AppStoreService(
                keyId: keyId,
                issuerId: issuerId,
                privateKeyPath: privateKeyPath
            )
            appStoreService.client.apps_getCollection()
            print("AppStoreService successfully initialized with Key ID: \(keyId)")
            // let apps = try await service.client.apps_getCollection(...)
        } else {
            print("AppStoreService hazır. Kimlik doğrulamalı istek atmak için:")
            print("  appitool --key-id <KEY_ID> --issuer-id <ISSUER_ID> --private-key-path <PATH_TO_P8>")
        }
    }
}
