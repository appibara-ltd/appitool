import ArgumentParser
import Foundation
import GoogleServices

/// Google Play store listing text: title, short and full description, and promo video.
struct GoogleMetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "List, download, and upload Google Play store listing text (title, short/full description, video).",
        subcommands: [
            GoogleMetadataListCommand.self,
            GoogleMetadataDownloadCommand.self,
            GoogleMetadataUploadCommand.self,
        ]
    )
}

extension GooglePlayListing {
    /// Store values keyed by `GoogleMetadataField` file stem.
    var metadataValues: [String: String?] {
        [
            GoogleMetadataField.title.rawValue: title,
            GoogleMetadataField.shortDescription.rawValue: shortDescription,
            GoogleMetadataField.fullDescription.rawValue: fullDescription,
            GoogleMetadataField.video.rawValue: video,
        ]
    }
}

extension GooglePlayAppDetails {
    /// Store values keyed by `GoogleStoreField` file stem.
    var metadataValues: [String: String?] {
        [
            GoogleStoreField.contactEmail.rawValue: contactEmail,
            GoogleStoreField.contactPhone.rawValue: contactPhone,
            GoogleStoreField.contactWebsite.rawValue: contactWebsite,
            GoogleStoreField.defaultLanguage.rawValue: defaultLanguage,
        ]
    }

    /// Patch body containing only the changed fields.
    static func changes(from changes: [StoreMetadataChange]) -> GooglePlayAppDetails {
        var details = GooglePlayAppDetails()
        for change in changes {
            switch GoogleStoreField(rawValue: change.field.key) {
            case .contactEmail: details.contactEmail = change.local
            case .contactPhone: details.contactPhone = change.local
            case .contactWebsite: details.contactWebsite = change.local
            case .defaultLanguage: details.defaultLanguage = change.local
            case .none: break
            }
        }
        return details
    }
}

enum GoogleMetadataSupport {
    /// Reads app details (contact email / phone / website, default language) in a short-lived read-only edit.
    static func fetchDetails(service: GooglePlayService, packageName: String) async throws -> GooglePlayAppDetails {
        try await service.withEditSession(packageName: packageName, commit: false) { editId in
            try await service.fetchAppDetails(packageName: packageName, editId: editId)
        }
    }

    /// Reads all listings in a short-lived read-only edit.
    static func fetchListings(service: GooglePlayService, packageName: String) async throws -> [GooglePlayListing] {
        try await service.withEditSession(packageName: packageName, commit: false) { editId in
            try await service.listListings(packageName: packageName, editId: editId)
        }
    }

    /// `$STORE_ASSETS_PATH/google/` or `~/.appitool/assets/<package>/google/`.
    static func defaultStoreRoot(packageName: String) -> URL {
        AppitoolPaths.assetsDirectory(project: packageName, store: "google")
    }

    static func filter(_ listings: [GooglePlayListing], locale: String?) -> [GooglePlayListing] {
        guard let target = CLIValues.trimmedNonEmpty(locale) else { return listings }
        return listings.filter { $0.language.caseInsensitiveCompare(target) == .orderedSame }
    }
}
