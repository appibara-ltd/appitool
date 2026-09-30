import Foundation
import AppStoreConnectAPI

/// Result of creating or registering an App Identifier with capabilities.
package struct RegisterBundleIdResult: Sendable {
    package let bundleId: Components.Schemas.BundleId
    package let enabledCapabilities: [Components.Schemas.CapabilityType]
    package let failedCapabilities: [(capability: Components.Schemas.CapabilityType, error: String)]

    package init(
        bundleId: Components.Schemas.BundleId,
        enabledCapabilities: [Components.Schemas.CapabilityType],
        failedCapabilities: [(capability: Components.Schemas.CapabilityType, error: String)]
    ) {
        self.bundleId = bundleId
        self.enabledCapabilities = enabledCapabilities
        self.failedCapabilities = failedCapabilities
    }
}

extension AppStoreService {

    /// Finds a bundle identifier by its identifier string (e.g. com.example.app).
    package func findBundleId(identifier: String) async throws -> Components.Schemas.BundleId? {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = try await fetchBundleIds(limit: 20, identifier: clean)
        return list.first(where: { $0.attributes?.identifier == clean })
    }

    /// Deletes a bundle identifier by its identifier string (e.g. com.example.app).
    ///
    /// - Returns: A tuple containing whether the bundle identifier was found and its portal ID.
    package func deleteBundleIdByIdentifier(identifier: String) async throws -> (found: Bool, portalId: String?) {
        guard let matched = try await findBundleId(identifier: identifier) else {
            return (false, nil)
        }
        let portalId = matched.id
        let deleted = try await deleteBundleId(id: portalId)
        return (deleted, portalId)
    }

    /// Registers a new bundle identifier with optional capabilities on Apple Developer Portal.
    package func registerBundleIdWithCapabilities(
        identifier: String,
        name: String? = nil,
        platform: String = "universal",
        capabilities: [String] = []
    ) async throws -> RegisterBundleIdResult {
        let targetIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetIdentifier.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Bundle identifier cannot be empty.")
        }

        let parsedPlatform = try AppleTypeMapper.parseBundleIdPlatform(platform)

        var capabilitiesToEnable: [Components.Schemas.CapabilityType] = []
        for rawCap in capabilities {
            let trimmed = rawCap.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let parsed = AppleTypeMapper.parseCapability(trimmed) else {
                throw AppStoreServiceError.invalidResponse("Unknown capability '\(trimmed)'.")
            }
            capabilitiesToEnable.append(parsed)
        }

        let identifierName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = try await createBundleId(
            identifier: targetIdentifier,
            name: identifierName,
            platform: parsedPlatform
        )

        let portalId = created.id
        var enabled: [Components.Schemas.CapabilityType] = []
        var failed: [(capability: Components.Schemas.CapabilityType, error: String)] = []

        for cap in capabilitiesToEnable {
            do {
                try await addCapability(bundleIdPortalId: portalId, capabilityType: cap)
                enabled.append(cap)
            } catch {
                failed.append((cap, error.localizedDescription))
            }
        }

        return RegisterBundleIdResult(
            bundleId: created,
            enabledCapabilities: enabled,
            failedCapabilities: failed
        )
    }

    /// Fetches all custom capabilities enabled for a specific application bundle identifier.
    package func fetchCapabilitiesForIdentifier(
        identifier: String
    ) async throws -> (bundleId: Components.Schemas.BundleId, capabilities: [Components.Schemas.BundleIdCapability]) {
        guard let matched = try await findBundleId(identifier: identifier) else {
            throw AppStoreServiceError.notFound("App Identifier '\(identifier)' was not found on Apple Developer Portal.")
        }
        let capabilities = try await fetchCapabilities(bundleIdPortalId: matched.id)
        return (matched, capabilities)
    }
}
