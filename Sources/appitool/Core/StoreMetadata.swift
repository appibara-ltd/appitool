import Foundation

/// One editable store listing text field, stored locally as `<root>/<store>/<locale>/metadata/<key>.txt`.
struct StoreMetadataField: Sendable, Equatable, Hashable {
    /// File stem (`promotional_text` → `promotional_text.txt`).
    let key: String
    let displayName: String
    let maxLength: Int?
    /// Short fields are shown inline in diffs; long ones are summarized.
    let isShort: Bool
    /// Secrets never come from or go to files and are masked in logs.
    var isSecret: Bool = false
}

/// App-level (not per-locale) App Store fields, stored as `<root>/apple/metadata/<key>.txt`.
enum AppleStoreField: String, CaseIterable, Sendable {
    case copyright
    case primaryCategory = "primary_category"
    case primarySubcategoryOne = "primary_subcategory_one"
    case primarySubcategoryTwo = "primary_subcategory_two"
    case secondaryCategory = "secondary_category"
    case secondarySubcategoryOne = "secondary_subcategory_one"
    case secondarySubcategoryTwo = "secondary_subcategory_two"
    case reviewContactFirstName = "review_contact_first_name"
    case reviewContactLastName = "review_contact_last_name"
    case reviewContactPhone = "review_contact_phone"
    case reviewContactEmail = "review_contact_email"
    case reviewNotes = "review_notes"
    case reviewDemoAccountRequired = "review_demo_account_required"
    case reviewDemoAccountName = "review_demo_account_name"
    /// Read from `APPLE_REVIEW_DEMO_PASSWORD`, never from a file.
    case reviewDemoAccountPassword = "review_demo_account_password"
    case contentRightsDeclaration = "content_rights_declaration"
    case accessibilityUrl = "accessibility_url"

    enum Level: Sendable { case version, appInfo, review, app }

    static let contentRightsValues: Set<String> = ["DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT"]

    var level: Level {
        switch self {
        case .copyright: return .version
        case .primaryCategory, .primarySubcategoryOne, .primarySubcategoryTwo,
             .secondaryCategory, .secondarySubcategoryOne, .secondarySubcategoryTwo: return .appInfo
        case .contentRightsDeclaration, .accessibilityUrl: return .app
        default: return .review
        }
    }

    var isCategory: Bool { level == .appInfo }

    var field: StoreMetadataField {
        let name: String
        var maxLength: Int?
        var isShort = true
        switch self {
        case .copyright: name = "Copyright"
        case .primaryCategory: name = "Primary Category"
        case .primarySubcategoryOne: name = "Primary Subcategory 1"
        case .primarySubcategoryTwo: name = "Primary Subcategory 2"
        case .secondaryCategory: name = "Secondary Category"
        case .secondarySubcategoryOne: name = "Secondary Subcategory 1"
        case .secondarySubcategoryTwo: name = "Secondary Subcategory 2"
        case .reviewContactFirstName: name = "Review Contact First Name"
        case .reviewContactLastName: name = "Review Contact Last Name"
        case .reviewContactPhone: name = "Review Contact Phone"
        case .reviewContactEmail: name = "Review Contact Email"
        case .reviewNotes: name = "Review Notes"; maxLength = 4000; isShort = false
        case .reviewDemoAccountRequired: name = "Demo Account Required"
        case .reviewDemoAccountName: name = "Demo Account Name"
        case .reviewDemoAccountPassword: name = "Demo Account Password"
        case .contentRightsDeclaration: name = "Content Rights Declaration"
        case .accessibilityUrl: name = "Accessibility URL"
        }
        return StoreMetadataField(key: rawValue, displayName: name, maxLength: maxLength, isShort: isShort, isSecret: self == .reviewDemoAccountPassword)
    }

    /// Fields stored in files (everything except secrets).
    static var fileFields: [StoreMetadataField] {
        allCases.map(\.field).filter { !$0.isSecret }
    }
}

/// App-level (not per-locale) Google Play fields, stored as `<root>/google/metadata/<key>.txt`.
enum GoogleStoreField: String, CaseIterable, Sendable {
    case contactEmail = "contact_email"
    case contactPhone = "contact_phone"
    case contactWebsite = "contact_website"
    case defaultLanguage = "default_language"

    var field: StoreMetadataField {
        switch self {
        case .contactEmail: return .init(key: rawValue, displayName: "Contact Email", maxLength: nil, isShort: true)
        case .contactPhone: return .init(key: rawValue, displayName: "Contact Phone", maxLength: nil, isShort: true)
        case .contactWebsite: return .init(key: rawValue, displayName: "Contact Website", maxLength: nil, isShort: true)
        case .defaultLanguage: return .init(key: rawValue, displayName: "Default Language", maxLength: nil, isShort: true)
        }
    }
}

/// App Store Connect metadata fields and where they live.
enum AppleMetadataField: String, CaseIterable, Sendable {
    // App info localization (name, subtitle, privacy) — goes live with the next version.
    case name
    case subtitle
    case privacyPolicyUrl = "privacy_policy_url"
    case privacyChoicesUrl = "privacy_choices_url"
    // Version localization.
    case description
    case keywords
    case promotionalText = "promotional_text"
    case whatsNew = "whats_new"
    case marketingUrl = "marketing_url"
    case supportUrl = "support_url"

    enum Level: Sendable { case appInfo, version }

    var level: Level {
        switch self {
        case .name, .subtitle, .privacyPolicyUrl, .privacyChoicesUrl: return .appInfo
        default: return .version
        }
    }

    var field: StoreMetadataField {
        switch self {
        case .name: return .init(key: rawValue, displayName: "Name", maxLength: 30, isShort: true)
        case .subtitle: return .init(key: rawValue, displayName: "Subtitle", maxLength: 30, isShort: true)
        case .privacyPolicyUrl: return .init(key: rawValue, displayName: "Privacy Policy URL", maxLength: nil, isShort: true)
        case .privacyChoicesUrl: return .init(key: rawValue, displayName: "Privacy Choices URL", maxLength: nil, isShort: true)
        case .description: return .init(key: rawValue, displayName: "Description", maxLength: 4000, isShort: false)
        case .keywords: return .init(key: rawValue, displayName: "Keywords", maxLength: 100, isShort: true)
        case .promotionalText: return .init(key: rawValue, displayName: "Promotional Text", maxLength: 170, isShort: false)
        case .whatsNew: return .init(key: rawValue, displayName: "What's New", maxLength: 4000, isShort: false)
        case .marketingUrl: return .init(key: rawValue, displayName: "Marketing URL", maxLength: nil, isShort: true)
        case .supportUrl: return .init(key: rawValue, displayName: "Support URL", maxLength: nil, isShort: true)
        }
    }
}

/// Google Play store listing fields.
enum GoogleMetadataField: String, CaseIterable, Sendable {
    case title
    case shortDescription = "short_description"
    case fullDescription = "full_description"
    case video

    var field: StoreMetadataField {
        switch self {
        case .title: return .init(key: rawValue, displayName: "Title", maxLength: 30, isShort: true)
        case .shortDescription: return .init(key: rawValue, displayName: "Short Description", maxLength: 80, isShort: true)
        case .fullDescription: return .init(key: rawValue, displayName: "Full Description", maxLength: 4000, isShort: false)
        case .video: return .init(key: rawValue, displayName: "Video URL", maxLength: nil, isShort: true)
        }
    }
}

/// A difference between a local metadata file and the store value.
struct StoreMetadataChange: Sendable, Equatable {
    let locale: String
    let field: StoreMetadataField
    let remote: String
    let local: String
}

/// Reads, writes, diffs, and validates local metadata text files.
enum StoreMetadataFiles {
    static let folderName = "metadata"

    /// Label used for app-level (not per-locale) changes.
    static let appLevelLabel = "app"

    /// `<storeRoot>/<locale>/metadata/`
    static func directory(storeRoot: URL, locale: String) -> URL {
        storeRoot.appendingPathComponent(locale).appendingPathComponent(folderName)
    }

    /// `<storeRoot>/metadata/` (app-level fields such as copyright, categories, review and contact details).
    static func storeDirectory(storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent(folderName)
    }

    /// `true` when `storeRoot/metadata/` exists.
    static func hasStoreDirectory(storeRoot: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: storeDirectory(storeRoot: storeRoot).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Normalizes a value for comparison and storage (trims surrounding whitespace and newlines; Windows newlines → `\n`).
    static func normalize(_ raw: String?) -> String {
        (raw ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locales under `storeRoot` that have a `metadata/` folder, sorted.
    static func locales(storeRoot: URL, localeFilter: String? = nil) -> [String] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: storeRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .filter { locale in
                if locale == folderName { return false }  // app-level <root>/metadata/ folder
                if let localeFilter, locale.caseInsensitiveCompare(localeFilter) != .orderedSame { return false }
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: directory(storeRoot: storeRoot, locale: locale).path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
    }

    /// Reads `<key>.txt` files for `fields` from `directory`. Missing and empty (after trimming) files are omitted.
    static func read(directory: URL, fields: [StoreMetadataField]) throws -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            let url = directory.appendingPathComponent("\(field.key).txt")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = normalize(try String(contentsOf: url, encoding: .utf8))
            if !text.isEmpty {
                values[field.key] = text
            }
        }
        return values
    }

    /// Writes non-empty values as `<key>.txt` (with a trailing newline); returns the written file names.
    @discardableResult
    static func write(directory: URL, values: [(field: StoreMetadataField, value: String?)]) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for (field, value) in values {
            let text = normalize(value)
            guard !text.isEmpty else { continue }
            let name = "\(field.key).txt"
            try (text + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            written.append(name)
        }
        return written
    }

    /// Fields whose local value differs from the remote value (only fields present locally are compared).
    static func diff(
        locale: String,
        fields: [StoreMetadataField],
        local: [String: String],
        remote: [String: String?]
    ) -> [StoreMetadataChange] {
        fields.compactMap { field in
            guard let localValue = local[field.key] else { return nil }
            let remoteValue = normalize(remote[field.key] ?? nil)
            return localValue == remoteValue ? nil : StoreMetadataChange(locale: locale, field: field, remote: remoteValue, local: localValue)
        }
    }

    /// Length-limit violations (in characters) for local values.
    static func lengthErrors(locale: String, fields: [StoreMetadataField], local: [String: String]) -> [String] {
        fields.compactMap { field in
            guard let maxLength = field.maxLength, let value = local[field.key], value.count > maxLength else { return nil }
            return "[\(locale)] \(field.displayName) is \(value.count) characters (limit \(maxLength)): \(field.key).txt"
        }
    }

    /// One-line description of a change for logs.
    static func describe(_ change: StoreMetadataChange) -> String {
        if change.field.isSecret {
            return "\(change.field.displayName): (updated, value hidden)"
        }
        if change.field.isShort {
            let old = change.remote.isEmpty ? "(empty)" : "\"\(change.remote)\""
            return "\(change.field.displayName): \(old) → \"\(change.local)\""
        }
        return "\(change.field.displayName): \(change.remote.count) → \(change.local.count) characters"
    }
}
