import Foundation
import OpenAPIRuntime
import Testing
@testable import appitool
import AppStoreConnectAPI
@testable import AppleServices

// MARK: - Store details (categories, app-level values, review details)

@Suite("AppStoreService StoreDetails Coverage")
struct AppStoreServiceStoreDetailsCoverageTests {

    @Test("Value types report emptiness")
    func valueTypes() {
        #expect(ReviewDetailValues().isEmpty)
        #expect(!ReviewDetailValues(notes: "n").isEmpty)
        #expect(AppLevelValues().isEmpty)
        #expect(!AppLevelValues(accessibilityUrl: "u").isEmpty)
        #expect(AppInfoCategorySlot.allCases.count == 6)
    }

    @Test("fetchAppInfoCategories reads every category slot")
    func fetchCategories() async throws {
        func rel(_ id: String) -> String { #"{"data":{"type":"appCategories","id":"\#(id)"}}"# }
        let relationships = """
        {"primaryCategory":\(rel("GAMES")),"primarySubcategoryOne":\(rel("GAMES_ACTION")),"primarySubcategoryTwo":\(rel("GAMES_PUZZLE")),
         "secondaryCategory":\(rel("UTILITIES")),"secondarySubcategoryOne":\(rel("S1")),"secondarySubcategoryTwo":\(rel("S2"))}
        """
        let router = StubRouter()
            .on("GET", "appInfos_getInstance",
                .ok(ASCStub.single(ASCStub.res("appInfos", "ai1", "{}", rel: relationships))),
                .ok(ASCStub.single(ASCStub.res("appInfos", "ai1"))))
        let service = try ASCStub.service(router)
        let categories = try await service.fetchAppInfoCategories(appInfoId: "ai1")
        #expect(categories[.primaryCategory] == "GAMES")
        #expect(categories[.primarySubcategoryOne] == "GAMES_ACTION")
        #expect(categories[.primarySubcategoryTwo] == "GAMES_PUZZLE")
        #expect(categories[.secondaryCategory] == "UTILITIES")
        #expect(categories[.secondarySubcategoryOne] == "S1")
        #expect(categories[.secondarySubcategoryTwo] == "S2")
        #expect(router.log.requests[0].query.contains("include="))
        #expect(try await service.fetchAppInfoCategories(appInfoId: "ai1").isEmpty)
    }

    @Test("updateAppInfoCategories sends only provided slots")
    func updateCategories() async throws {
        let router = StubRouter()
            .on("PATCH", "appInfos_updateInstance", .ok(ASCStub.single(ASCStub.res("appInfos", "ai1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        try await service.updateAppInfoCategories(appInfoId: "ai1", categories: [.primaryCategory: "GAMES", .secondaryCategory: "UTILITIES"])
        let data = ASCStub.json(router.log.requests[0].body)["data"] as? [String: Any]
        let rel = data?["relationships"] as? [String: Any] ?? [:]
        #expect(((rel["primaryCategory"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "GAMES")
        #expect(rel["primarySubcategoryOne"] == nil)
        await #expect(throws: AppStoreServiceError.self) {
            try await service.updateAppInfoCategories(appInfoId: "ai1", categories: [:])
        }
    }

    @Test("fetchCategoryIds merges categories and included subcategories")
    func categoryIds() async throws {
        let router = StubRouter()
            .on("GET", "appCategories_getCollection",
                .ok(ASCStub.list([ASCStub.res("appCategories", "GAMES")], included: [ASCStub.res("appCategories", "GAMES_ACTION")])),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        #expect(try await service.fetchCategoryIds(platform: .IOS) == ["GAMES", "GAMES_ACTION"])
        #expect(router.log.requests[0].query.contains("IOS"))
        #expect(try await service.fetchCategoryIds(platform: .MAC_OS).isEmpty)
    }

    @Test("App-level values are read and updated")
    func appLevelValues() async throws {
        let router = StubRouter()
            .on("GET", "apps_getInstance",
                .ok(ASCStub.single(ASCStub.res("apps", "a1", #"{"contentRightsDeclaration":"USES_THIRD_PARTY_CONTENT","accessibilityUrl":"https://a11y"}"#))),
                ASCStub.undocumented)
            .on("PATCH", "apps_updateInstance", .ok(ASCStub.single(ASCStub.res("apps", "a1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let values = try await service.fetchAppLevelValues(appId: "a1")
        #expect(values == AppLevelValues(contentRightsDeclaration: "USES_THIRD_PARTY_CONTENT", accessibilityUrl: "https://a11y"))
        #expect(try await service.fetchAppLevelValues(appId: "a1").isEmpty)

        try await service.updateAppLevelValues(appId: "a1", changes: AppLevelValues(contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT"))
        let attrs = ASCStub.dataAttrs(router.log.requests.last)
        #expect(attrs["contentRightsDeclaration"] as? String == "DOES_NOT_USE_THIRD_PARTY_CONTENT")
        await #expect(throws: AppStoreServiceError.self) {
            try await service.updateAppLevelValues(appId: "a1", changes: AppLevelValues(accessibilityUrl: "u"))
        }
    }

    @Test("updateVersionCopyright patches the version")
    func copyright() async throws {
        let router = StubRouter()
            .on("PATCH", "appStoreVersions_updateInstance", .ok(ASCStub.single(ASCStub.res("appStoreVersions", "v1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        try await service.updateVersionCopyright(versionId: "v1", copyright: "2026 Me")
        #expect(ASCStub.dataAttrs(router.log.requests[0])["copyright"] as? String == "2026 Me")
        await #expect(throws: AppStoreServiceError.self) {
            try await service.updateVersionCopyright(versionId: "v1", copyright: "x")
        }
    }

    @Test("fetchReviewDetail decodes details and treats 404 / null data as missing")
    func fetchReviewDetail() async throws {
        let attrs = #"{"contactFirstName":"A","contactLastName":"B","contactPhone":"1","contactEmail":"a@b.c","demoAccountName":"demo","demoAccountPassword":"pw","demoAccountRequired":true,"notes":"n"}"#
        let router = StubRouter()
            .on("GET", "appStoreVersions_appStoreReviewDetail_getToOneRelated",
                .ok(ASCStub.single(ASCStub.res("appStoreReviewDetails", "rd1", attrs))),
                ASCStub.notFound,
                .ok(#"{"data":null,"links":{"self":"https://x"}}"#),
                ASCStub.undocumented,
                ASCStub.serverError)
        let service = try ASCStub.service(router)
        let detail = try #require(try await service.fetchReviewDetail(versionId: "v1"))
        #expect(detail.id == "rd1")
        #expect(detail.values == ReviewDetailValues(
            contactFirstName: "A", contactLastName: "B", contactPhone: "1", contactEmail: "a@b.c",
            demoAccountName: "demo", demoAccountPassword: "pw", demoAccountRequired: true, notes: "n"
        ))
        #expect(try await service.fetchReviewDetail(versionId: "v1") == nil)
        #expect(try await service.fetchReviewDetail(versionId: "v1") == nil)
        #expect(try await service.fetchReviewDetail(versionId: "v1") == nil)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.fetchReviewDetail(versionId: "v1")
        }
        #expect(AppStoreService.isNullDataResponse(AppStoreServiceError.notFound("x")) == false)
    }

    @Test("Review details are created and updated")
    func createUpdateReviewDetail() async throws {
        let router = StubRouter()
            .on("POST", "appStoreReviewDetails_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("appStoreReviewDetails", "rd1"))), ASCStub.undocumented)
            .on("PATCH", "appStoreReviewDetails_updateInstance", .ok(ASCStub.single(ASCStub.res("appStoreReviewDetails", "rd1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        try await service.createReviewDetail(versionId: "v1", values: ReviewDetailValues(contactEmail: "a@b.c", demoAccountRequired: false))
        let created = ASCStub.json(router.log.requests[0].body)["data"] as? [String: Any]
        #expect((created?["attributes"] as? [String: Any])?["contactEmail"] as? String == "a@b.c")
        let version = ((created?["relationships"] as? [String: Any])?["appStoreVersion"] as? [String: Any])?["data"] as? [String: Any]
        #expect(version?["id"] as? String == "v1")
        await #expect(throws: AppStoreServiceError.self) {
            try await service.createReviewDetail(versionId: "v1", values: ReviewDetailValues())
        }

        try await service.updateReviewDetail(id: "rd1", changes: ReviewDetailValues(notes: "hello"))
        #expect(ASCStub.dataAttrs(router.log.requests[2])["notes"] as? String == "hello")
        await #expect(throws: AppStoreServiceError.self) {
            try await service.updateReviewDetail(id: "rd1", changes: ReviewDetailValues())
        }
    }
}

// MARK: - Metadata (versions, app infos, localizations)

@Suite("AppStoreService Metadata Coverage")
struct AppStoreServiceMetadataCoverageTests {

    @Test("Change value types report emptiness and promotional-only edits")
    func valueTypes() {
        #expect(AppInfoLocalizationChanges().isEmpty)
        #expect(!AppInfoLocalizationChanges(subtitle: "s").isEmpty)
        #expect(VersionLocalizationChanges().isEmpty)
        #expect(VersionLocalizationChanges(promotionalText: "p").isPromotionalTextOnly)
        #expect(!VersionLocalizationChanges(promotionalText: "p", whatsNew: "w").isPromotionalTextOnly)
        #expect(!VersionLocalizationChanges(keywords: "k").isEmpty)
    }

    @Test("createAppStoreVersion posts attributes and rejects unexpected responses")
    func createVersion() async throws {
        let router = StubRouter()
            .on("POST", "appStoreVersions_createInstance",
                ASCStub.created(ASCStub.single(ASCStub.res("appStoreVersions", "v2", #"{"versionString":"2.0"}"#))),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let version = try await service.createAppStoreVersion(
            appId: "a1", platform: .IOS, versionString: "2.0", releaseType: "MANUAL",
            earliestReleaseDate: Date(timeIntervalSince1970: 1_700_000_000), copyright: "2026"
        )
        #expect(version.id == "v2")
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["releaseType"] as? String == "MANUAL")
        #expect(attrs["copyright"] as? String == "2026")
        #expect((attrs["earliestReleaseDate"] as? String)?.hasPrefix("2023-11-14T22:13:20") == true)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createAppStoreVersion(appId: "a1", platform: .IOS, versionString: "3.0")
        }
    }

    @Test("deleteAppStoreVersion maps 204, 404 and unexpected responses")
    func deleteVersion() async throws {
        let router = StubRouter()
            .on("DELETE", "appStoreVersions_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.undocumented)
        let service = try ASCStub.service(router)
        #expect(try await service.deleteAppStoreVersion(id: "v1") == true)
        #expect(try await service.deleteAppStoreVersion(id: "v1") == false)
        await #expect(throws: AppStoreServiceError.self) {
            try await service.deleteAppStoreVersion(id: "v1")
        }
    }

    @Test("resolveAppInfo prefers editable, then live, then first app info")
    func resolveAppInfo() async throws {
        let router = StubRouter()
            .on("GET", "apps_appInfos_getToManyRelated",
                .ok(ASCStub.list([
                    ASCStub.res("appInfos", "live", #"{"state":"READY_FOR_DISTRIBUTION"}"#),
                    ASCStub.res("appInfos", "edit", #"{"state":"PREPARE_FOR_SUBMISSION"}"#),
                ])),
                .ok(ASCStub.list([
                    ASCStub.res("appInfos", "review", #"{"state":"IN_REVIEW"}"#),
                    ASCStub.res("appInfos", "live", #"{"state":"READY_FOR_DISTRIBUTION"}"#),
                ])),
                .ok(ASCStub.list([ASCStub.res("appInfos", "first")])),
                .ok(ASCStub.list([])),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let editable = try await service.resolveAppInfo(appId: "a1")
        #expect(editable.id == "edit")
        #expect(editable.isEditable)
        #expect(try await service.resolveAppInfo(appId: "a1").id == "live")
        let first = try await service.resolveAppInfo(appId: "a1")
        #expect(first.id == "first")
        #expect(first.isEditable == false)
        do {
            _ = try await service.resolveAppInfo(appId: "a1")
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound {}
        #expect(try await service.fetchAppInfos(appId: "a1").isEmpty)
    }

    @Test("App info localizations are listed and updated")
    func appInfoLocalizations() async throws {
        let router = StubRouter()
            .on("GET", "appInfos_appInfoLocalizations_getToManyRelated",
                .ok(ASCStub.list([
                    ASCStub.res("appInfoLocalizations", "l1", #"{"locale":"en-US","name":"App","subtitle":"Sub","privacyPolicyUrl":"https://p","privacyChoicesUrl":"https://c"}"#),
                    ASCStub.res("appInfoLocalizations", "l2"),
                ])),
                ASCStub.undocumented)
            .on("PATCH", "appInfoLocalizations_updateInstance", .ok(ASCStub.single(ASCStub.res("appInfoLocalizations", "l1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let locs = try await service.fetchAppInfoLocalizations(appInfoId: "ai1")
        #expect(locs.count == 2)
        #expect(locs[0] == AppInfoLocalizationValues(id: "l1", locale: "en-US", name: "App", subtitle: "Sub", privacyPolicyUrl: "https://p", privacyChoicesUrl: "https://c"))
        #expect(locs[1].locale == "l2")
        #expect(try await service.fetchAppInfoLocalizations(appInfoId: "ai1").isEmpty)

        try await service.updateAppInfoLocalization(id: "l1", changes: AppInfoLocalizationChanges(name: "New"))
        #expect(ASCStub.dataAttrs(router.log.requests.last)["name"] as? String == "New")
        await #expect(throws: AppStoreServiceError.self) {
            try await service.updateAppInfoLocalization(id: "l1", changes: AppInfoLocalizationChanges(subtitle: "x"))
        }
    }

    @Test("updateVersionLocalization patches fields and rejects unexpected responses")
    func versionLocalization() async throws {
        let router = StubRouter()
            .on("PATCH", "appStoreVersionLocalizations_updateInstance",
                .ok(ASCStub.single(ASCStub.res("appStoreVersionLocalizations", "vl1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        try await service.updateVersionLocalization(id: "vl1", changes: VersionLocalizationChanges(description: "d", keywords: "k", marketingUrl: "m", promotionalText: "p", supportUrl: "s", whatsNew: "w"))
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["description"] as? String == "d")
        #expect(attrs["whatsNew"] as? String == "w")
        await #expect(throws: AppStoreServiceError.self) {
            try await service.updateVersionLocalization(id: "vl1", changes: VersionLocalizationChanges(keywords: "k"))
        }
    }
}

// MARK: - Build uploads & TestFlight what-to-test

@Suite("AppStoreService BuildUploads Coverage")
struct AppStoreServiceBuildUploadsCoverageTests {

    @Test("createBuildUpload posts version info and handles unexpected responses")
    func createBuildUpload() async throws {
        let router = StubRouter()
            .on("POST", "buildUploads_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("buildUploads", "bu1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let id = try await service.createBuildUpload(appId: "a1", version: "1.2.3", buildNumber: "45", platform: .macOS)
        #expect(id == "bu1")
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["cfBundleShortVersionString"] as? String == "1.2.3")
        #expect(attrs["cfBundleVersion"] as? String == "45")
        #expect(attrs["platform"] as? String == "MAC_OS")
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createBuildUpload(appId: "a1", version: "1", buildNumber: "1")
        }
    }

    @Test("createBuildUploadFile maps upload operations and rejects empty or unexpected responses")
    func createBuildUploadFile() async throws {
        let ops = """
        {"fileName":"App.ipa","uploadOperations":[
          {"method":"PUT","url":"https://upload/1","offset":0,"length":10,"requestHeaders":[{"name":"Content-Type","value":"application/octet-stream"},{"name":"X-Missing"}]},
          {"method":"PUT","url":"https://upload/2","length":5},
          {"method":"PUT","url":"https://upload/3"}
        ]}
        """
        let router = StubRouter()
            .on("POST", "buildUploadFiles_createInstance",
                ASCStub.created(ASCStub.single(ASCStub.res("buildUploadFiles", "f1", ops))),
                ASCStub.created(ASCStub.single(ASCStub.res("buildUploadFiles", "f2"))),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let reservation = try await service.createBuildUploadFile(buildUploadId: "bu1", fileName: "App.ipa", fileSize: 15)
        #expect(reservation.id == "f1")
        #expect(reservation.operations.count == 2)
        #expect(reservation.operations[0].headers.count == 1)
        #expect(reservation.operations[0].headers.first?.name == "Content-Type")
        #expect(reservation.operations[1].offset == 0)
        #expect(reservation.operations[1].length == 5)
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["uti"] as? String == "com.apple.ipa")
        #expect(attrs["assetType"] as? String == "ASSET")
        #expect(attrs["fileSize"] as? Int == 15)

        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createBuildUploadFile(buildUploadId: "bu1", fileName: "App.ipa", fileSize: 15)
        }
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createBuildUploadFile(buildUploadId: "bu1", fileName: "App.ipa", fileSize: 15)
        }
    }

    @Test("commitBuildUploadFile marks the file uploaded")
    func commit() async throws {
        let router = StubRouter()
            .on("PATCH", "buildUploadFiles_updateInstance", .ok(ASCStub.single(ASCStub.res("buildUploadFiles", "f1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        try await service.commitBuildUploadFile(id: "f1")
        try await service.commitBuildUploadFile(id: "f1")
        #expect(ASCStub.dataAttrs(router.log.requests[0])["uploaded"] as? Bool == true)
        #expect(router.log.requests[0].path.hasSuffix("/v1/buildUploadFiles/f1") == true)
    }

    @Test("fetchBuildUpload maps state, errors, warnings, and build ID")
    func fetchBuildUpload() async throws {
        let attrs = """
        {"state":{"state":"FAILED","errors":[{"code":"E1","description":"Bad binary"},{"description":"Only description"}],"warnings":[{"code":"W1"}]}}
        """
        let rel = #"{"build":{"data":{"type":"builds","id":"build-1"}}}"#
        let router = StubRouter()
            .on("GET", "buildUploads_getInstance",
                .ok(ASCStub.single(ASCStub.res("buildUploads", "bu1", attrs, rel: rel))),
                .ok(ASCStub.single(ASCStub.res("buildUploads", "bu2"))),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let status = try await service.fetchBuildUpload(id: "bu1")
        #expect(status.state == .failed)
        #expect(status.errors == ["E1: Bad binary", "Only description"])
        #expect(status.warnings == ["W1"])
        #expect(status.buildId == "build-1")
        let unknown = try await service.fetchBuildUpload(id: "bu2")
        #expect(unknown.state == .unknown)
        #expect(unknown.errors.isEmpty)
        #expect(unknown.buildId == nil)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.fetchBuildUpload(id: "bu3")
        }
    }

    @Test("setWhatsNew updates an existing localization or creates a new one")
    func setWhatsNew() async throws {
        let router = StubRouter()
            .on("GET", "builds_betaBuildLocalizations_getToManyRelated",
                .ok(ASCStub.list([ASCStub.res("betaBuildLocalizations", "bl-en", #"{"locale":"en-US"}"#)])),
                .ok(ASCStub.list([ASCStub.res("betaBuildLocalizations", "bl-en", #"{"locale":"en-US"}"#)])),
                ASCStub.undocumented)
            .on("PATCH", "betaBuildLocalizations_updateInstance", .ok(ASCStub.single(ASCStub.res("betaBuildLocalizations", "bl-en"))), ASCStub.undocumented)
            .on("POST", "betaBuildLocalizations_createInstance", ASCStub.created(ASCStub.single(ASCStub.res("betaBuildLocalizations", "bl-de"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)

        try await service.setWhatsNew(buildId: "b1", whatsNew: "Fixes", locale: "en-US")
        let patch = try #require(router.log.first { $0.operationID == "betaBuildLocalizations_updateInstance" })
        #expect(ASCStub.dataAttrs(patch)["whatsNew"] as? String == "Fixes")
        #expect(patch.path.hasSuffix("/v1/betaBuildLocalizations/bl-en") == true)

        try await service.setWhatsNew(buildId: "b1", whatsNew: "Neu", locale: "de-DE")
        let create = try #require(router.log.first { $0.operationID == "betaBuildLocalizations_createInstance" })
        #expect(ASCStub.dataAttrs(create)["locale"] as? String == "de-DE")

        // Undocumented list response → treated as missing → create (undocumented response tolerated).
        try await service.setWhatsNew(buildId: "b1", whatsNew: "x", locale: "en-US")
        #expect(router.log.requests.filter { $0.operationID == "betaBuildLocalizations_createInstance" }.count == 2)
    }

    @Test("setWhatsNew tolerates undocumented update responses")
    func setWhatsNewUndocumentedUpdate() async throws {
        let router = StubRouter()
            .on("GET", "builds_betaBuildLocalizations_getToManyRelated",
                .ok(ASCStub.list([ASCStub.res("betaBuildLocalizations", "bl-en", #"{"locale":"en-US"}"#)])))
            .on("PATCH", "betaBuildLocalizations_updateInstance", ASCStub.undocumented)
        try await ASCStub.service(router).setWhatsNew(buildId: "b1", whatsNew: "x", locale: "en-US")
        #expect(router.log.count == 2)
    }
}

// MARK: - Asset Library

@Suite("AppStoreService AssetLibrary Coverage", .serialized)
struct AppStoreServiceAssetLibraryCoverageTests {

    private func imageJSON(_ id: String, state: String, ops: String? = nil, details: String? = nil) -> String {
        var attrs = #""state":"\#(state)","fileName":"a.png","fileSize":4"#
        if let ops { attrs += #","uploadOperations":\#(ops)"# }
        if let details { attrs += #","stateDetails":\#(details)"# }
        return ASCStub.res("appAssetLibraryImages", id, "{\(attrs)}")
    }

    private func tempImage(_ bytes: Data = Data("abcd".utf8)) throws -> (dir: URL, file: URL) {
        let dir = try TestFiles.makeTempDir()
        let file = dir.appendingPathComponent("a.png")
        try bytes.write(to: file)
        return (dir, file)
    }

    @Test("fetchAssetLibraryId returns the library ID or notFound")
    func libraryId() async throws {
        let router = StubRouter()
            .on("GET", "apps_assetLibrary_getToOneRelated", .ok(ASCStub.single(ASCStub.res("appAssetLibraries", "lib-1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        #expect(try await service.fetchAssetLibraryId(appId: "a1") == "lib-1")
        do {
            _ = try await service.fetchAssetLibraryId(appId: "a1")
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound {}
    }

    @Test("fetchPlacements joins included images and falls back to empty")
    func placements() async throws {
        let placement = ASCStub.res(
            "appAssetLibraryPlacements", "pl1",
            #"{"placementType":"APP_SCREENSHOT","placementGroup":"IPHONE_DUO_PROFILE","state":"ACTIVE"}"#,
            rel: #"{"image":{"data":{"type":"appAssetLibraryImages","id":"img1"}}}"#
        )
        let bare = ASCStub.res("appAssetLibraryPlacements", "pl2", #"{"placementType":"PRODUCT_PAGE_HEADER_ASSET"}"#)
        let image = ASCStub.res("appAssetLibraryImages", "img1",
            #"{"state":"COMPLETE","fileName":"s.png","fileSize":10,"imageAsset":{"templateUrl":"https://cdn/{w}x{h}.{f}","width":10,"height":20},"stateDetails":[{"code":"OK","description":"fine"},{}]}"#)
        let localization = ASCStub.res("appStoreVersionLocalizations", "loc-1", #"{"locale":"en-US"}"#)
        let router = StubRouter()
            .on("GET", "appStoreVersionLocalizations_placements_getToManyRelated",
                .ok(ASCStub.list([placement, bare], included: [image, localization])),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let result = try await service.fetchPlacements(localizationId: "loc-1", placementTypes: [])
        #expect(result.count == 2)
        #expect(result[0].imageId == "img1")
        #expect(result[0].image?.templateUrl == "https://cdn/{w}x{h}.{f}")
        #expect(result[0].image?.width == 10)
        #expect(result[0].image?.stateMessages == ["OK: fine"])
        #expect(result[0].placementGroup == "IPHONE_DUO_PROFILE")
        #expect(result[1].image == nil)
        #expect(result[1].placementType == .PRODUCT_PAGE_HEADER_ASSET)
        #expect(router.log.requests[0].query.contains("placementType") == false)
        #expect(try await service.fetchPlacements(localizationId: "loc-1", placementTypes: [.APP_SCREENSHOT]).isEmpty)
    }

    @Test("fetchAssetLibraryImage decodes one image and rejects unexpected responses")
    func fetchImage() async throws {
        let router = StubRouter()
            .on("GET", "appAssetLibraryImages_getInstance", .ok(ASCStub.single(imageJSON("img1", state: "COMPLETE"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let image = try await service.fetchAssetLibraryImage(id: "img1")
        #expect(image.state == "COMPLETE")
        #expect(image.fileSize == 4)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.fetchAssetLibraryImage(id: "img1")
        }
        let noAttrs = AppStoreService.imageInfo(.init(_type: .appAssetLibraryImages, id: "x"))
        #expect(noAttrs.state == "UNKNOWN")
        #expect(noAttrs.stateMessages.isEmpty)
    }

    @Test("uploadAssetLibraryImage validates files, reservation, and commit responses")
    func uploadFailures() async throws {
        let (dir, file) = try tempImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.png")
        try Data().write(to: empty)

        let service0 = try ASCStub.service(StubRouter())
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service0.uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: empty)
        }

        let reserveFail = StubRouter().on("POST", "appAssetLibraryImages_createInstance", ASCStub.undocumented)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await ASCStub.service(reserveFail).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file)
        }

        let noOps = StubRouter().on("POST", "appAssetLibraryImages_createInstance", ASCStub.created(ASCStub.single(imageJSON("img1", state: "AWAITING_UPLOAD"))))
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await ASCStub.service(noOps).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file)
        }

        let ops = #"[{"method":"PUT","url":"https://upload.example/1","offset":0,"length":4}]"#
        let commitFail = StubRouter()
            .on("POST", "appAssetLibraryImages_createInstance", ASCStub.created(ASCStub.single(imageJSON("img1", state: "AWAITING_UPLOAD", ops: ops))))
            .on("PUT", "upload.example/1", .ok(""))
            .on("PATCH", "appAssetLibraryImages_updateInstance", ASCStub.undocumented)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await HTTPStub.withSession(commitFail) { session in
                try await ASCStub.service(commitFail, session: session).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file)
            }
        }
    }

    @Test("uploadAssetLibraryImage surfaces FAILED states and supports no-wait uploads")
    func uploadStates() async throws {
        let (dir, file) = try tempImage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = #"[{"url":"https://upload.example/1"}]"#

        func makeRouter(commit: String, polls: [StubResponse] = []) -> StubRouter {
            let router = StubRouter()
                .on("POST", "appAssetLibraryImages_createInstance", ASCStub.created(ASCStub.single(imageJSON("img1", state: "AWAITING_UPLOAD", ops: ops))))
                .on("PUT", "upload.example/1", .ok(""))
                .on("PATCH", "appAssetLibraryImages_updateInstance", .ok(ASCStub.single(commit)))
            if !polls.isEmpty {
                router.on("GET", where: { $0.operationID == "appAssetLibraryImages_getInstance" }, polls)
            }
            return router
        }

        // Immediate failure after commit, with details.
        let failed = makeRouter(commit: imageJSON("img1", state: "FAILED", details: #"[{"code":"BAD","description":"too big"}]"#))
        do {
            _ = try await HTTPStub.withSession(failed) { session in
                try await ASCStub.service(failed, session: session).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file, category: .CREATIVE_ASSETS)
            }
            Issue.record("expected failure")
        } catch let AppStoreServiceError.apiError(status, message) {
            #expect(status == nil)
            #expect(message == "BAD: too big")
        }
        let put = try #require(failed.log.first { $0.method == "PUT" })
        #expect(put.bodyString == "abcd")

        // No wait → returns the committed state.
        let noWait = makeRouter(commit: imageJSON("img1", state: "UPLOAD_COMPLETE"))
        let info = try await HTTPStub.withSession(noWait) { session in
            try await ASCStub.service(noWait, session: session).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file, waitForProcessing: false)
        }
        #expect(info.state == "UPLOAD_COMPLETE")

        // Poll reports FAILED without details.
        let pollFailed = makeRouter(commit: imageJSON("img1", state: "UPLOAD_COMPLETE"), polls: [.ok(ASCStub.single(imageJSON("img1", state: "FAILED")))])
        do {
            _ = try await HTTPStub.withSession(pollFailed) { session in
                try await ASCStub.service(pollFailed, session: session).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file, pollInterval: 0.001)
            }
            Issue.record("expected failure")
        } catch let AppStoreServiceError.apiError(_, message) {
            #expect(message == "Asset processing failed without error details.")
        }

        // Timeout while still processing.
        let timeout = makeRouter(commit: imageJSON("img1", state: "UPLOAD_COMPLETE"))
        do {
            _ = try await HTTPStub.withSession(timeout) { session in
                try await ASCStub.service(timeout, session: session).uploadAssetLibraryImage(assetLibraryId: "lib", fileUrl: file, pollInterval: 0, processingTimeout: 0)
            }
            Issue.record("expected timeout")
        } catch AppStoreServiceError.invalidResponse(let message) {
            #expect(message.contains("Timed out"))
        }
    }

    @Test("orderPlacements and createPlacement reject unexpected responses; createPlacement maps the result")
    func placementMutations() async throws {
        let router = StubRouter()
            .on("POST", "appAssetLibraryPlacementOrderingRequests_createInstance", ASCStub.undocumented)
            .on("POST", "appAssetLibraryPlacements_createInstance",
                ASCStub.created(ASCStub.single(ASCStub.res("appAssetLibraryPlacements", "pl1", #"{"state":"PROCESSING"}"#))),
                ASCStub.undocumented)
            .on("DELETE", "appAssetLibraryPlacements_deleteInstance", ASCStub.undocumented)
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) {
            try await service.orderPlacements(localizationId: "loc", placementGroup: "G", placementIds: ["a"])
        }
        let placement = try await service.createPlacement(imageId: "img1", localizationId: "loc", placementType: .APP_SCREENSHOT, placementGroup: "G")
        #expect(placement.id == "pl1")
        #expect(placement.placementType == .APP_SCREENSHOT)
        #expect(placement.placementGroup == "G")
        #expect(placement.state == "PROCESSING")
        #expect(placement.imageId == "img1")
        let attrs = ASCStub.dataAttrs(router.log.requests[1])
        #expect(attrs["placementGroup"] as? String == "G")
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createPlacement(imageId: "img1", localizationId: "loc", placementType: .PRODUCT_PAGE_HEADER_ASSET)
        }
        #expect(try await service.deletePlacement(id: "pl1") == false)
    }

    @Test("fetchAssetLibraryImageSpecs and fetchAssetLibraryReference flatten ref data")
    func referenceData() async throws {
        let refData = """
        {"type":"appAssetLibraryRefData","id":"ref1","attributes":{
          "displayClasses":[{"displayClassId":"IPHONE_DUO","deviceFamily":"IPHONE","screenDimensions":["1320x2868"]},{"deviceFamily":"IPAD"}],
          "placementTypes":[
            {"placementTypeId":"APP_SCREENSHOT","specMappings":[{"placementGroupId":"IPHONE_DUO_PROFILE","specs":["spec-1"]},{"specs":["x"]},{"placementGroupId":"NO_SPECS"}]},
            {"placementTypeId":"APP_PREVIEW","specMappings":[{"placementGroupId":"PREVIEW_GROUP","specs":["v"]}]},
            {"specMappings":[]}
          ],
          "features":[{"featureId":"APP_STORE_VERSIONS","placementPolicies":[
            {"placementType":"APP_SCREENSHOT","groupLimits":[{"groupIds":["IPHONE_DUO_PROFILE"],"maxCount":10},{}]},
            {"placementType":"APP_PREVIEW","groupLimits":[{"maxCount":3}]},
            {"groupLimits":[{"maxCount":1}]}
          ]},{}],
          "placementProfileGroups":[
            {"placementProfileGroupId":"IPHONE_DUO_PROFILE","platform":"IPHONE_APP_STORE","displayClassId":"IPHONE_DUO"},
            {"placementProfileGroupId":"IPHONE_DUO_PROFILE","platform":"IPHONE_APP_STORE"},
            {"placementProfileGroupId":"LOOSE"},
            {"platform":"ANY"}
          ],
          "imageSpecs":[
            {"specId":"spec-1","shortName":"duo","aspectRatio":"9:19.5","dimensions":{"minWidth":1,"maxWidth":2,"minHeight":3,"maxHeight":4},"fileExtensions":["png"],"maxFileSize":1000,"alphaAllowed":false,"universalAsset":true,"compatiblePlacementTypes":["APP_SCREENSHOT"]},
            {"specId":"spec-1","compatiblePlacementTypes":["APP_SCREENSHOT"]},
            {"specId":"spec-2","compatiblePlacementTypes":["PRODUCT_PAGE_HEADER_ASSET"]},
            {"compatiblePlacementTypes":["APP_SCREENSHOT"]}
          ]
        }}
        """
        let noAttrs = ASCStub.res("appAssetLibraryRefData", "ref2").replacingOccurrences(of: #","attributes":{}"#, with: "")
        let router = StubRouter()
            .on("GET", "appAssetLibraryRefData_getCollection", .ok(ASCStub.list([refData, noAttrs])))
        let service = try ASCStub.service(router)

        let specs = try await service.fetchAssetLibraryImageSpecs(placementTypes: [.APP_SCREENSHOT])
        #expect(specs.count == 2)
        #expect(specs[0] == AssetLibraryImageSpec(
            specId: "spec-1", shortName: "duo", aspectRatio: "9:19.5", minWidth: 1, maxWidth: 2, minHeight: 3, maxHeight: 4,
            fileExtensions: ["png"], maxFileSize: 1000, alphaAllowed: false, universalAsset: true, placementTypes: [.APP_SCREENSHOT]
        ))
        #expect(specs[1].specId == nil)

        let reference = try await service.fetchAssetLibraryReference(placementTypes: [.APP_SCREENSHOT])
        #expect(reference.groupSpecs == [
            .init(placementType: .APP_SCREENSHOT, groupId: "IPHONE_DUO_PROFILE", specIds: ["spec-1"]),
            .init(placementType: .APP_SCREENSHOT, groupId: "NO_SPECS", specIds: []),
        ])
        #expect(reference.limits.count == 2)
        #expect(reference.limits[0] == .init(feature: "APP_STORE_VERSIONS", placementType: .APP_SCREENSHOT, groupIds: ["IPHONE_DUO_PROFILE"], maxCount: 10))
        #expect(reference.limits[1].groupIds.isEmpty)
        #expect(reference.groups.map(\.id) == ["IPHONE_DUO_PROFILE", "LOOSE"])
        #expect(reference.groups[0] == .init(id: "IPHONE_DUO_PROFILE", platform: "IPHONE_APP_STORE", displayClass: "IPHONE_DUO", deviceFamily: "IPHONE", screenDimensions: ["1320x2868"]))
        #expect(reference.groups[1].screenDimensions.isEmpty)
        #expect(reference.specs.count == 2)

        let all = try await service.fetchAssetLibraryReference(placementTypes: [])
        #expect(all.groupSpecs.count == 3)
        #expect(all.limits.count == 4)
        #expect(all.specs.count == 3) // spec-1 deduped; spec-2 and the specId-less spec included
        #expect(router.log.requests.last?.query.contains("placementTypes") == false)
    }

    @Test("Reference endpoints return empty values on undocumented responses")
    func referenceUndocumented() async throws {
        let router = StubRouter().on("GET", "appAssetLibraryRefData_getCollection", ASCStub.undocumented)
        let service = try ASCStub.service(router)
        #expect(try await service.fetchAssetLibraryImageSpecs(placementTypes: []).isEmpty)
        let reference = try await service.fetchAssetLibraryReference(placementTypes: [.APP_SCREENSHOT])
        #expect(reference == AssetLibraryReference(specs: [], groups: [], groupSpecs: [], limits: []))
    }
}

// MARK: - Screenshots helpers (versions, localizations, downloads, chunk uploads)

@Suite("AppStoreService Screenshots Coverage", .serialized)
struct AppStoreServiceScreenshotsCoverageTests {

    private func version(_ id: String, _ versionString: String, state: String? = nil, legacy: String? = nil) -> String {
        var attrs = [#""platform":"IOS""#, #""versionString":"\#(versionString)""#]
        if let state { attrs.append(#""appVersionState":"\#(state)""#) }
        if let legacy { attrs.append(#""appStoreState":"\#(legacy)""#) }
        return ASCStub.res("appStoreVersions", id, "{\(attrs.joined(separator: ","))}")
    }

    @Test("fetchAppStoreVersions validates input, filters, and paginates")
    func fetchVersions() async throws {
        let router = StubRouter()
            .on("GET", "apps_appStoreVersions_getToManyRelated",
                .ok(ASCStub.list([version("v1", "1.0")], next: "\(ASCStub.base)/v1/apps/a1/appStoreVersions?cursor=2")),
                ASCStub.undocumented)
            .on("GET", "cursor=2", .ok(ASCStub.list([version("v2", "2.0")])))
        let versions = try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(router, session: session)
            await #expect(throws: AppStoreServiceError.self) {
                _ = try await service.fetchAppStoreVersions(appId: " ")
            }
            let found = try await service.fetchAppStoreVersions(appId: "a1", platform: .IOS, versionString: " 1.0 ", limit: 5)
            #expect(try await service.fetchAppStoreVersions(appId: "a1", versionString: "  ").isEmpty)
            return found
        }
        #expect(versions.map(\.id) == ["v1", "v2"])
        let query = router.log.requests.first?.query ?? ""
        #expect(query.contains("IOS"))
        #expect(query.contains("1.0"))
        #expect(query.contains("limit=5"))
    }

    @Test("resolveAppStoreVersion handles explicit versions, legacy states, and empty lists")
    func resolveVersion() async throws {
        let router = StubRouter()
            .on("GET", "apps_appStoreVersions_getToManyRelated",
                .ok(ASCStub.list([version("v1", "1.0", state: "READY_FOR_DISTRIBUTION")])),
                .ok(ASCStub.list([version("v1", "1.0", state: "READY_FOR_DISTRIBUTION")])),
                .ok(ASCStub.list([])),
                .ok(ASCStub.list([version("v1", "1.0", legacy: "REJECTED")])),
                .ok(ASCStub.list([version("v1", "1.0"), ASCStub.res("appStoreVersions", "v0")])),
                .ok(ASCStub.list([ASCStub.res("appStoreVersions", "v0")])))
        let service = try ASCStub.service(router)
        #expect(try await service.resolveAppStoreVersion(appId: "a1", versionString: "1.0", requireEditable: true).id == "v1")
        do {
            _ = try await service.resolveAppStoreVersion(appId: "a1", versionString: "9.9", requireEditable: false)
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound(let message) {
            #expect(message.contains("9.9"))
        }
        do {
            _ = try await service.resolveAppStoreVersion(appId: "a1", requireEditable: false)
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound(let message) {
            #expect(message.contains("No App Store versions"))
        }
        #expect(try await service.resolveAppStoreVersion(appId: "a1", requireEditable: true).id == "v1")
        do {
            _ = try await service.resolveAppStoreVersion(appId: "a1", requireEditable: true)
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound(let message) {
            #expect(message.contains("1.0 (UNKNOWN)"))
        }
        do {
            _ = try await service.resolveAppStoreVersion(appId: "a1", requireEditable: true)
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound(let message) {
            #expect(message.contains("available: none"))
        }
    }

    @Test("Version localizations are fetched, paginated, and resolved case-insensitively")
    func localizations() async throws {
        let loc = { (id: String, locale: String) in ASCStub.res("appStoreVersionLocalizations", id, #"{"locale":"\#(locale)"}"#) }
        let router = StubRouter()
            .on("GET", "appStoreVersions_appStoreVersionLocalizations_getToManyRelated",
                .ok(ASCStub.list([loc("l1", "en-US")], next: "\(ASCStub.base)/v1/appStoreVersions/v1/appStoreVersionLocalizations?cursor=2")),
                .ok(ASCStub.list([loc("l1", "en-US"), loc("l2", "de-DE")])),
                .ok(ASCStub.list([loc("l1", "en-US"), loc("l2", "de-DE")])),
                .ok(ASCStub.list([])),
                ASCStub.undocumented)
            .on("GET", "cursor=2", .ok(ASCStub.list([loc("l3", "fr-FR")])))
        try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(router, session: session)
            await #expect(throws: AppStoreServiceError.self) {
                _ = try await service.fetchAppStoreVersionLocalizations(versionId: " ")
            }
            let all = try await service.fetchAppStoreVersionLocalizations(versionId: "v1", locale: "en-US")
            #expect(all.map(\.id) == ["l1", "l3"])
            #expect(router.log.requests.first?.query.contains("en-US") == true)

            await #expect(throws: AppStoreServiceError.self) {
                _ = try await service.resolveVersionLocalization(versionId: "v1", locale: " ")
            }
            #expect(try await service.resolveVersionLocalization(versionId: "v1", locale: "DE-de").id == "l2")
            do {
                _ = try await service.resolveVersionLocalization(versionId: "v1", locale: "ja")
                Issue.record("expected notFound")
            } catch AppStoreServiceError.notFound(let message) {
                #expect(message.contains("de-DE, en-US"))
            }
            do {
                _ = try await service.resolveVersionLocalization(versionId: "v1", locale: "ja")
                Issue.record("expected notFound")
            } catch AppStoreServiceError.notFound(let message) {
                #expect(message.contains("available locales: none"))
            }
            #expect(try await service.fetchAppStoreVersionLocalizations(versionId: "v1").isEmpty)
        }
    }

    @Test("resolveScreenshotDownloadURL substitutes template placeholders and rejects incomplete templates")
    func downloadURL() {
        #expect(AppStoreService.resolveScreenshotDownloadURL(templateUrl: nil, width: 1, height: 1, fileName: nil) == nil)
        #expect(AppStoreService.resolveScreenshotDownloadURL(templateUrl: "  ", width: 1, height: 1, fileName: nil) == nil)
        #expect(AppStoreService.resolveScreenshotDownloadURL(templateUrl: "https://c/{w}x{h}.{f}", width: nil, height: 1, fileName: nil) == nil)
        #expect(AppStoreService.resolveScreenshotDownloadURL(templateUrl: "https://c/{w}x{h}.{f}", width: 1, height: 0, fileName: nil) == nil)
        let jpg = AppStoreService.resolveScreenshotDownloadURL(templateUrl: "https://c/{w}x{h}.{f}", width: 10, height: 20, fileName: "Shot.JPEG")
        #expect(jpg?.url.absoluteString == "https://c/10x20.jpg")
        #expect(jpg?.fileExtension == "jpg")
        let plain = AppStoreService.resolveScreenshotDownloadURL(templateUrl: "https://c/fixed.png", width: nil, height: nil, fileName: nil)
        #expect(plain?.url.absoluteString == "https://c/fixed.png")
        #expect(plain?.fileExtension == "png")
    }

    @Test("downloadScreenshotData returns bytes and content type, and fails on HTTP errors")
    func download() async throws {
        let router = StubRouter()
            .on("GET", "cdn.example/ok", StubResponse(200, Data("img".utf8), headers: ["Content-Type": "image/png"]))
            .on("GET", "cdn.example/missing", StubResponse(404, Data()))
        try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(StubRouter(), session: session)
            let result = try await service.downloadScreenshotData(from: URL(string: "https://cdn.example/ok")!)
            #expect(result.data == Data("img".utf8))
            #expect(result.contentType == "image/png")
            do {
                _ = try await service.downloadScreenshotData(from: URL(string: "https://cdn.example/missing")!)
                Issue.record("expected error")
            } catch let AppStoreServiceError.apiError(status, _) {
                #expect(status == 404)
            }
        }
    }

    @Test("uploadScreenshotChunk validates URLs and bounds, applies defaults, and retries failures")
    func uploadChunk() async throws {
        let data = Data("0123456789".utf8)
        let service0 = try ASCStub.service(StubRouter())
        await #expect(throws: AppStoreServiceError.self) {
            try await service0.uploadScreenshotChunk(operation: .init(method: "PUT"), index: 0, fileData: data)
        }
        await #expect(throws: AppStoreServiceError.self) {
            try await service0.uploadScreenshotChunk(operation: .init(url: "https://u/1", length: 20, offset: 0), index: 0, fileData: data)
        }

        let router = StubRouter()
            .on("POST", "u.example/default", .ok(""))
            .on("PUT", "u.example/retry", .status(500, ""), .ok(""))
            .on("PUT", "u.example/fail", .status(503, ""))
        try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(router, session: session)
            // Defaults: offset 0, length = rest of file.
            try await service.uploadScreenshotChunk(
                operation: .init(method: "POST", url: "https://u.example/default", offset: 4, requestHeaders: [.init(name: "X-A", value: "1"), .init(name: "X-B")]),
                index: 0, fileData: data
            )
            try await service.uploadScreenshotChunk(operation: .init(url: "https://u.example/retry", length: 2), index: 1, fileData: data)
            do {
                try await service.uploadScreenshotChunk(operation: .init(url: "https://u.example/fail"), index: 2, fileData: data)
                Issue.record("expected failure")
            } catch let AppStoreServiceError.apiError(status, message) {
                #expect(status == 503)
                #expect(message.contains("#3"))
            }
        }
        let first = try #require(router.log.first { $0.url.absoluteString.contains("default") })
        #expect(first.bodyString == "456789")
        #expect(first.headers["X-A"] == "1")
        let retries = router.log.requests.filter { $0.url.absoluteString.contains("retry") }
        #expect(retries.count == 2)
        #expect(retries.last?.bodyString == "01")
        #expect(router.log.requests.filter { $0.url.absoluteString.contains("fail") }.count == 3)
    }
}

// MARK: - Users & invitations

@Suite("AppStoreService Users Coverage")
struct AppStoreServiceUsersCoverageTests {
    private func user(_ id: String, _ username: String?) -> String {
        ASCStub.res("users", id, username.map { #"{"username":"\#($0)"}"# } ?? "{}")
    }

    private func invitation(_ id: String, _ email: String?) -> String {
        ASCStub.res("userInvitations", id, email.map { #"{"email":"\#($0)"}"# } ?? "{}")
    }

    @Test("fetchUsers paginates; findUser matches by username or id")
    func users() async throws {
        let router = StubRouter()
            .on("GET", "users_getCollection",
                .ok(ASCStub.list([user("u1", "other@x.com")])),
                .ok(ASCStub.list([user("u1", "other@x.com"), user("u2", nil)], next: "\(ASCStub.base)/v1/users?cursor=2")),
                .ok(ASCStub.list([user("u9", "Z@Y.com")])),
                .ok(ASCStub.list([user("u1", "A@B.com")])),
                .ok(ASCStub.list([user("u1", "x@y.z")])),
                ASCStub.undocumented)
            .on("GET", "cursor=2", .ok(ASCStub.list([user("u3", "a@b.com")])))
        try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(router, session: session)
            #expect(try await service.findUser(identifier: " ") == nil)
            // "@" lookup misses the filtered list, then falls back to the paginated full list.
            #expect(try await service.findUser(identifier: "a@b.com")?.id == "u3")
            #expect(try await service.findUser(identifier: "z@y.com")?.id == "u9")
            #expect(try await service.findUser(identifier: "u1")?.id == "u1")
            #expect(try await service.findUser(identifier: "nobody") == nil)
            #expect(try await service.fetchUsers().isEmpty)
        }
    }

    @Test("updateUser validates input and maps responses")
    func updateUser() async throws {
        let router = StubRouter()
            .on("PATCH", "users_updateInstance", .ok(ASCStub.single(user("u1", "a@b.c"))), .ok(ASCStub.single(user("u1", "a@b.c"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.updateUser(id: " ", roles: ["admin"]) }
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.updateUser(id: "u1", roles: ["account-holder"]) }
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.updateUser(id: "u1", allAppsVisible: true, visibleAppIds: ["a"]) }
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.updateUser(id: "u1") }

        _ = try await service.updateUser(id: "u1", visibleAppIds: [" "])
        #expect(ASCStub.json(router.log.requests[0].body)["data"].flatMap { ($0 as? [String: Any])?["attributes"] } == nil)
        let updated = try await service.updateUser(id: "u1", provisioningAllowed: true)
        #expect(updated.id == "u1")
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.updateUser(id: "u1", provisioningAllowed: false) }
    }

    @Test("deleteUser and cancelUserInvitation map 204 / 404 / other")
    func deletes() async throws {
        let router = StubRouter()
            .on("DELETE", "users_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.undocumented)
            .on("DELETE", "userInvitations_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.undocumented)
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.deleteUser(id: " ") }
        #expect(try await service.deleteUser(id: "u1") == true)
        #expect(try await service.deleteUser(id: "u1") == false)
        #expect(try await service.deleteUser(id: "u1") == false)
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.cancelUserInvitation(id: " ") }
        #expect(try await service.cancelUserInvitation(id: "i1") == true)
        #expect(try await service.cancelUserInvitation(id: "i1") == false)
        #expect(try await service.cancelUserInvitation(id: "i1") == false)
    }

    @Test("fetchUserInvitations paginates; findUserInvitation matches by email or id")
    func invitations() async throws {
        let router = StubRouter()
            .on("GET", "userInvitations_getCollection",
                .ok(ASCStub.list([invitation("i1", "a@b.com")])),
                .ok(ASCStub.list([invitation("i1", "x@y.z")])),
                .ok(ASCStub.list([invitation("i1", "x@y.z"), invitation("i2", nil)], next: "\(ASCStub.base)/v1/userInvitations?cursor=2")),
                .ok(ASCStub.list([invitation("i1", "x@y.z")])),
                .ok(ASCStub.list([])),
                ASCStub.undocumented)
            .on("GET", "cursor=2", .ok(ASCStub.list([invitation("i3", "C@D.com")])))
        try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(router, session: session)
            #expect(try await service.findUserInvitation(identifier: "") == nil)
            #expect(try await service.findUserInvitation(identifier: "A@b.com")?.id == "i1")
            #expect(try await service.findUserInvitation(identifier: "c@d.com")?.id == "i3")
            #expect(try await service.findUserInvitation(identifier: "i1")?.id == "i1")
            #expect(try await service.findUserInvitation(identifier: "zzz") == nil)
            let query = router.log.requests.first?.query ?? ""
            #expect(query.contains("a@b.com") || query.contains("A@b.com") || query.contains("%40"))
            #expect(try await service.fetchUserInvitations(roles: ["admin"], visibleAppIds: [" ", "app1"]).isEmpty)
        }
    }

    @Test("inviteUser validates names, roles and app visibility and maps responses")
    func invite() async throws {
        let router = StubRouter()
            .on("POST", "userInvitations_createInstance", ASCStub.created(ASCStub.single(invitation("i1", "a@b.c"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.inviteUser(email: " ", firstName: "A", lastName: "B", roles: ["admin"]) }
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.inviteUser(email: "a@b.c", firstName: " ", lastName: "B", roles: ["admin"]) }
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.inviteUser(email: "a@b.c", firstName: "A", lastName: " ", roles: ["admin"]) }
        await #expect(throws: AppStoreServiceError.self) { _ = try await service.inviteUser(email: "a@b.c", firstName: "A", lastName: "B", roles: ["account_holder"]) }
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.inviteUser(email: "a@b.c", firstName: "A", lastName: "B", roles: ["admin"], allAppsVisible: true, visibleAppIds: ["x"])
        }
        let invited = try await service.inviteUser(email: "a@b.c", firstName: "A", lastName: "B", roles: ["developer"], visibleAppIds: ["x", "x"])
        #expect(invited.id == "i1")
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["allAppsVisible"] as? Bool == false)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.inviteUser(email: "a@b.c", firstName: "A", lastName: "B", roles: ["developer"])
        }
    }
}

// MARK: - Remaining edge cases

@Suite("AppStoreService Edge Coverage")
struct AppStoreServiceEdgeCoverageTests {

    @Test("Result value types expose their fields")
    func resultTypes() {
        let cert = Components.Schemas.Certificate(_type: .certificates, id: "c1")
        let created = CreateCertificateResult(
            certificate: cert, typeLabel: "Distribution", commonName: "CN",
            cerFile: URL(fileURLWithPath: "/tmp/a.cer"), keyFile: URL(fileURLWithPath: "/tmp/a.pem"),
            p12File: nil, p12Password: "pw", keychainImported: false, keychainName: nil
        )
        #expect(created.commonName == "CN")
        #expect(created.p12File == nil)
        let signing = SigningCertificateData(certificate: cert, typeLabel: "Dist", commonName: "CN", cerData: Data([1]), privateKeyPEM: "k", p12Data: Data([2]))
        #expect(signing.id == "c1")
        #expect(signing.p12Data == Data([2]))
    }

    @Test("createSigningCertificateData(certificateType:) defaults label and common name before rolling back")
    func signingDefaults() async throws {
        let router = StubRouter()
            .on("POST", "certificates_createInstance", ASCStub.created(ASCStub.single(ASCStub.cert("c1"))))
            .on("DELETE", "certificates_deleteInstance", ASCStub.notFound)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await ASCStub.service(router).createSigningCertificateData(certificateType: .IOS_DISTRIBUTION)
        }
        #expect(router.log.count == 2)
    }

    @Test("Unnamed certificates/profiles and typeless profiles use fallbacks")
    func fallbacks() async throws {
        let content = Data("p".utf8).base64EncodedString()
        let typeless = ASCStub.res("profiles", "p0", #"{"profileState":"INVALID"}"#)
        let router = StubRouter()
            .on("GET", "bundleIds_getCollection", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([ASCStub.res("certificates", "c-unnamed")])))
            .on("POST", "profiles_createInstance", ASCStub.created(ASCStub.single(ASCStub.profile("p1", content: content))))
            .on("GET", "profiles_getCollection", .ok(ASCStub.list([typeless])))
            .on("DELETE", "profiles_deleteInstance", ASCStub.noContent)
        let service = try ASCStub.service(router)
        let result = try await service.createProvisioningProfile(bundleId: "com.a", platform: "tvos")
        #expect(result.selectedCertificateName == "c-unnamed")
        #expect(ASCStub.dataAttrs(router.log.requests.last)["name"] as? String == "match AppStore com.a tvos")

        #expect(try await service.fetchActiveProfileUUIDs(platform: "ios", type: "appstore").isEmpty)
        let pruned = try await service.pruneProfiles()
        #expect(pruned.deletedCount == 1)
        let nuked = try await service.nuke(type: "development")
        #expect(nuked.deletedProfileIds.isEmpty)
    }

    @Test("fetchApps follows pagination; updateAppInfoCategories sends every slot")
    func appsAndAllCategorySlots() async throws {
        let router = StubRouter()
            .on("GET", "apps_getCollection", .ok(ASCStub.list([ASCStub.res("apps", "a1")], next: "\(ASCStub.base)/v1/apps?cursor=2")))
            .on("GET", "cursor=2", .ok(ASCStub.list([ASCStub.res("apps", "a2")])))
            .on("PATCH", "appInfos_updateInstance", .ok(ASCStub.single(ASCStub.res("appInfos", "ai1"))))
        try await HTTPStub.withSession(router) { session in
            let service = try ASCStub.service(router, session: session)
            #expect(try await service.fetchApps().map(\.id) == ["a1", "a2"])
            var slots: [AppInfoCategorySlot: String] = [:]
            for slot in AppInfoCategorySlot.allCases { slots[slot] = slot.rawValue.uppercased() }
            try await service.updateAppInfoCategories(appInfoId: "ai1", categories: slots)
        }
        let rel = (ASCStub.json(router.log.requests.last?.body)["data"] as? [String: Any])?["relationships"] as? [String: Any]
        #expect(rel?.count == 6)
    }

    @Test("uploadScreenshotChunk retries transport errors and rethrows the last one")
    func chunkTransportError() async throws {
        // Hold the stub gate with no handler installed so the stub protocol fails every request locally.
        await HTTPStubGate.shared.acquire()
        StubURLProtocol.setHandler(nil)
        let session = HTTPStub.makeSession()
        do {
            let service = try ASCStub.service(StubRouter(), session: session)
            try await service.uploadScreenshotChunk(operation: .init(url: "https://u.example/x", length: 1), index: 0, fileData: Data([1, 2]))
            Issue.record("expected transport error")
        } catch is AppStoreServiceError {
            Issue.record("expected a transport error, not a service error")
        } catch {
            // Expected URLError from the stub protocol.
        }
        await HTTPStubGate.shared.release()
    }
}
