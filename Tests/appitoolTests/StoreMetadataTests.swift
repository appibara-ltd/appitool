import ArgumentParser
import Foundation
import Testing
@testable import appitool
import GoogleServices

@Suite("Store Metadata Tests")
struct StoreMetadataTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appitool-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Metadata files round-trip, skip empty files, and normalize whitespace")
    func filesRoundTrip() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = StoreMetadataFiles.directory(storeRoot: root, locale: "en-US")
        let fields = AppleMetadataField.allCases.map(\.field)

        let written = try StoreMetadataFiles.write(directory: dir, values: [
            (AppleMetadataField.name.field, "My App"),
            (AppleMetadataField.description.field, "Line 1\r\nLine 2\n\n"),
            (AppleMetadataField.subtitle.field, "   "),
            (AppleMetadataField.keywords.field, nil),
        ])
        #expect(written.sorted() == ["description.txt", "name.txt"])

        try "\n".write(to: dir.appendingPathComponent("whats_new.txt"), atomically: true, encoding: .utf8)
        let values = try StoreMetadataFiles.read(directory: dir, fields: fields)
        #expect(values == ["name": "My App", "description": "Line 1\nLine 2"])

        #expect(StoreMetadataFiles.locales(storeRoot: root) == ["en-US"])
        #expect(StoreMetadataFiles.locales(storeRoot: root, localeFilter: "EN-us") == ["en-US"])
        #expect(StoreMetadataFiles.locales(storeRoot: root, localeFilter: "tr").isEmpty)
    }

    @Test("Diff compares only local fields and length limits are enforced")
    func diffAndLimits() {
        let fields = AppleMetadataField.allCases.map(\.field)
        let changes = StoreMetadataFiles.diff(
            locale: "en-US",
            fields: fields,
            local: ["name": "New Name", "keywords": "a,b"],
            remote: ["name": "Old Name", "keywords": "a,b\n", "description": "untouched"]
        )
        #expect(changes.map(\.field.key) == ["name"])
        #expect(StoreMetadataFiles.describe(changes[0]) == "Name: \"Old Name\" → \"New Name\"")

        let errors = StoreMetadataFiles.lengthErrors(
            locale: "en-US",
            fields: fields,
            local: ["name": String(repeating: "x", count: 31), "promotional_text": String(repeating: "y", count: 170)]
        )
        #expect(errors.count == 1)
        #expect(errors[0].contains("Name is 31 characters (limit 30)"))

        let google = StoreMetadataFiles.lengthErrors(
            locale: "en-US",
            fields: GoogleMetadataField.allCases.map(\.field),
            local: ["short_description": String(repeating: "z", count: 81)]
        )
        #expect(google.count == 1)
    }

    private func input(_ local: [String: String], remote: [String: String?] = [:], version: Bool = true, info: Bool = true) -> AppleMetadataPlanner.LocaleInput {
        .init(locale: "en-US", local: local, remote: remote, hasVersionLocalization: version, hasAppInfoLocalization: info)
    }

    @Test("Apple planner enforces editability: live version allows only promotional text")
    func applePlannerEditability() throws {
        // Promotional text alone is allowed on a live version.
        let promo = try AppleMetadataPlanner.plan(
            inputs: [input(["promotional_text": "New promo"])],
            isVersionEditable: false, isAppInfoEditable: false, versionLabel: "1.0.8", appInfoState: "READY_FOR_DISTRIBUTION"
        )
        #expect(promo.changes.map(\.field.key) == ["promotional_text"])

        // Description on a live version is rejected before any change.
        #expect(throws: CommandError.self) {
            _ = try AppleMetadataPlanner.plan(
                inputs: [input(["description": "New"])],
                isVersionEditable: false, isAppInfoEditable: true, versionLabel: "1.0.8", appInfoState: "PREPARE_FOR_SUBMISSION"
            )
        }
        // Name needs an editable app info.
        #expect(throws: CommandError.self) {
            _ = try AppleMetadataPlanner.plan(
                inputs: [input(["name": "New"])],
                isVersionEditable: true, isAppInfoEditable: false, versionLabel: "1.0.9", appInfoState: "READY_FOR_DISTRIBUTION"
            )
        }
        // Unchanged values on a live version are fine (no changes, no error).
        let unchanged = try AppleMetadataPlanner.plan(
            inputs: [input(["name": "Same", "description": "Same"], remote: ["name": "Same", "description": "Same"])],
            isVersionEditable: false, isAppInfoEditable: false, versionLabel: "1.0.8", appInfoState: "READY_FOR_DISTRIBUTION"
        )
        #expect(unchanged.changes.isEmpty)

        // Locales missing remotely are skipped with a warning.
        let missing = try AppleMetadataPlanner.plan(
            inputs: [input(["name": "X"], version: false, info: false)],
            isVersionEditable: true, isAppInfoEditable: true, versionLabel: "1.0.9", appInfoState: "PREPARE_FOR_SUBMISSION"
        )
        #expect(missing.changes.isEmpty)
        #expect(missing.warnings.count == 1)
    }

    @Test("Apple planner splits changes into app info and version updates")
    func applePlannerSplit() throws {
        let plan = try AppleMetadataPlanner.plan(
            inputs: [input(["name": "N", "subtitle": "S", "keywords": "k", "whats_new": "W"])],
            isVersionEditable: true, isAppInfoEditable: true, versionLabel: "1.0.9", appInfoState: "PREPARE_FOR_SUBMISSION"
        )
        let (info, version) = AppleMetadataPlanner.split(plan.changes)
        #expect(info.name == "N")
        #expect(info.subtitle == "S")
        #expect(version.keywords == "k")
        #expect(version.whatsNew == "W")
        #expect(version.description == nil)
        #expect(!version.isPromotionalTextOnly)
    }

    @Test("App-level Apple fields: validation, editability, splitting, and secret masking")
    func appleStoreLevelFields() throws {
        let valid: Set<String> = ["PRODUCTIVITY", "UTILITIES"]

        // Valid changes on editable version + app info.
        let plan = try AppleMetadataPlanner.plan(
            inputs: [],
            isVersionEditable: true, isAppInfoEditable: true, versionLabel: "1.0.9", appInfoState: "PREPARE_FOR_SUBMISSION",
            storeLocal: [
                "copyright": "2026 Example",
                "primary_category": "PRODUCTIVITY",
                "review_contact_email": "review@example.com",
                "review_demo_account_required": "TRUE",
                "review_demo_account_password": "s3cret",
                "content_rights_declaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT",
            ],
            storeRemote: ["copyright": "2025 Example", "primary_category": "UTILITIES"],
            validCategoryIds: valid
        )
        #expect(plan.changes.allSatisfy { $0.locale == StoreMetadataFiles.appLevelLabel })
        let split = AppleMetadataPlanner.splitStore(plan.changes)
        #expect(split.copyright == "2026 Example")
        #expect(split.categories[.primaryCategory] == "PRODUCTIVITY")
        #expect(split.review.contactEmail == "review@example.com")
        #expect(split.review.demoAccountRequired == true)
        #expect(split.review.demoAccountPassword == "s3cret")
        #expect(split.app.contentRightsDeclaration == "DOES_NOT_USE_THIRD_PARTY_CONTENT")

        let password = try #require(plan.changes.first { $0.field.key == "review_demo_account_password" })
        #expect(!StoreMetadataFiles.describe(password).contains("s3cret"))
        #expect(!AppleStoreField.fileFields.contains { $0.key == "review_demo_account_password" })

        // Invalid values are rejected before any change.
        for local in [
            ["primary_category": "NOT_A_CATEGORY"],
            ["content_rights_declaration": "MAYBE"],
            ["review_demo_account_required": "yes"],
        ] {
            #expect(throws: CommandError.self) {
                _ = try AppleMetadataPlanner.plan(
                    inputs: [], isVersionEditable: true, isAppInfoEditable: true, versionLabel: "1.0.9", appInfoState: "PREPARE_FOR_SUBMISSION",
                    storeLocal: local, validCategoryIds: valid
                )
            }
        }

        // Editability: categories need the editable app info; copyright/review need the editable version;
        // app-level attributes (content rights, accessibility URL) work on a live version.
        #expect(throws: CommandError.self) {
            _ = try AppleMetadataPlanner.plan(
                inputs: [], isVersionEditable: true, isAppInfoEditable: false, versionLabel: "1.0.9", appInfoState: "READY_FOR_DISTRIBUTION",
                storeLocal: ["primary_category": "PRODUCTIVITY"], validCategoryIds: valid
            )
        }
        #expect(throws: CommandError.self) {
            _ = try AppleMetadataPlanner.plan(
                inputs: [], isVersionEditable: false, isAppInfoEditable: true, versionLabel: "1.0.8", appInfoState: "PREPARE_FOR_SUBMISSION",
                storeLocal: ["copyright": "2026"]
            )
        }
        let live = try AppleMetadataPlanner.plan(
            inputs: [], isVersionEditable: false, isAppInfoEditable: false, versionLabel: "1.0.8", appInfoState: "READY_FOR_DISTRIBUTION",
            storeLocal: ["accessibility_url": "https://example.com/a11y"]
        )
        #expect(live.changes.map(\.field.key) == ["accessibility_url"])
    }

    @Test("App-level metadata folder is not treated as a locale; Google details patch has only changed fields")
    func storeFolderAndGoogleDetails() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try StoreMetadataFiles.write(directory: StoreMetadataFiles.storeDirectory(storeRoot: root), values: [(GoogleStoreField.contactEmail.field, "a@b.com")])
        try StoreMetadataFiles.write(directory: StoreMetadataFiles.directory(storeRoot: root, locale: "en-US"), values: [(GoogleMetadataField.title.field, "T")])
        #expect(StoreMetadataFiles.locales(storeRoot: root) == ["en-US"])
        #expect(StoreMetadataFiles.hasStoreDirectory(storeRoot: root))

        let changes = StoreMetadataFiles.diff(
            locale: StoreMetadataFiles.appLevelLabel,
            fields: GoogleStoreField.allCases.map(\.field),
            local: ["contact_email": "new@b.com", "contact_website": "https://same.example"],
            remote: ["contact_email": "old@b.com", "contact_website": "https://same.example"]
        )
        let details = GooglePlayAppDetails.changes(from: changes)
        #expect(details.contactEmail == "new@b.com")
        #expect(details.contactWebsite == nil)
        #expect(details.defaultLanguage == nil)
    }

    @Test("Google patch body only contains changed fields")
    func googleListingChanges() {
        let changes = StoreMetadataFiles.diff(
            locale: "en-US",
            fields: GoogleMetadataField.allCases.map(\.field),
            local: ["title": "New Title", "full_description": "Same"],
            remote: ["title": "Old", "full_description": "Same"]
        )
        let body = GoogleMetadataUploadCommand.listingChanges(language: "en-US", changes: changes)
        #expect(body.title == "New Title")
        #expect(body.fullDescription == nil)
        #expect(body.shortDescription == nil)
    }

    @Test("metadata commands parse, and asset uploads ignore <locale>/metadata/ folders")
    func commandsAndAssetTreeIsolation() throws {
        _ = try appitool.parseAsRoot(["apple", "metadata", "list", "--locale", "en-US"])
        _ = try appitool.parseAsRoot(["apple", "metadata", "download", "-o", "./out", "--dry-run"])
        _ = try appitool.parseAsRoot(["apple", "metadata", "upload", "--dry-run", "./store/apple"])
        _ = try appitool.parseAsRoot(["google", "metadata", "upload", "--validate-only", "--changes-not-sent-for-review"])

        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let shots = root.appendingPathComponent("en-US/iphone-67")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shots.appendingPathComponent("01.png"))
        try StoreMetadataFiles.write(
            directory: StoreMetadataFiles.directory(storeRoot: root, locale: "en-US"),
            values: [(AppleMetadataField.name.field, "My App")]
        )

        let (_, batches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [root.path],
            defaultDirectory: { root },
            localeFilter: nil,
            typeFilter: nil,
            storeDisplayName: "App Store Connect",
            downloadHintCommand: "appitool apple assets download",
            parseType: AppleAssetSlot.parse
        )
        #expect(batches.map(\.type.key) == ["iphone-67"])
    }
}
