import Foundation
import AppStoreConnectAPI

/// An App Store Connect app info (holds name / subtitle localizations; one live, one editable while a version is prepared).
package struct AppInfoSummary: Sendable, Equatable {
    package let id: String
    package let state: String?

    /// `true` when the app info can be edited (a new version is being prepared or was rejected).
    package var isEditable: Bool {
        state.map(AppStoreService.editableVersionStates.contains) ?? false
    }
}

/// Name / subtitle / privacy fields of one app info localization.
package struct AppInfoLocalizationValues: Sendable, Equatable {
    package let id: String
    package let locale: String
    package let name: String?
    package let subtitle: String?
    package let privacyPolicyUrl: String?
    package let privacyChoicesUrl: String?
}

/// Changes to apply to an app info localization (`nil` fields are not sent).
package struct AppInfoLocalizationChanges: Sendable, Equatable {
    package var name: String?
    package var subtitle: String?
    package var privacyPolicyUrl: String?
    package var privacyChoicesUrl: String?

    package init(name: String? = nil, subtitle: String? = nil, privacyPolicyUrl: String? = nil, privacyChoicesUrl: String? = nil) {
        self.name = name
        self.subtitle = subtitle
        self.privacyPolicyUrl = privacyPolicyUrl
        self.privacyChoicesUrl = privacyChoicesUrl
    }

    package var isEmpty: Bool { name == nil && subtitle == nil && privacyPolicyUrl == nil && privacyChoicesUrl == nil }
}

/// Changes to apply to an App Store version localization (`nil` fields are not sent).
package struct VersionLocalizationChanges: Sendable, Equatable {
    package var description: String?
    package var keywords: String?
    package var marketingUrl: String?
    package var promotionalText: String?
    package var supportUrl: String?
    package var whatsNew: String?

    package init(
        description: String? = nil,
        keywords: String? = nil,
        marketingUrl: String? = nil,
        promotionalText: String? = nil,
        supportUrl: String? = nil,
        whatsNew: String? = nil
    ) {
        self.description = description
        self.keywords = keywords
        self.marketingUrl = marketingUrl
        self.promotionalText = promotionalText
        self.supportUrl = supportUrl
        self.whatsNew = whatsNew
    }

    package var isEmpty: Bool {
        description == nil && keywords == nil && marketingUrl == nil && promotionalText == nil && supportUrl == nil && whatsNew == nil
    }

    /// `true` when only `promotionalText` changes (the one field App Store Connect allows on a live version).
    package var isPromotionalTextOnly: Bool {
        promotionalText != nil && description == nil && keywords == nil && marketingUrl == nil && supportUrl == nil && whatsNew == nil
    }
}

extension AppStoreService {
    // MARK: - App Store Versions

    /// Creates a new App Store version (`POST /v1/appStoreVersions`). App Store Connect copies the previous version's
    /// localizations and screenshots into it.
    package func createAppStoreVersion(
        appId: String,
        platform: Components.Schemas.Platform,
        versionString: String,
        releaseType: String? = nil,
        earliestReleaseDate: Date? = nil,
        copyright: String? = nil
    ) async throws -> Components.Schemas.AppStoreVersion {
        typealias Attributes = Components.Schemas.AppStoreVersionCreateRequest.dataPayload.attributesPayload
        let payload = Components.Schemas.AppStoreVersionCreateRequest(
            data: .init(
                _type: .appStoreVersions,
                attributes: .init(
                    platform: platform,
                    versionString: versionString,
                    copyright: copyright,
                    releaseType: releaseType.flatMap(Attributes.releaseTypePayload.init(rawValue:)),
                    earliestReleaseDate: earliestReleaseDate
                ),
                relationships: .init(app: .init(data: .init(_type: .apps, id: appId)))
            )
        )
        let response = try await execute {
            try await client.appStoreVersions_createInstance(body: .json(payload))
        }
        guard case .created(let created) = response, case .json(let body) = created.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when creating App Store version '\(versionString)'.")
        }
        return body.data
    }

    /// Deletes an App Store version. Returns `false` when it no longer exists (HTTP 404).
    @discardableResult
    package func deleteAppStoreVersion(id: String) async throws -> Bool {
        let response = try await execute {
            try await client.appStoreVersions_deleteInstance(path: .init(id: id))
        }
        switch response {
        case .noContent: return true
        case .notFound: return false
        default:
            throw AppStoreServiceError.invalidResponse("Unexpected response when deleting App Store version '\(id)'.")
        }
    }

    // MARK: - App Info (name, subtitle, privacy)

    /// Lists the app infos of an app (usually the live one plus an editable one while a version is prepared).
    package func fetchAppInfos(appId: String) async throws -> [AppInfoSummary] {
        let response = try await execute {
            try await client.apps_appInfos_getToManyRelated(path: .init(id: appId), query: .init(limit: 200))
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            return []
        }
        return body.data.map { AppInfoSummary(id: $0.id, state: $0.attributes?.state?.rawValue) }
    }

    /// Picks the app info to read or edit: the editable one when present, otherwise the live (or first) one.
    package func resolveAppInfo(appId: String) async throws -> AppInfoSummary {
        let infos = try await fetchAppInfos(appId: appId)
        if let editable = infos.first(where: \.isEditable) {
            return editable
        }
        if let live = infos.first(where: { $0.state == "READY_FOR_DISTRIBUTION" }) ?? infos.first {
            return live
        }
        throw AppStoreServiceError.notFound("No app info found for app '\(appId)'.")
    }

    /// Lists the localizations (name, subtitle, privacy URLs) of an app info.
    package func fetchAppInfoLocalizations(appInfoId: String) async throws -> [AppInfoLocalizationValues] {
        let response = try await execute {
            try await client.appInfos_appInfoLocalizations_getToManyRelated(path: .init(id: appInfoId), query: .init(limit: 200))
        }
        guard case .ok(let ok) = response, case .json(let body) = ok.body else {
            return []
        }
        return body.data.map {
            AppInfoLocalizationValues(
                id: $0.id,
                locale: $0.attributes?.locale ?? $0.id,
                name: $0.attributes?.name,
                subtitle: $0.attributes?.subtitle,
                privacyPolicyUrl: $0.attributes?.privacyPolicyUrl,
                privacyChoicesUrl: $0.attributes?.privacyChoicesUrl
            )
        }
    }

    /// Updates the given fields of an app info localization.
    package func updateAppInfoLocalization(id: String, changes: AppInfoLocalizationChanges) async throws {
        let payload = Components.Schemas.AppInfoLocalizationUpdateRequest(
            data: .init(
                _type: .appInfoLocalizations,
                id: id,
                attributes: .init(
                    name: changes.name,
                    subtitle: changes.subtitle,
                    privacyPolicyUrl: changes.privacyPolicyUrl,
                    privacyChoicesUrl: changes.privacyChoicesUrl
                )
            )
        )
        let response = try await execute {
            try await client.appInfoLocalizations_updateInstance(path: .init(id: id), body: .json(payload))
        }
        guard case .ok = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating app info localization '\(id)'.")
        }
    }

    // MARK: - Version Localization (description, keywords, promotional text, what's new, URLs)

    /// Updates the given fields of an App Store version localization.
    package func updateVersionLocalization(id: String, changes: VersionLocalizationChanges) async throws {
        let payload = Components.Schemas.AppStoreVersionLocalizationUpdateRequest(
            data: .init(
                _type: .appStoreVersionLocalizations,
                id: id,
                attributes: .init(
                    description: changes.description,
                    keywords: changes.keywords,
                    marketingUrl: changes.marketingUrl,
                    promotionalText: changes.promotionalText,
                    supportUrl: changes.supportUrl,
                    whatsNew: changes.whatsNew
                )
            )
        )
        let response = try await execute {
            try await client.appStoreVersionLocalizations_updateInstance(path: .init(id: id), body: .json(payload))
        }
        guard case .ok = response else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating version localization '\(id)'.")
        }
    }
}
