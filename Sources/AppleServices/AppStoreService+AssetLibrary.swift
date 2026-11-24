import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AppStoreConnectAPI

/// Flattened view of an App Store Connect Asset Library image (its attributes differ per review state).
package struct AssetLibraryImageInfo: Sendable, Equatable {
    package let id: String
    package let state: String
    package let fileName: String?
    package let fileSize: Int64?
    package let templateUrl: String?
    package let width: Int?
    package let height: Int?
    package let stateMessages: [String]
}

/// Flattened view of an Asset Library placement with its image (when included).
package struct AssetLibraryPlacementInfo: Sendable, Equatable {
    package let id: String
    package let placementType: Components.Schemas.AppAssetLibraryPlacementType?
    package let placementGroup: String?
    package let state: String?
    package let imageId: String?
    package let image: AssetLibraryImageInfo?
}

/// An image spec from `appAssetLibraryRefData`.
package struct AssetLibraryImageSpec: Sendable, Equatable {
    package let specId: String?
    package let shortName: String?
    package let aspectRatio: String?
    package let minWidth: Int?
    package let maxWidth: Int?
    package let minHeight: Int?
    package let maxHeight: Int?
    package let fileExtensions: [String]
    package let maxFileSize: Int?
    package let alphaAllowed: Bool?
    package let universalAsset: Bool?
    package let placementTypes: [Components.Schemas.AppAssetLibraryPlacementType]
}

/// Placement rules from `appAssetLibraryRefData`: which specs each placement group accepts, and limits.
package struct AssetLibraryReference: Sendable, Equatable {
    package struct PlacementGroup: Sendable, Equatable {
        package let id: String
        package let platform: String?
        package let displayClass: String?
        package let deviceFamily: String?
        package let screenDimensions: [String]
    }

    package struct GroupSpecs: Sendable, Equatable {
        package let placementType: Components.Schemas.AppAssetLibraryPlacementType
        package let groupId: String
        package let specIds: [String]
    }

    package struct Limit: Sendable, Equatable {
        package let feature: String?
        package let placementType: Components.Schemas.AppAssetLibraryPlacementType?
        package let groupIds: [String]
        package let maxCount: Int?
    }

    package let specs: [AssetLibraryImageSpec]
    package let groups: [PlacementGroup]
    package let groupSpecs: [GroupSpecs]
    package let limits: [Limit]
}

extension AppStoreService {
    // MARK: - Asset Library

    /// Returns the Asset Library ID of an app.
    package func fetchAssetLibraryId(appId: String) async throws -> String {
        let response = try await execute {
            try await client.apps_assetLibrary_getToOneRelated(path: .init(id: appId))
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            throw AppStoreServiceError.notFound("Asset Library for app '\(appId)' was not found.")
        }
        return body.data.id
    }

    /// Lists placements on an App Store version localization in display order (`placementGroupPosition`), including
    /// their images. Optionally filtered by placement types and one placement group.
    package func fetchPlacements(
        localizationId: String,
        placementTypes: [Components.Schemas.AppAssetLibraryPlacementType],
        placementGroup: String? = nil
    ) async throws -> [AssetLibraryPlacementInfo] {
        typealias Query = Operations.appStoreVersionLocalizations_placements_getToManyRelated.Input.Query
        let typeFilter = placementTypes.compactMap { Query.filter_lbrack_placementType_rbrack_PayloadPayload(rawValue: $0.rawValue) }

        let response = try await execute {
            try await client.appStoreVersionLocalizations_placements_getToManyRelated(
                path: .init(id: localizationId),
                query: .init(
                    filter_lbrack_placementType_rbrack_: typeFilter.isEmpty ? nil : typeFilter,
                    filter_lbrack_placementGroup_rbrack_: placementGroup.map { [$0] },
                    sort: [.placementGroupPosition],
                    limit: 200,
                    include: [.image]
                )
            )
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            return []
        }

        var images: [String: AssetLibraryImageInfo] = [:]
        for item in body.included ?? [] {
            if case .appAssetLibraryImages(let image) = item {
                images[image.id] = Self.imageInfo(image)
            }
        }

        return body.data.map { placement in
            let imageId = placement.relationships?.value1.value2.image?.data?.id
            return AssetLibraryPlacementInfo(
                id: placement.id,
                placementType: placement.attributes?.placementType,
                placementGroup: placement.attributes?.placementGroup,
                state: placement.attributes?.state,
                imageId: imageId,
                image: imageId.flatMap { images[$0] }
            )
        }
    }

    /// Fetches a single Asset Library image.
    package func fetchAssetLibraryImage(id: String) async throws -> AssetLibraryImageInfo {
        let response = try await execute {
            try await client.appAssetLibraryImages_getInstance(path: .init(id: id))
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when fetching Asset Library image '\(id)'.")
        }
        return Self.imageInfo(body.data)
    }

    /// Uploads an image into the Asset Library (reserve → upload parts → commit), optionally waiting for processing.
    package func uploadAssetLibraryImage(
        assetLibraryId: String,
        fileUrl: URL,
        category: Components.Schemas.AppAssetLibraryAssetCategory = .CREATIVE_ASSETS,
        waitForProcessing: Bool = true,
        pollInterval: TimeInterval = 2,
        processingTimeout: TimeInterval = 120
    ) async throws -> AssetLibraryImageInfo {
        let fileData = try Data(contentsOf: fileUrl)
        guard !fileData.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Image file is empty (0 bytes): \(fileUrl.path)")
        }

        // 1. Reserve
        let createPayload = Components.Schemas.AppAssetLibraryImageCreateRequest(
            data: .init(
                _type: .appAssetLibraryImages,
                attributes: .init(
                    category: category,
                    fileName: fileUrl.lastPathComponent,
                    fileSize: Int64(fileData.count)
                ),
                relationships: .init(
                    assetLibrary: .init(data: .init(_type: .appAssetLibraries, id: assetLibraryId))
                )
            )
        )
        let createResponse = try await execute {
            try await client.appAssetLibraryImages_createInstance(body: .json(createPayload))
        }
        guard case .created(let created) = createResponse, case .json(let reservation) = created.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when reserving Asset Library image upload.")
        }

        let imageId = reservation.data.id
        let operations = reservation.data.attributes?.value2.uploadOperations ?? []
        guard !operations.isEmpty else {
            throw AppStoreServiceError.invalidResponse("App Store Connect returned no upload operations for '\(fileUrl.lastPathComponent)'.")
        }

        // 2. Upload parts
        for (index, op) in operations.enumerated() {
            try await uploadScreenshotChunk(operation: op, index: index, fileData: fileData)
        }

        // 3. Commit
        let updatePayload = Components.Schemas.AppAssetLibraryImageUpdateRequest(
            data: .init(_type: .appAssetLibraryImages, id: imageId, attributes: .init(uploaded: true))
        )
        let updateResponse = try await execute {
            try await client.appAssetLibraryImages_updateInstance(path: .init(id: imageId), body: .json(updatePayload))
        }
        guard case .ok(let ok) = updateResponse, case .json(let updated) = ok.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when committing Asset Library image '\(imageId)'.")
        }

        var latest = Self.imageInfo(updated.data)
        func failIfFailed(_ info: AssetLibraryImageInfo) throws {
            if info.state == "FAILED" {
                let details = info.stateMessages.isEmpty ? "Asset processing failed without error details." : info.stateMessages.joined(separator: "; ")
                throw AppStoreServiceError.apiError(status: nil, message: details)
            }
        }
        try failIfFailed(latest)
        guard waitForProcessing else { return latest }

        // 4. Poll until processing finishes
        let processingStates: Set<String> = ["AWAITING_UPLOAD", "UPLOAD_COMPLETE"]
        let deadline = Date().addingTimeInterval(processingTimeout)
        while processingStates.contains(latest.state) {
            guard Date() < deadline else {
                throw AppStoreServiceError.invalidResponse("Timed out waiting for App Store Connect to process Asset Library image '\(imageId)'.")
            }
            if pollInterval > 0 {
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            latest = try await fetchAssetLibraryImage(id: imageId)
            try failIfFailed(latest)
        }
        return latest
    }

    /// Sets the display order of one placement group on a localization (`placementIds` first → shown first).
    package func orderPlacements(localizationId: String, placementGroup: String, placementIds: [String]) async throws {
        let payload = Components.Schemas.AppAssetLibraryPlacementOrderingRequestCreateRequest(
            data: .init(
                _type: .appAssetLibraryPlacementOrderingRequests,
                attributes: .init(placementGroup: placementGroup),
                relationships: .init(
                    orderedPlacements: .init(data: placementIds.map { .init(_type: .appAssetLibraryPlacements, id: $0) }),
                    appStoreVersionLocalization: .init(data: .init(_type: .appStoreVersionLocalizations, id: localizationId))
                )
            )
        )
        let response = try await execute {
            try await client.appAssetLibraryPlacementOrderingRequests_createInstance(body: .json(payload))
        }
        guard case .created = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when ordering placement group '\(placementGroup)'.")
        }
    }

    /// Places an Asset Library image on an App Store version localization. Screenshot placements need the device
    /// slot's `placementGroup` (e.g. `IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`); header / search placements have none.
    package func createPlacement(
        imageId: String,
        localizationId: String,
        placementType: Components.Schemas.AppAssetLibraryPlacementType,
        placementGroup: String? = nil
    ) async throws -> AssetLibraryPlacementInfo {
        let payload = Components.Schemas.AppAssetLibraryPlacementCreateRequest(
            data: .init(
                _type: .appAssetLibraryPlacements,
                attributes: .init(placementType: placementType, placementGroup: placementGroup),
                relationships: .init(
                    image: .init(data: .init(_type: .appAssetLibraryImages, id: imageId)),
                    appStoreVersionLocalization: .init(data: .init(_type: .appStoreVersionLocalizations, id: localizationId))
                )
            )
        )
        let response = try await execute {
            try await client.appAssetLibraryPlacements_createInstance(body: .json(payload))
        }
        guard case .created(let created) = response, case .json(let body) = created.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when creating placement.")
        }
        return AssetLibraryPlacementInfo(
            id: body.data.id,
            placementType: body.data.attributes?.placementType ?? placementType,
            placementGroup: body.data.attributes?.placementGroup ?? placementGroup,
            state: body.data.attributes?.state,
            imageId: imageId,
            image: nil
        )
    }

    /// Removes a placement (the image stays in the Asset Library).
    @discardableResult
    package func deletePlacement(id: String) async throws -> Bool {
        let response = try await execute {
            try await client.appAssetLibraryPlacements_deleteInstance(path: .init(id: id))
        }
        if case .noContent = response { return true }
        return false
    }

    /// Lists Apple's image specs for the given placement types.
    package func fetchAssetLibraryImageSpecs(
        placementTypes: [Components.Schemas.AppAssetLibraryPlacementType]
    ) async throws -> [AssetLibraryImageSpec] {
        let response = try await execute {
            try await client.appAssetLibraryRefData_getCollection(
                query: .init(filter_lbrack_placementTypes_rbrack_: placementTypes.map(\.rawValue))
            )
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            return []
        }
        let wanted = Set(placementTypes)
        var seen = Set<String>()
        var specs: [AssetLibraryImageSpec] = []
        for datum in body.data {
            for spec in datum.attributes?.imageSpecs ?? [] {
                let types = spec.compatiblePlacementTypes ?? []
                guard wanted.isEmpty || !wanted.isDisjoint(with: types) else { continue }
                let key = spec.specId ?? UUID().uuidString
                guard seen.insert(key).inserted else { continue }
                specs.append(AssetLibraryImageSpec(
                    specId: spec.specId,
                    shortName: spec.shortName,
                    aspectRatio: spec.aspectRatio,
                    minWidth: spec.dimensions?.minWidth,
                    maxWidth: spec.dimensions?.maxWidth,
                    minHeight: spec.dimensions?.minHeight,
                    maxHeight: spec.dimensions?.maxHeight,
                    fileExtensions: spec.fileExtensions ?? [],
                    maxFileSize: spec.maxFileSize.map { Int($0) },
                    alphaAllowed: spec.alphaAllowed,
                    universalAsset: spec.universalAsset,
                    placementTypes: types
                ))
            }
        }
        return specs
    }

    /// Fetches the full placement reference (specs, placement groups, display classes, limits) for placement types.
    package func fetchAssetLibraryReference(
        placementTypes: [Components.Schemas.AppAssetLibraryPlacementType]
    ) async throws -> AssetLibraryReference {
        let response = try await execute {
            try await client.appAssetLibraryRefData_getCollection(
                query: .init(filter_lbrack_placementTypes_rbrack_: placementTypes.isEmpty ? nil : placementTypes.map(\.rawValue))
            )
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            return AssetLibraryReference(specs: [], groups: [], groupSpecs: [], limits: [])
        }

        let wanted = Set(placementTypes)
        var displayClasses: [String: (family: String?, dims: [String])] = [:]
        var groups: [AssetLibraryReference.PlacementGroup] = []
        var groupSpecs: [AssetLibraryReference.GroupSpecs] = []
        var limits: [AssetLibraryReference.Limit] = []
        var seenGroups = Set<String>()

        for datum in body.data {
            guard let attrs = datum.attributes else { continue }
            for item in attrs.displayClasses ?? [] {
                guard let id = item.displayClassId?.rawValue else { continue }
                displayClasses[id] = (item.deviceFamily?.rawValue, item.screenDimensions ?? [])
            }
            for item in attrs.placementTypes ?? [] {
                guard let type = item.placementTypeId, wanted.isEmpty || wanted.contains(type) else { continue }
                for mapping in item.specMappings ?? [] {
                    guard let groupId = mapping.placementGroupId else { continue }
                    groupSpecs.append(.init(placementType: type, groupId: groupId, specIds: mapping.specs ?? []))
                }
            }
            for feature in attrs.features ?? [] {
                for policy in feature.placementPolicies ?? [] {
                    guard wanted.isEmpty || policy.placementType.map(wanted.contains) == true else { continue }
                    for limit in policy.groupLimits ?? [] {
                        limits.append(.init(
                            feature: feature.featureId?.rawValue,
                            placementType: policy.placementType,
                            groupIds: limit.groupIds ?? [],
                            maxCount: limit.maxCount
                        ))
                    }
                }
            }
            for group in attrs.placementProfileGroups ?? [] {
                guard let id = group.placementProfileGroupId, seenGroups.insert(id).inserted else { continue }
                let displayClass = group.displayClassId?.rawValue
                groups.append(.init(
                    id: id,
                    platform: group.platform?.rawValue,
                    displayClass: displayClass,
                    deviceFamily: displayClass.flatMap { displayClasses[$0]?.family },
                    screenDimensions: displayClass.flatMap { displayClasses[$0]?.dims } ?? []
                ))
            }
        }

        return AssetLibraryReference(
            specs: try await fetchAssetLibraryImageSpecs(placementTypes: placementTypes),
            groups: groups,
            groupSpecs: groupSpecs,
            limits: limits
        )
    }

    // MARK: - Helpers

    static func imageInfo(_ image: Components.Schemas.AppAssetLibraryImage) -> AssetLibraryImageInfo {
        // Attributes are patched to one superset schema (common + uploadOperations); `state` is a plain string.
        let common = image.attributes?.value1
        return AssetLibraryImageInfo(
            id: image.id,
            state: common?.state ?? "UNKNOWN",
            fileName: common?.fileName,
            fileSize: common?.fileSize,
            templateUrl: common?.imageAsset?.templateUrl,
            width: common?.imageAsset?.width,
            height: common?.imageAsset?.height,
            stateMessages: (common?.stateDetails ?? []).map {
                [$0.code, $0.description].compactMap { $0 }.joined(separator: ": ")
            }.filter { !$0.isEmpty }
        )
    }
}
