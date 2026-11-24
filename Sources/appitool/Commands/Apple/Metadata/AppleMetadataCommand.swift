import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

/// App Store listing text: name, subtitle, description, keywords, promotional text, what's new, and URLs.
struct AppleMetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "List, download, and upload App Store listing text (name, subtitle, description, keywords, promotional text, what's new, URLs).",
        subcommands: [
            AppleMetadataListCommand.self,
            AppleMetadataDownloadCommand.self,
            AppleMetadataUploadCommand.self,
        ]
    )
}

/// Resolved version, app info, and localizations shared by the `apple metadata` commands.
struct AppleMetadataContext {
    let service: AppStoreService
    let appId: String
    let projectLabel: String
    let version: Components.Schemas.AppStoreVersion
    let versionLocalizations: [Components.Schemas.AppStoreVersionLocalization]
    let appInfo: AppInfoSummary
    let appInfoLocalizations: [AppInfoLocalizationValues]

    var versionLabel: String { version.attributes?.versionString ?? version.id }
    var versionState: String {
        version.attributes?.appVersionState?.rawValue ?? version.attributes?.appStoreState?.rawValue ?? "UNKNOWN"
    }
    var isVersionEditable: Bool { AppStoreService.editableVersionStates.contains(versionState) }

    /// Resolves the target version (editable preferred, `--app-version` respected) and app info (editable preferred).
    static func resolve(app: AppleAssetAppOptions) async throws -> AppleMetadataContext {
        let platform = try app.parsedPlatform()
        let service = try app.requireService()
        let candidate = await app.resolveBundleIdOrAppId()
        let appId = try await app.resolveAppId(service: service)

        let version = try await service.resolveAppStoreVersion(
            appId: appId,
            platform: platform,
            versionString: app.appVersion,
            requireEditable: false
        )
        let versionLocalizations = try await service.fetchAppStoreVersionLocalizations(versionId: version.id)
        let appInfo = try await service.resolveAppInfo(appId: appId)
        let appInfoLocalizations = try await service.fetchAppInfoLocalizations(appInfoId: appInfo.id)

        let context = AppleMetadataContext(
            service: service,
            appId: appId,
            projectLabel: candidate.bundleId ?? appId,
            version: version,
            versionLocalizations: versionLocalizations,
            appInfo: appInfo,
            appInfoLocalizations: appInfoLocalizations
        )
        Log("   Version \(context.versionLabel) [\(context.versionState)] · App info [\(appInfo.state ?? "UNKNOWN")]".dim)
        return context
    }

    /// Locales present on the version or the app info, sorted.
    var remoteLocales: [String] {
        Array(Set(versionLocalizations.compactMap { $0.attributes?.locale } + appInfoLocalizations.map(\.locale))).sorted()
    }

    func versionLocalization(_ locale: String) -> Components.Schemas.AppStoreVersionLocalization? {
        versionLocalizations.first { $0.attributes?.locale?.caseInsensitiveCompare(locale) == .orderedSame }
    }

    func appInfoLocalization(_ locale: String) -> AppInfoLocalizationValues? {
        appInfoLocalizations.first { $0.locale.caseInsensitiveCompare(locale) == .orderedSame }
    }

    /// Current store values for `locale`, keyed by field file stem.
    func remoteValues(_ locale: String) -> [String: String?] {
        let version = versionLocalization(locale)?.attributes
        let info = appInfoLocalization(locale)
        return [
            AppleMetadataField.name.rawValue: info?.name,
            AppleMetadataField.subtitle.rawValue: info?.subtitle,
            AppleMetadataField.privacyPolicyUrl.rawValue: info?.privacyPolicyUrl,
            AppleMetadataField.privacyChoicesUrl.rawValue: info?.privacyChoicesUrl,
            AppleMetadataField.description.rawValue: version?.description,
            AppleMetadataField.keywords.rawValue: version?.keywords,
            AppleMetadataField.promotionalText.rawValue: version?.promotionalText,
            AppleMetadataField.whatsNew.rawValue: version?.whatsNew,
            AppleMetadataField.marketingUrl.rawValue: version?.marketingUrl,
            AppleMetadataField.supportUrl.rawValue: version?.supportUrl,
        ]
    }

    /// `$STORE_ASSETS_PATH/apple/` or `~/.appitool/assets/<project>/apple/`.
    func defaultStoreRoot() -> URL {
        AppitoolPaths.assetsDirectory(project: projectLabel, store: "apple")
    }

    /// Current app-level values (copyright, categories, App Review details, content rights, accessibility URL) keyed by
    /// `AppleStoreField` file stem, plus the App Review detail ID when one exists.
    func fetchStoreRemote() async throws -> (values: [String: String?], reviewDetailId: String?) {
        let categories = try await service.fetchAppInfoCategories(appInfoId: appInfo.id)
        let review = try await service.fetchReviewDetail(versionId: version.id)
        let appValues = try await service.fetchAppLevelValues(appId: appId)
        let r = review?.values
        let values: [String: String?] = [
            AppleStoreField.copyright.rawValue: version.attributes?.copyright,
            AppleStoreField.primaryCategory.rawValue: categories[.primaryCategory],
            AppleStoreField.primarySubcategoryOne.rawValue: categories[.primarySubcategoryOne],
            AppleStoreField.primarySubcategoryTwo.rawValue: categories[.primarySubcategoryTwo],
            AppleStoreField.secondaryCategory.rawValue: categories[.secondaryCategory],
            AppleStoreField.secondarySubcategoryOne.rawValue: categories[.secondarySubcategoryOne],
            AppleStoreField.secondarySubcategoryTwo.rawValue: categories[.secondarySubcategoryTwo],
            AppleStoreField.reviewContactFirstName.rawValue: r?.contactFirstName,
            AppleStoreField.reviewContactLastName.rawValue: r?.contactLastName,
            AppleStoreField.reviewContactPhone.rawValue: r?.contactPhone,
            AppleStoreField.reviewContactEmail.rawValue: r?.contactEmail,
            AppleStoreField.reviewNotes.rawValue: r?.notes,
            AppleStoreField.reviewDemoAccountRequired.rawValue: r?.demoAccountRequired.map { $0 ? "true" : "false" },
            AppleStoreField.reviewDemoAccountName.rawValue: r?.demoAccountName,
            AppleStoreField.reviewDemoAccountPassword.rawValue: r?.demoAccountPassword,
            AppleStoreField.contentRightsDeclaration.rawValue: appValues.contentRightsDeclaration,
            AppleStoreField.accessibilityUrl.rawValue: appValues.accessibilityUrl,
        ]
        return (values, review?.id)
    }
}

/// Environment variable holding the App Review demo account password (never stored in metadata files).
let appleReviewDemoPasswordKey = "APPLE_REVIEW_DEMO_PASSWORD"
