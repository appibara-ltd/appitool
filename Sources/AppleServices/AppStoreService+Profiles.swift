import Foundation
import AppStoreConnectAPI

/// Details of a newly created provisioning profile.
package struct CreatedProfileInfo: Sendable {
    package let id: String
    package let name: String
    package let uuid: String
    package let profileData: Data

    package init(id: String, name: String, uuid: String, profileData: Data) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.profileData = profileData
    }
}

/// Result of creating a provisioning profile.
package struct CreateProfileResult: Sendable {
    package let profile: CreatedProfileInfo
    package let profileType: Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload
    package let bundleId: String
    package let selectedCertificateId: String
    package let selectedCertificateName: String?
    package let includedDeviceCount: Int
    package let savedURL: URL?

    package init(
        profile: CreatedProfileInfo,
        profileType: Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload,
        bundleId: String,
        selectedCertificateId: String,
        selectedCertificateName: String?,
        includedDeviceCount: Int,
        savedURL: URL?
    ) {
        self.profile = profile
        self.profileType = profileType
        self.bundleId = bundleId
        self.selectedCertificateId = selectedCertificateId
        self.selectedCertificateName = selectedCertificateName
        self.includedDeviceCount = includedDeviceCount
        self.savedURL = savedURL
    }
}

/// Result of deleting a provisioning profile.
package struct DeleteProfileResult: Sendable {
    package let deleted: Bool
    package let matchedProfile: Components.Schemas.Profile?
    package let targetDescription: String

    package init(deleted: Bool, matchedProfile: Components.Schemas.Profile?, targetDescription: String) {
        self.deleted = deleted
        self.matchedProfile = matchedProfile
        self.targetDescription = targetDescription
    }
}

/// Result of pruning provisioning profiles.
package struct PruneProfilesResult: Sendable {
    package let candidates: [(profile: Components.Schemas.Profile, reason: String)]
    package let isDryRun: Bool
    package let deletedCount: Int
    package let failedProfiles: [(name: String, error: String)]

    package init(
        candidates: [(profile: Components.Schemas.Profile, reason: String)],
        isDryRun: Bool,
        deletedCount: Int,
        failedProfiles: [(name: String, error: String)]
    ) {
        self.candidates = candidates
        self.isDryRun = isDryRun
        self.deletedCount = deletedCount
        self.failedProfiles = failedProfiles
    }
}

extension AppStoreService {

    /// Creates and optionally saves a provisioning profile on Apple Developer Portal.
    package func createProvisioningProfile(
        bundleId: String,
        type: String = "appstore",
        platform: String = "ios",
        name: String? = nil,
        certificateId: String? = nil,
        deviceIds: [String]? = nil,
        outputPath: String? = nil
    ) async throws -> CreateProfileResult {
        let cleanBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Bundle ID cannot be empty.")
        }

        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Resolve Profile Type
        let targetProfileType = try AppleTypeMapper.mapProfileType(type: normalizedType, platform: normalizedPlatform)

        // 2. Resolve Bundle ID Portal ID
        let portalBundleId = try await resolveOrCreateBundleId(bundleId: cleanBundleId)

        // 3. Resolve Certificate ID
        let resolvedCertId: String
        let selectedCertName: String?
        if let explicitCertId = certificateId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitCertId.isEmpty {
            resolvedCertId = explicitCertId
            selectedCertName = nil
        } else {
            let certTypes = AppleTypeMapper.appleCertificateTypesForProfile(type: normalizedType, platform: normalizedPlatform)
            let certs = try await fetchCertificates(types: certTypes)
            guard let activeCert = certs.first else {
                throw AppStoreServiceError.notFound("No active \(normalizedType) certificate found on Apple Developer Portal.")
            }
            resolvedCertId = activeCert.id
            selectedCertName = activeCert.attributes?.name ?? activeCert.id
        }

        // 4. Resolve Devices (for development / adhoc)
        var resolvedDeviceIds: [String] = []
        let isDevOrAdhoc = normalizedType == "development" || normalizedType == "dev" || normalizedType == "adhoc" || normalizedType == "ad-hoc"
        if let explicitDevices = deviceIds, !explicitDevices.isEmpty {
            resolvedDeviceIds = explicitDevices
        } else if isDevOrAdhoc {
            resolvedDeviceIds = try await fetchActiveDeviceIds(for: normalizedPlatform)
            guard !resolvedDeviceIds.isEmpty else {
                throw AppStoreServiceError.invalidResponse("Development/AdHoc profiles require at least one registered device, but no enabled devices were found on Apple Developer Portal.")
            }
        }

        // 5. Determine Profile Name
        let profileName: String
        if let customName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !customName.isEmpty {
            profileName = customName
        } else {
            let typeLabel: String
            switch normalizedType {
            case "development", "dev": typeLabel = "Development"
            case "adhoc", "ad-hoc": typeLabel = "AdHoc"
            case "enterprise", "inhouse": typeLabel = "InHouse"
            case "developer-id", "developer_id", "direct": typeLabel = "DeveloperID"
            default: typeLabel = "AppStore"
            }
            let platformSuffix = (normalizedPlatform == "ios") ? "" : " \(normalizedPlatform)"
            profileName = "match \(typeLabel) \(cleanBundleId)\(platformSuffix)"
        }

        // 6. Create Profile
        let created = try await createProfile(
            name: profileName,
            profileType: targetProfileType,
            bundleIdPortalId: portalBundleId,
            certificateId: resolvedCertId,
            deviceIds: resolvedDeviceIds
        )

        // 7. Write to output if requested
        var savedURL: URL? = nil
        if let outPath = outputPath?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            let expandedPath = (outPath as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expandedPath)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try created.profileData.write(to: fileURL)
            savedURL = fileURL
        }

        return CreateProfileResult(
            profile: CreatedProfileInfo(
                id: created.id,
                name: created.name,
                uuid: created.uuid,i
                profileData: created.profileData
            ),
            profileType: targetProfileType,
            bundleId: cleanBundleId,
            selectedCertificateId: resolvedCertId,
            selectedCertificateName: selectedCertName,
            includedDeviceCount: resolvedDeviceIds.count,
            savedURL: savedURL
        )
    }

    /// Deletes a single provisioning profile from Apple Developer Portal matching name, uuid, or direct portal ID.
    package func deleteProvisioningProfile(
        name: String? = nil,
        uuid: String? = nil,
        portalId: String? = nil
    ) async throws -> DeleteProfileResult {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUUID = uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = portalId?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedName != nil && !trimmedName!.isEmpty) ||
              (trimmedUUID != nil && !trimmedUUID!.isEmpty) ||
              (trimmedId != nil && !trimmedId!.isEmpty) else {
            throw AppStoreServiceError.invalidResponse("Missing target profile identifier (provide name, uuid, or portalId).")
        }

        let targetDescription = trimmedName ?? trimmedUUID ?? trimmedId ?? "unknown"

        // Direct delete if only portal ID is provided
        if let directId = trimmedId, trimmedName == nil, trimmedUUID == nil {
            let deleted = try await deleteProfile(id: directId)
            return DeleteProfileResult(deleted: deleted, matchedProfile: nil, targetDescription: targetDescription)
        }

        let profiles = try await fetchProfiles(limit: 200, name: trimmedName)
        let matched = profiles.first { profile in
            if let targetUUID = trimmedUUID, profile.attributes?.uuid == targetUUID {
                return true
            }
            if let targetName = trimmedName, profile.attributes?.name == targetName {
                return true
            }
            if let targetId = trimmedId, profile.id == targetId {
                return true
            }
            return false
        }

        guard let targetProfile = matched else {
            return DeleteProfileResult(deleted: false, matchedProfile: nil, targetDescription: targetDescription)
        }

        let deleted = try await deleteProfile(id: targetProfile.id)
        return DeleteProfileResult(deleted: deleted, matchedProfile: targetProfile, targetDescription: targetDescription)
    }

    /// Inspects and discovers all candidate provisioning profiles for pruning (INVALID or EXPIRED).
    package func inspectProfilesForPruning(
        includeExpired: Bool = false
    ) async throws -> [(profile: Components.Schemas.Profile, reason: String)] {
        let profiles = try await fetchProfiles()
        let now = Date()

        return profiles.compactMap { profile in
            let isInvalid = profile.attributes?.profileState == .INVALID
            let isExpired = includeExpired && (profile.attributes?.expirationDate != nil) && (profile.attributes!.expirationDate! < now)

            if isInvalid {
                return (profile: profile, reason: "INVALID")
            } else if isExpired {
                return (profile: profile, reason: "EXPIRED")
            }
            return nil
        }
    }

    /// Prunes invalid and optionally expired provisioning profiles from Apple Developer Portal.
    package func pruneProfiles(
        includeExpired: Bool = false,
        dryRun: Bool = false
    ) async throws -> PruneProfilesResult {
        let candidates = try await inspectProfilesForPruning(includeExpired: includeExpired)

        if dryRun || candidates.isEmpty {
            return PruneProfilesResult(
                candidates: candidates,
                isDryRun: dryRun,
                deletedCount: 0,
                failedProfiles: []
            )
        }

        var deletedCount = 0
        var failed: [(name: String, error: String)] = []

        for (p, _) in candidates {
            let nameStr = p.attributes?.name ?? "unnamed"
            do {
                let success = try await deleteProfile(id: p.id)
                if success {
                    deletedCount += 1
                } else {
                    failed.append((nameStr, "Profile was already absent."))
                }
            } catch {
                failed.append((nameStr, error.localizedDescription))
            }
        }

        return PruneProfilesResult(
            candidates: candidates,
            isDryRun: false,
            deletedCount: deletedCount,
            failedProfiles: failed
        )
    }

    // MARK: - Active Profile and Device Queries

    /// Fetches all active, non-invalidated profile UUIDs from Apple Developer Portal matching the given platform and type.
    package func fetchActiveProfileUUIDs(
        platform: String,
        type: String,
        limit: Int = 200
    ) async throws -> Set<String> {
        let profiles = try await fetchProfiles(limit: limit)

        var activeUUIDs = Set<String>()
        for profile in profiles {
            let profTypeStr = profile.attributes?.profileType?.rawValue ?? ""
            let state = profile.attributes?.profileState
            if AppleTypeMapper.matchesProfileType(profTypeStr: profTypeStr, targetType: type, platform: platform) && state == .ACTIVE {
                if let uuid = profile.attributes?.uuid {
                    activeUUIDs.insert(uuid)
                }
            }
        }
        return activeUUIDs
    }

    /// Fetches all active, enabled device IDs registered on Apple Developer Portal matching the target platform.
    package func fetchActiveDeviceIds(for platform: String) async throws -> [String] {
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let platformFilter: Operations.devices_getCollection.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload =
            (normalizedPlatform == "macos" || normalizedPlatform == "mac" || normalizedPlatform == "catalyst") ? .MAC_OS : .IOS
        let devices = try await fetchDevices(platform: platformFilter)
        return AppleTypeMapper.filterDeviceIds(devices, for: normalizedPlatform)
    }
}
