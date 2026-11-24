import Foundation
import AppStoreConnectAPI
import OpenAPIRuntime

/// App Review contact and demo-account details of an App Store version.
package struct ReviewDetailValues: Sendable, Equatable {
    package var contactFirstName: String?
    package var contactLastName: String?
    package var contactPhone: String?
    package var contactEmail: String?
    package var demoAccountName: String?
    package var demoAccountPassword: String?
    package var demoAccountRequired: Bool?
    package var notes: String?

    package init(
        contactFirstName: String? = nil,
        contactLastName: String? = nil,
        contactPhone: String? = nil,
        contactEmail: String? = nil,
        demoAccountName: String? = nil,
        demoAccountPassword: String? = nil,
        demoAccountRequired: Bool? = nil,
        notes: String? = nil
    ) {
        self.contactFirstName = contactFirstName
        self.contactLastName = contactLastName
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.demoAccountName = demoAccountName
        self.demoAccountPassword = demoAccountPassword
        self.demoAccountRequired = demoAccountRequired
        self.notes = notes
    }

    package var isEmpty: Bool { self == ReviewDetailValues() }
}

/// App-level attributes editable through `apple metadata`.
package struct AppLevelValues: Sendable, Equatable {
    package var contentRightsDeclaration: String?
    package var accessibilityUrl: String?

    package init(contentRightsDeclaration: String? = nil, accessibilityUrl: String? = nil) {
        self.contentRightsDeclaration = contentRightsDeclaration
        self.accessibilityUrl = accessibilityUrl
    }

    package var isEmpty: Bool { contentRightsDeclaration == nil && accessibilityUrl == nil }
}

/// App info category relationship names (as in the API) mapped to category IDs.
package enum AppInfoCategorySlot: String, CaseIterable, Sendable {
    case primaryCategory
    case primarySubcategoryOne
    case primarySubcategoryTwo
    case secondaryCategory
    case secondarySubcategoryOne
    case secondarySubcategoryTwo
}

extension AppStoreService {
    // MARK: - Categories

    /// Current category IDs of an app info, keyed by slot.
    package func fetchAppInfoCategories(appInfoId: String) async throws -> [AppInfoCategorySlot: String] {
        let response = try await execute {
            try await client.appInfos_getInstance(
                path: .init(id: appInfoId),
                query: .init(include: [
                    .primaryCategory, .primarySubcategoryOne, .primarySubcategoryTwo,
                    .secondaryCategory, .secondarySubcategoryOne, .secondarySubcategoryTwo,
                ])
            )
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body, let rel = body.data.relationships else {
            return [:]
        }
        var result: [AppInfoCategorySlot: String] = [:]
        result[.primaryCategory] = rel.primaryCategory?.data?.id
        result[.primarySubcategoryOne] = rel.primarySubcategoryOne?.data?.id
        result[.primarySubcategoryTwo] = rel.primarySubcategoryTwo?.data?.id
        result[.secondaryCategory] = rel.secondaryCategory?.data?.id
        result[.secondarySubcategoryOne] = rel.secondarySubcategoryOne?.data?.id
        result[.secondarySubcategoryTwo] = rel.secondarySubcategoryTwo?.data?.id
        return result
    }

    /// Sets the given category slots of an app info (`nil` / absent slots are not sent).
    package func updateAppInfoCategories(appInfoId: String, categories: [AppInfoCategorySlot: String]) async throws {
        typealias Rel = Components.Schemas.AppInfoUpdateRequest.dataPayload.relationshipsPayload
        let payload = Components.Schemas.AppInfoUpdateRequest(
            data: .init(
                _type: .appInfos,
                id: appInfoId,
                relationships: Rel(
                    primaryCategory: categories[.primaryCategory].map { .init(data: .init(_type: .appCategories, id: $0)) },
                    primarySubcategoryOne: categories[.primarySubcategoryOne].map { .init(data: .init(_type: .appCategories, id: $0)) },
                    primarySubcategoryTwo: categories[.primarySubcategoryTwo].map { .init(data: .init(_type: .appCategories, id: $0)) },
                    secondaryCategory: categories[.secondaryCategory].map { .init(data: .init(_type: .appCategories, id: $0)) },
                    secondarySubcategoryOne: categories[.secondarySubcategoryOne].map { .init(data: .init(_type: .appCategories, id: $0)) },
                    secondarySubcategoryTwo: categories[.secondarySubcategoryTwo].map { .init(data: .init(_type: .appCategories, id: $0)) }
                )
            )
        )
        let response = try await execute {
            try await client.appInfos_updateInstance(path: .init(id: appInfoId), body: .json(payload))
        }
        guard case .ok = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating categories of app info '\(appInfoId)'.")
        }
    }

    /// Valid App Store category IDs (categories and subcategories) for a platform.
    package func fetchCategoryIds(platform: Components.Schemas.Platform) async throws -> Set<String> {
        typealias Query = Operations.appCategories_getCollection.Input.Query
        let platforms = Query.filter_lbrack_platforms_rbrack_PayloadPayload(rawValue: platform.rawValue).map { [$0] }
        let response = try await execute {
            try await client.appCategories_getCollection(query: .init(
                filter_lbrack_platforms_rbrack_: platforms,
                limit: 200,
                include: [.subcategories],
                limit_lbrack_subcategories_rbrack_: 50
            ))
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else { return [] }
        var ids = Set(body.data.map(\.id))
        for item in body.included ?? [] {
            ids.insert(item.id)
        }
        return ids
    }

    // MARK: - App-Level Attributes

    package func fetchAppLevelValues(appId: String) async throws -> AppLevelValues {
        let response = try await execute {
            try await client.apps_getInstance(path: .init(id: appId))
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else { return AppLevelValues() }
        return AppLevelValues(
            contentRightsDeclaration: body.data.attributes?.contentRightsDeclaration?.rawValue,
            accessibilityUrl: body.data.attributes?.accessibilityUrl
        )
    }

    package func updateAppLevelValues(appId: String, changes: AppLevelValues) async throws {
        typealias Attributes = Components.Schemas.AppUpdateRequest.dataPayload.attributesPayload
        let payload = Components.Schemas.AppUpdateRequest(
            data: .init(
                _type: .apps,
                id: appId,
                attributes: .init(
                    accessibilityUrl: changes.accessibilityUrl,
                    contentRightsDeclaration: changes.contentRightsDeclaration.flatMap(Attributes.contentRightsDeclarationPayload.init(rawValue:))
                )
            )
        )
        let response = try await execute {
            try await client.apps_updateInstance(path: .init(id: appId), body: .json(payload))
        }
        guard case .ok = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating app '\(appId)'.")
        }
    }

    // MARK: - Version Copyright

    package func updateVersionCopyright(versionId: String, copyright: String) async throws {
        let payload = Components.Schemas.AppStoreVersionUpdateRequest(
            data: .init(_type: .appStoreVersions, id: versionId, attributes: .init(copyright: copyright))
        )
        let response = try await execute {
            try await client.appStoreVersions_updateInstance(path: .init(id: versionId), body: .json(payload))
        }
        guard case .ok = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating copyright of version '\(versionId)'.")
        }
    }

    // MARK: - App Review Details

    /// The version's App Review details, or `nil` when none exist yet.
    package func fetchReviewDetail(versionId: String) async throws -> (id: String, values: ReviewDetailValues)? {
        let response: Operations.appStoreVersions_appStoreReviewDetail_getToOneRelated.Output
        do {
            response = try await execute {
                try await client.appStoreVersions_appStoreReviewDetail_getToOneRelated(path: .init(id: versionId))
            }
        } catch AppStoreServiceError.apiError(status: 404, _) {
            return nil
        } catch let error as ClientError where Self.isNullDataResponse(error.underlyingError) {
            // A version without App Review details returns `{"data": null}`, which the spec does not allow.
            return nil
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else { return nil }
        let attrs = body.data.attributes
        return (body.data.id, ReviewDetailValues(
            contactFirstName: attrs?.contactFirstName,
            contactLastName: attrs?.contactLastName,
            contactPhone: attrs?.contactPhone,
            contactEmail: attrs?.contactEmail,
            demoAccountName: attrs?.demoAccountName,
            demoAccountPassword: attrs?.demoAccountPassword,
            demoAccountRequired: attrs?.demoAccountRequired,
            notes: attrs?.notes
        ))
    }

    /// `true` for the decoding failure produced by a to-one response whose `data` is `null`.
    static func isNullDataResponse(_ error: any Error) -> Bool {
        guard case DecodingError.valueNotFound(_, let context) = error else { return false }
        return context.codingPath.map(\.stringValue) == ["data"]
    }

    /// Creates App Review details for a version (when none exist) with the given values.
    package func createReviewDetail(versionId: String, values: ReviewDetailValues) async throws {
        let payload = Components.Schemas.AppStoreReviewDetailCreateRequest(
            data: .init(
                _type: .appStoreReviewDetails,
                attributes: .init(
                    contactFirstName: values.contactFirstName,
                    contactLastName: values.contactLastName,
                    contactPhone: values.contactPhone,
                    contactEmail: values.contactEmail,
                    demoAccountName: values.demoAccountName,
                    demoAccountPassword: values.demoAccountPassword,
                    demoAccountRequired: values.demoAccountRequired,
                    notes: values.notes
                ),
                relationships: .init(appStoreVersion: .init(data: .init(_type: .appStoreVersions, id: versionId)))
            )
        )
        let response = try await execute {
            try await client.appStoreReviewDetails_createInstance(body: .json(payload))
        }
        guard case .created = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when creating App Review details for version '\(versionId)'.")
        }
    }

    /// Updates the given App Review detail fields (`nil` fields are not sent).
    package func updateReviewDetail(id: String, changes: ReviewDetailValues) async throws {
        let payload = Components.Schemas.AppStoreReviewDetailUpdateRequest(
            data: .init(
                _type: .appStoreReviewDetails,
                id: id,
                attributes: .init(
                    contactFirstName: changes.contactFirstName,
                    contactLastName: changes.contactLastName,
                    contactPhone: changes.contactPhone,
                    contactEmail: changes.contactEmail,
                    demoAccountName: changes.demoAccountName,
                    demoAccountPassword: changes.demoAccountPassword,
                    demoAccountRequired: changes.demoAccountRequired,
                    notes: changes.notes
                )
            )
        )
        let response = try await execute {
            try await client.appStoreReviewDetails_updateInstance(path: .init(id: id), body: .json(payload))
        }
        guard case .ok = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating App Review details '\(id)'.")
        }
    }
}
