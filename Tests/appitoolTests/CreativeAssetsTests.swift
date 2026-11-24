import ArgumentParser
import Foundation
import Testing
@testable import appitool
@testable import AppleServices
import AppStoreConnectAPI

@Suite("Apple Assets Tests")
struct CreativeAssetsTests {
    @Test("Asset slot types parse screenshot display types plus header and search")
    func typeParsing() throws {
        #expect(try AppleAssetSlot.parse("header") == .creative(.header))
        #expect(try AppleAssetSlot.parse("Product-Page-Header") == .creative(.header))
        #expect(try AppleAssetSlot.parse("search-results") == .creative(.search))
        #expect(try AppleAssetSlot.parse("APP_STORE_SEARCH_RESULTS_ASSET") == .creative(.search))
        #expect(try AppleAssetSlot.parse("iphone-67").key == "iphone-67")
        #expect(try AppleAssetSlot.parse("APP_IPHONE_67").screenshotSlot?.placementGroup == "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE")
        #expect(try AppleAssetSlot.parse("iphone-duo").screenshotSlot?.placementGroup == "IPHONE_DUO_PROFILE")
        #expect(AppleAssetSlot.creative(.search).key == "search")
        #expect(throws: (any Error).self) { try AppleAssetSlot.parse("banner") }
        #expect(CreativeAssetType.parseIfCreative("iphone-67") == nil)
        #expect(CreativeAssetType.header.placementType == .PRODUCT_PAGE_HEADER_ASSET)
        #expect(CreativeAssetType(placementType: .APP_STORE_SEARCH_RESULTS_ASSET) == .search)
        #expect(CreativeAssetType(placementType: .APP_SCREENSHOT) == nil)
    }

    @Test("Every screenshot display type maps to its verified Asset Library placement group")
    func screenshotSlotMapping() throws {
        // 33 display types + 2 Duo slots, all unique.
        #expect(AppleScreenshotSlot.all.count == AppleTypeMapper.supportedScreenshotDisplayTypes.count + 2)
        #expect(Set(AppleScreenshotSlot.all.map(\.placementGroup)).count == AppleScreenshotSlot.all.count)
        #expect(Set(AppleScreenshotSlot.all.map(\.key)).count == AppleScreenshotSlot.all.count)

        let expected: [(String, Components.Schemas.AppAssetLibraryPlacementType, String)] = [
            ("iphone-65", .APP_SCREENSHOT, "IPHONE_FACE_ID_LARGE_PROFILE"),
            ("iphone-61", .APP_SCREENSHOT, "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE"),
            ("iphone-58", .APP_SCREENSHOT, "IPHONE_FACE_ID_MEDIUM_PROFILE"),
            ("APP_IPAD_PRO_3GEN_129", .APP_SCREENSHOT, "IPAD_13_PROFILE"),
            ("APP_IPAD_PRO_129", .APP_SCREENSHOT, "IPAD_129_PROFILE"),
            ("APP_WATCH_SERIES_10", .APP_SCREENSHOT, "WATCH_SERIES_10_PROFILE"),
            ("APP_DESKTOP", .APP_SCREENSHOT, "MAC_PROFILE"),
            ("IMESSAGE_APP_IPHONE_67", .IMESSAGE_APP_SCREENSHOT, "IMESSAGE_IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"),
            ("imessage-iphone-duo", .IMESSAGE_APP_SCREENSHOT, "IMESSAGE_IPHONE_DUO_PROFILE"),
        ]
        for (raw, type, group) in expected {
            let slot = try AppleScreenshotSlot.parse(raw)
            #expect(slot.placementType == type, "\(raw)")
            #expect(slot.placementGroup == group, "\(raw)")
            #expect(AppleScreenshotSlot.forPlacement(type: type, group: group) == slot)
        }
        #expect(AppleScreenshotSlot.forPlacement(type: .APP_SCREENSHOT, group: "FUTURE_PROFILE") == nil)
        #expect(try AppleScreenshotSlot.parse("iphone-67").slotKey(versionId: "v1", locale: "en-US") == "v1/en-US/IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE")
    }

    @Test("apple assets commands parse header/search options and validate --all-locales")
    func commandValidation() throws {
        let upload = try #require(
            try appitool.parseAsRoot(["apple", "assets", "upload", "--all-locales", "-t", "header", "./header.png"]) as? AppleAssetsUploadCommand
        )
        #expect(upload.allLocales == true)

        for args in [
            ["apple", "assets", "upload", "--all-locales", "-t", "header"],
            ["apple", "assets", "upload", "--all-locales", "./header.png"],
            ["apple", "assets", "upload", "--all-locales", "-t", "iphone-67", "./shot.png"],
            ["apple", "assets", "upload", "--all-locales", "--locale", "en-US", "-t", "header", "./header.png"],
            ["apple", "assets", "upload", "--all-locales", "--sync", "-t", "header", "./header.png"],
            ["apple", "creative-assets", "list"],
            ["apple", "screenshots", "list"],
        ] {
            #expect(throws: (any Error).self) {
                _ = try appitool.parseAsRoot(args)
            }
        }

        let delete = try #require(
            try appitool.parseAsRoot(["apple", "assets", "delete", "--all", "--locale", "en-US", "-t", "search", "--ci"]) as? AppleAssetsDeleteCommand
        )
        #expect(delete.isDestructive == true)
        #expect(delete.destructiveCommandDescription == "apple assets delete")
        #expect(delete.ciSkipResolution(environment: [:])?.isCI == true)

        let list = try #require(try appitool.parseAsRoot(["apple", "assets", "list", "--asset-library"]) as? AppleAssetsListCommand)
        #expect(list.assetLibrary == true)
        _ = try appitool.parseAsRoot(["apple", "assets", "list", "-t", "header"])
        _ = try appitool.parseAsRoot(["apple", "assets", "specs", "-t", "screenshot"])
        _ = try appitool.parseAsRoot(["apple", "assets", "types"])
        _ = try appitool.parseAsRoot(["apple", "assets", "download", "--locale", "en-US", "-t", "search", "-o", "./out", "--dry-run"])
    }

    @Test("Upload resolves a <locale>/<type>/ tree into screenshot and header/search slots")
    func treeResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appitool-assets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, file) in [("en-US/iphone-67", "01.png"), ("en-US/iphone-67", "02.png"), ("en-US/header", "header.png"), ("tr/search", "search.png")] {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent(file))
        }

        let (_, batches) = try ScreenshotFileResolver.resolveUploadBatches(
            paths: [root.path],
            defaultDirectory: { root },
            localeFilter: nil,
            typeFilter: nil,
            storeDisplayName: "App Store Connect",
            downloadHintCommand: "appitool apple assets download",
            parseType: AppleAssetSlot.parse
        )
        let summary = batches.map { "\($0.locale)/\($0.type.key)/\($0.files.count)" }.sorted()
        #expect(summary == ["en-US/header/1", "en-US/iphone-67/2", "tr/search/1"])
    }

    @Test("Placement list responses decode relationships and state-specific image attributes")
    func placementResponseDecoding() throws {
        let json = """
        {
          "data": [
            {
              "type": "appAssetLibraryPlacements",
              "id": "pl-1",
              "attributes": { "mediaType": "IMAGE", "placementType": "PRODUCT_PAGE_HEADER_ASSET", "state": "ACTIVE" },
              "relationships": {
                "image": { "data": { "type": "appAssetLibraryImages", "id": "img-1" } },
                "appStoreVersionLocalization": { "data": { "type": "appStoreVersionLocalizations", "id": "loc-1" } }
              }
            }
          ],
          "included": [
            {
              "type": "appAssetLibraryImages",
              "id": "img-1",
              "attributes": {
                "state": "APPROVED",
                "category": "CREATIVE_ASSETS",
                "fileName": "header.png",
                "fileSize": 1234,
                "imageAsset": { "templateUrl": "https://example.com/{w}x{h}bb.{f}", "width": 3840, "height": 1646 }
              }
            }
          ],
          "links": { "self": "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/loc-1/placements" }
        }
        """
        let response = try JSONDecoder().decode(Components.Schemas.AppAssetLibraryPlacementsResponse.self, from: Data(json.utf8))
        let placement = try #require(response.data.first)
        #expect(placement.attributes?.placementType == .PRODUCT_PAGE_HEADER_ASSET)
        // Live API returns states missing from the 4.6.1 spec (e.g. ACTIVE); they must decode as plain strings.
        #expect(placement.attributes?.state == "ACTIVE")
        #expect(placement.relationships?.value1.value2.image?.data?.id == "img-1")

        guard case .appAssetLibraryImages(let image)? = response.included?.first else {
            Issue.record("Expected an included image")
            return
        }
        let info = AppStoreService.imageInfo(image)
        #expect(info.state == "APPROVED")
        #expect(info.fileName == "header.png")
        #expect(info.width == 3840)
        #expect(info.height == 1646)
    }

    @Test("Placement create request encodes a flat body (no anyOf wrappers)")
    func placementCreateEncoding() throws {
        let payload = Components.Schemas.AppAssetLibraryPlacementCreateRequest(
            data: .init(
                _type: .appAssetLibraryPlacements,
                attributes: .init(placementType: .APP_STORE_SEARCH_RESULTS_ASSET),
                relationships: .init(
                    image: .init(data: .init(_type: .appAssetLibraryImages, id: "img-1")),
                    appStoreVersionLocalization: .init(data: .init(_type: .appStoreVersionLocalizations, id: "loc-1"))
                )
            )
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let attributes = try #require(data["attributes"] as? [String: Any])
        let relationships = try #require(data["relationships"] as? [String: Any])
        #expect(attributes["placementType"] as? String == "APP_STORE_SEARCH_RESULTS_ASSET")
        #expect(((relationships["image"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "img-1")
        #expect(((relationships["appStoreVersionLocalization"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "loc-1")
    }
}
