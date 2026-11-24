import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleMetadataUploadCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Uploads changed App Store metadata from <locale>/metadata/ and app-level metadata/ files (only fields that differ are sent)."
    )

    @OptionGroup
    var app: AppleAssetAppOptions

    @Option(name: .long, help: "Upload only this App Store locale (e.g. en-US); app-level fields are skipped. Omit to upload every locale plus app-level fields.")
    var locale: String?

    @Flag(name: .long, help: "Show the per-field changes without sending them.")
    var dryRun: Bool = false

    @Argument(help: "Metadata root containing <locale>/metadata/ folders (defaults to $STORE_ASSETS_PATH/apple/, or ~/.appitool/assets/<project>/apple/ when unset).")
    var path: String?

    func execute() async throws {
        Log("🔍 Resolving App Store version and app info...".dim)
        let context = try await AppleMetadataContext.resolve(app: app)
        let root = CLIValues.trimmedNonEmpty(path).map(ScreenshotFileResolver.expandPath) ?? context.defaultStoreRoot()

        let localeFilter = CLIValues.trimmedNonEmpty(locale)
        let localLocales = StoreMetadataFiles.locales(storeRoot: root, localeFilter: localeFilter)
        // App-level fields are uploaded only without --locale.
        let includeStore = localeFilter == nil
            && (StoreMetadataFiles.hasStoreDirectory(storeRoot: root) || EnvLoader.value(for: appleReviewDemoPasswordKey) != nil)
        guard !localLocales.isEmpty || includeStore else {
            throw CommandError(
                "No <locale>/metadata/ or metadata/ folders found under \(root.path)\(locale.map { " for '\($0)'" } ?? "").",
                hint: "Run 'appitool apple metadata download' first."
            )
        }

        var storeLocal: [String: String] = [:]
        var storeRemote: [String: String?] = [:]
        var reviewDetailId: String?
        var validCategoryIds: Set<String>?
        if includeStore {
            storeLocal = try StoreMetadataFiles.read(directory: StoreMetadataFiles.storeDirectory(storeRoot: root), fields: AppleStoreField.fileFields)
            if let password = EnvLoader.value(for: appleReviewDemoPasswordKey) {
                storeLocal[AppleStoreField.reviewDemoAccountPassword.rawValue] = password
            }
            (storeRemote, reviewDetailId) = try await context.fetchStoreRemote()
            if storeLocal.keys.contains(where: { AppleStoreField(rawValue: $0)?.isCategory == true }) {
                validCategoryIds = try await context.service.fetchCategoryIds(platform: try app.parsedPlatform())
            }
        }

        let fields = AppleMetadataField.allCases.map(\.field)
        var inputs: [AppleMetadataPlanner.LocaleInput] = []
        for code in localLocales {
            inputs.append(.init(
                locale: code,
                local: try StoreMetadataFiles.read(directory: StoreMetadataFiles.directory(storeRoot: root, locale: code), fields: fields),
                remote: context.remoteValues(code),
                hasVersionLocalization: context.versionLocalization(code) != nil,
                hasAppInfoLocalization: context.appInfoLocalization(code) != nil
            ))
        }

        let plan = try AppleMetadataPlanner.plan(
            inputs: inputs,
            isVersionEditable: context.isVersionEditable,
            isAppInfoEditable: context.appInfo.isEditable,
            versionLabel: "\(context.versionLabel) [\(context.versionState)]",
            appInfoState: context.appInfo.state ?? "UNKNOWN",
            storeLocal: storeLocal,
            storeRemote: storeRemote,
            validCategoryIds: validCategoryIds
        )

        for warning in plan.warnings {
            Log("🟡 \(warning)".yellow)
        }
        Log("\n🔄 Metadata changes for version \(context.versionLabel) (app info \(context.appInfo.state ?? "UNKNOWN")):".bold)
        if plan.changes.isEmpty {
            Log("  No changes — App Store Connect already matches the local files.".dim + "\n")
            return
        }
        for change in plan.changes {
            Log("  [\(change.locale)] ".cyan + StoreMetadataFiles.describe(change))
        }
        if dryRun {
            Log("\n🟡 [Dry Run] No changes were made.".yellow.bold + "\n")
            return
        }

        var updated = 0

        // App-level fields.
        let storeChanges = plan.changes.filter { $0.locale == StoreMetadataFiles.appLevelLabel }
        if !storeChanges.isEmpty {
            let split = AppleMetadataPlanner.splitStore(storeChanges)
            if let copyright = split.copyright {
                try await context.service.updateVersionCopyright(versionId: context.version.id, copyright: copyright)
                updated += 1
            }
            if !split.categories.isEmpty {
                try await context.service.updateAppInfoCategories(appInfoId: context.appInfo.id, categories: split.categories)
                updated += 1
            }
            if !split.review.isEmpty {
                if let reviewDetailId {
                    try await context.service.updateReviewDetail(id: reviewDetailId, changes: split.review)
                } else {
                    try await context.service.createReviewDetail(versionId: context.version.id, values: split.review)
                }
                updated += 1
            }
            if !split.app.isEmpty {
                try await context.service.updateAppLevelValues(appId: context.appId, changes: split.app)
                updated += 1
            }
            Log("  ✔ [app] updated \(storeChanges.count) field(s)".green)
        }

        for code in localLocales {
            let localeChanges = plan.changes.filter { $0.locale == code }
            guard !localeChanges.isEmpty else { continue }
            let (infoChanges, versionChanges) = AppleMetadataPlanner.split(localeChanges)
            if !infoChanges.isEmpty, let localization = context.appInfoLocalization(code) {
                try await context.service.updateAppInfoLocalization(id: localization.id, changes: infoChanges)
                updated += 1
            }
            if !versionChanges.isEmpty, let localization = context.versionLocalization(code) {
                try await context.service.updateVersionLocalization(id: localization.id, changes: versionChanges)
                updated += 1
            }
            Log("  ✔ [\(code)] updated \(localeChanges.count) field(s)".green)
        }
        Log("\n🟢 Metadata upload completed: \(plan.changes.count) field(s) in \(updated) update request(s).".green.bold + "\n")
    }
}

/// Plans App Store metadata updates: diffs, length limits, and editability rules (no network access).
enum AppleMetadataPlanner {
    struct LocaleInput {
        let locale: String
        let local: [String: String]
        let remote: [String: String?]
        let hasVersionLocalization: Bool
        let hasAppInfoLocalization: Bool
    }

    struct Plan: Equatable {
        let changes: [StoreMetadataChange]
        let warnings: [String]
    }

    static func plan(
        inputs: [LocaleInput],
        isVersionEditable: Bool,
        isAppInfoEditable: Bool,
        versionLabel: String,
        appInfoState: String,
        storeLocal: [String: String] = [:],
        storeRemote: [String: String?] = [:],
        validCategoryIds: Set<String>? = nil
    ) throws -> Plan {
        var changes: [StoreMetadataChange] = []
        var warnings: [String] = []
        var errors: [String] = []

        // App-level fields (copyright, categories, App Review details, content rights, accessibility URL).
        let storeChanges = StoreMetadataFiles.diff(
            locale: StoreMetadataFiles.appLevelLabel,
            fields: AppleStoreField.allCases.map(\.field),
            local: storeLocal,
            remote: storeRemote
        )
        errors += StoreMetadataFiles.lengthErrors(locale: StoreMetadataFiles.appLevelLabel, fields: AppleStoreField.allCases.map(\.field), local: storeLocal)
        for change in storeChanges {
            guard let field = AppleStoreField(rawValue: change.field.key) else { continue }
            switch field {
            case _ where field.isCategory:
                if let validCategoryIds, !validCategoryIds.contains(change.local) {
                    errors.append("[app] \(field.field.displayName) '\(change.local)' is not an App Store category ID for this platform (e.g. PRODUCTIVITY, GAMES_ACTION).")
                }
            case .contentRightsDeclaration where !AppleStoreField.contentRightsValues.contains(change.local):
                errors.append("[app] content_rights_declaration must be one of: \(AppleStoreField.contentRightsValues.sorted().joined(separator: ", ")).")
            case .reviewDemoAccountRequired where !["true", "false"].contains(change.local.lowercased()):
                errors.append("[app] review_demo_account_required must be true or false.")
            default:
                break
            }
        }
        let storeLevels = Set(storeChanges.compactMap { AppleStoreField(rawValue: $0.field.key)?.level })
        if storeLevels.contains(.appInfo) && !isAppInfoEditable {
            errors.append("Category changes need an editable app info (current: \(appInfoState)). Create a new version first ('appitool apple versions create').")
        }
        if (storeLevels.contains(.version) || storeLevels.contains(.review)) && !isVersionEditable {
            errors.append("Copyright and App Review details need an editable version (\(versionLabel) is not). Create a new version ('appitool apple versions create') or pass --app-version.")
        }

        for input in inputs {
            var fields: [StoreMetadataField] = []
            if input.hasAppInfoLocalization {
                fields += AppleMetadataField.allCases.filter { $0.level == .appInfo }.map(\.field)
            }
            if input.hasVersionLocalization {
                fields += AppleMetadataField.allCases.filter { $0.level == .version }.map(\.field)
            }
            if fields.isEmpty {
                warnings.append("[\(input.locale)] is not a localization of this app/version; skipped (add the language in App Store Connect first).")
                continue
            }
            errors += StoreMetadataFiles.lengthErrors(locale: input.locale, fields: fields, local: input.local)
            changes += StoreMetadataFiles.diff(locale: input.locale, fields: fields, local: input.local, remote: input.remote)
        }

        let infoKeys = Set(AppleMetadataField.allCases.filter { $0.level == .appInfo }.map(\.rawValue))
        let hasInfoChanges = changes.contains { infoKeys.contains($0.field.key) }
        let versionChangeKeys = Set(changes.map(\.field.key)).subtracting(infoKeys)
        if hasInfoChanges && !isAppInfoEditable {
            errors.append("Name/subtitle/privacy changes need an editable app info (current: \(appInfoState)). Create a new version first ('appitool apple versions create').")
        }
        if !versionChangeKeys.isEmpty && !isVersionEditable && versionChangeKeys != [AppleMetadataField.promotionalText.rawValue] {
            errors.append("Version \(versionLabel) is not editable; only promotional_text can change on a live version. Create a new version ('appitool apple versions create') or pass --app-version.")
        }

        guard errors.isEmpty else {
            throw CommandError("Metadata upload aborted before making changes:\n" + errors.map { "  • \($0)" }.joined(separator: "\n"))
        }
        return Plan(changes: storeChanges + changes, warnings: warnings)
    }

    /// Groups app-level changes by the API object they update.
    static func splitStore(_ changes: [StoreMetadataChange]) -> (
        copyright: String?,
        categories: [AppInfoCategorySlot: String],
        review: ReviewDetailValues,
        app: AppLevelValues
    ) {
        var copyright: String?
        var categories: [AppInfoCategorySlot: String] = [:]
        var review = ReviewDetailValues()
        var app = AppLevelValues()
        for change in changes {
            switch AppleStoreField(rawValue: change.field.key) {
            case .copyright: copyright = change.local
            case .primaryCategory: categories[.primaryCategory] = change.local
            case .primarySubcategoryOne: categories[.primarySubcategoryOne] = change.local
            case .primarySubcategoryTwo: categories[.primarySubcategoryTwo] = change.local
            case .secondaryCategory: categories[.secondaryCategory] = change.local
            case .secondarySubcategoryOne: categories[.secondarySubcategoryOne] = change.local
            case .secondarySubcategoryTwo: categories[.secondarySubcategoryTwo] = change.local
            case .reviewContactFirstName: review.contactFirstName = change.local
            case .reviewContactLastName: review.contactLastName = change.local
            case .reviewContactPhone: review.contactPhone = change.local
            case .reviewContactEmail: review.contactEmail = change.local
            case .reviewNotes: review.notes = change.local
            case .reviewDemoAccountRequired: review.demoAccountRequired = change.local.lowercased() == "true"
            case .reviewDemoAccountName: review.demoAccountName = change.local
            case .reviewDemoAccountPassword: review.demoAccountPassword = change.local
            case .contentRightsDeclaration: app.contentRightsDeclaration = change.local
            case .accessibilityUrl: app.accessibilityUrl = change.local
            case .none: break
            }
        }
        return (copyright, categories, review, app)
    }

    /// Splits one locale's changes into app info and version localization updates.
    static func split(_ changes: [StoreMetadataChange]) -> (AppInfoLocalizationChanges, VersionLocalizationChanges) {
        var info = AppInfoLocalizationChanges()
        var version = VersionLocalizationChanges()
        for change in changes {
            switch AppleMetadataField(rawValue: change.field.key) {
            case .name: info.name = change.local
            case .subtitle: info.subtitle = change.local
            case .privacyPolicyUrl: info.privacyPolicyUrl = change.local
            case .privacyChoicesUrl: info.privacyChoicesUrl = change.local
            case .description: version.description = change.local
            case .keywords: version.keywords = change.local
            case .promotionalText: version.promotionalText = change.local
            case .whatsNew: version.whatsNew = change.local
            case .marketingUrl: version.marketingUrl = change.local
            case .supportUrl: version.supportUrl = change.local
            case .none: break
            }
        }
        return (info, version)
    }
}
