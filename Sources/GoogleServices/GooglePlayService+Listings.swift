import Foundation
import GooglePlayStoreAPI
import OpenAPIRuntime

/// Text fields of one Google Play store listing language.
package struct GooglePlayListing: Sendable, Equatable {
    package let language: String
    package let title: String?
    package let shortDescription: String?
    package let fullDescription: String?
    package let video: String?

    package init(language: String, title: String? = nil, shortDescription: String? = nil, fullDescription: String? = nil, video: String? = nil) {
        self.language = language
        self.title = title
        self.shortDescription = shortDescription
        self.fullDescription = fullDescription
        self.video = video
    }
}

/// App-level contact details and default language of a Google Play app.
package struct GooglePlayAppDetails: Sendable, Equatable {
    package var contactEmail: String?
    package var contactPhone: String?
    package var contactWebsite: String?
    package var defaultLanguage: String?

    package init(contactEmail: String? = nil, contactPhone: String? = nil, contactWebsite: String? = nil, defaultLanguage: String? = nil) {
        self.contactEmail = contactEmail
        self.contactPhone = contactPhone
        self.contactWebsite = contactWebsite
        self.defaultLanguage = defaultLanguage
    }

    package var isEmpty: Bool { self == GooglePlayAppDetails() }
}

extension GooglePlayService {
    // MARK: - App Details (contact email / phone / website, default language)

    package func fetchAppDetails(packageName: String, editId: String) async throws -> GooglePlayAppDetails {
        let response = try await client.androidpublisher_period_edits_period_details_period_get(
            .init(path: .init(packageName: packageName, editId: editId))
        )
        switch response {
        case .ok(let ok):
            guard case .json(let details) = ok.body else { return GooglePlayAppDetails() }
            return GooglePlayAppDetails(
                contactEmail: details.contactEmail,
                contactPhone: details.contactPhone,
                contactWebsite: details.contactWebsite,
                defaultLanguage: details.defaultLanguage
            )
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while reading app details."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    /// Patches the given app details (`nil` fields are unchanged).
    package func patchAppDetails(packageName: String, editId: String, changes: GooglePlayAppDetails) async throws {
        let body = Components.Schemas.AppDetails(
            contactEmail: changes.contactEmail,
            contactPhone: changes.contactPhone,
            contactWebsite: changes.contactWebsite,
            defaultLanguage: changes.defaultLanguage
        )
        let response = try await client.androidpublisher_period_edits_period_details_period_patch(
            .init(path: .init(packageName: packageName, editId: editId), body: .json(body))
        )
        switch response {
        case .ok:
            return
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while updating app details."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    // MARK: - Store Listing Text

    /// Lists every store listing (title, short and full description, video) in the edit.
    package func listListings(packageName: String, editId: String) async throws -> [GooglePlayListing] {
        let response = try await client.androidpublisher_period_edits_period_listings_period_list(
            .init(path: .init(packageName: packageName, editId: editId))
        )
        switch response {
        case .ok(let ok):
            guard case .json(let payload) = ok.body else { return [] }
            return (payload.listings ?? []).compactMap { listing in
                guard let language = listing.language else { return nil }
                return GooglePlayListing(
                    language: language,
                    title: listing.title,
                    shortDescription: listing.shortDescription,
                    fullDescription: listing.fullDescription,
                    video: listing.video
                )
            }
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while listing store listings."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    /// Patches the given fields (`nil` = unchanged) of one store listing language in the edit.
    package func patchListing(packageName: String, editId: String, changes: GooglePlayListing) async throws {
        let body = Components.Schemas.Listing(
            fullDescription: changes.fullDescription,
            language: changes.language,
            shortDescription: changes.shortDescription,
            title: changes.title,
            video: changes.video
        )
        let response = try await client.androidpublisher_period_edits_period_listings_period_patch(
            .init(
                path: .init(packageName: packageName, editId: editId, language: changes.language),
                body: .json(body)
            )
        )
        switch response {
        case .ok:
            return
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while updating listing '\(changes.language)'."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }
}
