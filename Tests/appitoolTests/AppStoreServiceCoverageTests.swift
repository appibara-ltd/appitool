import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import appitool
import AppStoreConnectAPI
import AppleServices

// MARK: - Shared JSON / service helpers for App Store Connect coverage tests

enum ASCStub {
    static let base = "https://api.appstoreconnect.apple.com"

    static func service(_ router: StubRouter, session: URLSession = .shared) throws -> AppStoreService {
        try AppStoreService(
            keyId: "KID",
            issuerId: "ISS",
            key: TestCredentials.appleKeyPEM(),
            transport: StubTransport(router),
            urlSession: session
        )
    }

    static func res(_ type: String, _ id: String, _ attrs: String = "{}", rel: String? = nil) -> String {
        var s = #"{"type":"\#(type)","id":"\#(id)","attributes":\#(attrs)"#
        if let rel { s += #","relationships":\#(rel)"# }
        return s + "}"
    }

    static func list(_ items: [String], next: String? = nil, included: [String]? = nil) -> String {
        var links = #""self":"\#(base)/v1/x""#
        if let next { links += #","next":"\#(next)""# }
        var s = #"{"data":[\#(items.joined(separator: ","))],"links":{\#(links)}"#
        if let included { s += #","included":[\#(included.joined(separator: ","))]"# }
        return s + "}"
    }

    static func single(_ item: String, included: [String]? = nil) -> String {
        var s = #"{"data":\#(item),"links":{"self":"\#(base)/v1/x"}"#
        if let included { s += #","included":[\#(included.joined(separator: ","))]"# }
        return s + "}"
    }

    static func errors(_ status: Int, code: String = "ERR", title: String = "Bad", detail: String = "Something failed") -> String {
        #"{"errors":[{"status":"\#(status)","code":"\#(code)","title":"\#(title)","detail":"\#(detail)"}]}"#
    }

    static func created(_ json: String) -> StubResponse { .status(201, json) }
    static let noContent = StubResponse(204, Data(), headers: [:])
    static let notFound = StubResponse.status(404, errors(404, code: "NOT_FOUND"))
    static let undocumented = StubResponse.status(202, "{}")
    static let serverError = StubResponse.status(500, errors(500, code: "INTERNAL", title: "Server", detail: "boom"))

    static func json(_ data: Data?) -> [String: Any] {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func dataAttrs(_ request: StubRequest?) -> [String: Any] {
        let data = json(request?.body)["data"] as? [String: Any]
        return data?["attributes"] as? [String: Any] ?? [:]
    }

    static func cert(_ id: String, name: String? = nil, serial: String? = nil, expiration: String? = nil, content: String? = nil) -> String {
        var attrs: [String] = [#""certificateType":"DISTRIBUTION""#]
        if let name { attrs.append(#""name":"\#(name)""#) }
        if let serial { attrs.append(#""serialNumber":"\#(serial)""#) }
        if let expiration { attrs.append(#""expirationDate":"\#(expiration)""#) }
        if let content { attrs.append(#""certificateContent":"\#(content)""#) }
        return res("certificates", id, "{\(attrs.joined(separator: ","))}")
    }

    static func profile(_ id: String, name: String = "P", type: String = "IOS_APP_STORE", state: String = "ACTIVE", uuid: String? = nil, expiration: String? = nil, content: String? = nil) -> String {
        var attrs: [String] = [#""name":"\#(name)""#, #""profileType":"\#(type)""#, #""profileState":"\#(state)""#]
        if let uuid { attrs.append(#""uuid":"\#(uuid)""#) }
        if let expiration { attrs.append(#""expirationDate":"\#(expiration)""#) }
        if let content { attrs.append(#""profileContent":"\#(content)""#) }
        return res("profiles", id, "{\(attrs.joined(separator: ","))}")
    }

    static func device(_ id: String, name: String = "Device", udid: String = "UDID", cls: String = "IPHONE") -> String {
        res("devices", id, #"{"name":"\#(name)","udid":"\#(udid)","deviceClass":"\#(cls)","platform":"IOS","status":"ENABLED"}"#)
    }

    static func bundle(_ id: String, identifier: String, platform: String = "IOS") -> String {
        res("bundleIds", id, #"{"name":"App","identifier":"\#(identifier)","platform":"\#(platform)"}"#)
    }
}

@Suite("AppStoreService Core Coverage")
struct AppStoreServiceCoreCoverageTests {

    // MARK: Errors & formatting

    @Test("AppStoreServiceError descriptions and Apple error formatting")
    func errorDescriptions() {
        #expect(AppStoreServiceError.apiError(status: 401, message: "m").errorDescription == "Apple API Error (HTTP 401): m")
        #expect(AppStoreServiceError.apiError(status: nil, message: "m").errorDescription == "Apple API Error: m")
        #expect(AppStoreServiceError.notFound("x").errorDescription == "Not Found: x")
        #expect(AppStoreServiceError.invalidResponse("y").errorDescription == "Invalid Response: y")
        #expect(AppStoreService.formatAppleErrors(nil) == "No detailed error provided by Apple")
        #expect(AppStoreService.formatAppleErrors([]) == "No detailed error provided by Apple")
        let errors: [Components.Schemas.ErrorResponse.errorsPayloadPayload] = [
            .init(status: "400", code: "A", title: "T1", detail: "D1"),
            .init(status: "400", code: "B", title: "T2", detail: "D2"),
        ]
        #expect(AppStoreService.formatAppleErrors(errors) == "T1 (A): D1 | T2 (B): D2")
    }

    @Test("Error middleware maps HTTP errors to AppStoreServiceError and passes allowed codes through")
    func errorMiddleware() async throws {
        let router = StubRouter()
            .on("GET", "certificates_getCollection", .status(403, ASCStub.errors(403, code: "FORBIDDEN", title: "No", detail: "denied")))
            .on("GET", "apps_getCollection", .status(500, "not json"))
        let service = try ASCStub.service(router)
        do {
            _ = try await service.fetchCertificates()
            Issue.record("expected error")
        } catch let AppStoreServiceError.apiError(status, message) {
            #expect(status == 403)
            #expect(message == "No (FORBIDDEN): denied")
        }
        do {
            _ = try await service.fetchApps()
            Issue.record("expected error")
        } catch let AppStoreServiceError.apiError(status, message) {
            #expect(status == 500)
            #expect(message == "No detailed error provided by Apple")
        }
    }

    @Test("execute rethrows non-service ClientErrors (e.g. decoding failures)")
    func executeRethrowsClientError() async throws {
        let router = StubRouter().on("GET", "apps_getCollection", .ok(#"{"data":"nope"}"#))
        let service = try ASCStub.service(router)
        await #expect(throws: ClientError.self) {
            _ = try await service.fetchApps()
        }
    }

    // MARK: Pagination

    @Test("fetchCertificates follows next links through the URLSession and honours limit")
    func certificatePagination() async throws {
        let router = StubRouter()
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([ASCStub.cert("c1")], next: "\(ASCStub.base)/v1/certificates?cursor=2")))
            .on("GET", "cursor=2", .ok(ASCStub.list([ASCStub.cert("c2", expiration: "2030-01-01T00:00:00Z")], next: "\(ASCStub.base)/v1/certificates?cursor=3")))
            .on("GET", "cursor=3", .ok(ASCStub.list([ASCStub.cert("c3"), ASCStub.cert("c4")])))
        let all = try await HTTPStub.withSession(router) { session in
            try await ASCStub.service(router, session: session).fetchCertificates()
        }
        #expect(all.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(all[1].attributes?.expirationDate != nil)
        let pageRequest = try #require(router.log.first { $0.url.absoluteString.contains("cursor=2") })
        #expect(pageRequest.headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(pageRequest.headers["Accept"] == "application/json")

        // limit stops paging early and truncates.
        let limitedRouter = StubRouter()
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([ASCStub.cert("c1")], next: "\(ASCStub.base)/v1/certificates?cursor=2")))
            .on("GET", "cursor=2", .ok(ASCStub.list([ASCStub.cert("c2"), ASCStub.cert("c3")], next: "\(ASCStub.base)/v1/certificates?cursor=3")))
        let limited = try await HTTPStub.withSession(limitedRouter) { session in
            try await ASCStub.service(limitedRouter, session: session).fetchCertificates(limit: 2)
        }
        #expect(limited.map(\.id) == ["c1", "c2"])
        #expect(limitedRouter.log.requests.contains { $0.url.absoluteString.contains("cursor=3") } == false)

        let ids = try await HTTPStub.withSession(limitedRouter) { session in
            try await ASCStub.service(limitedRouter, session: session).fetchActiveCertificateIds(limit: 1)
        }
        #expect(ids == ["c1"])
    }

    @Test("Pagination surfaces invalid next links and HTTP errors")
    func paginationErrors() async throws {
        let invalid = StubRouter().on("GET", "apps_getCollection", .ok(ASCStub.list([ASCStub.res("apps", "a1")], next: "")))
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await ASCStub.service(invalid).fetchApps()
        }

        let failing = StubRouter()
            .on("GET", "apps_getCollection", .ok(ASCStub.list([ASCStub.res("apps", "a1")], next: "\(ASCStub.base)/v1/apps?cursor=2")))
            .on("GET", "cursor=2", .status(429, ASCStub.errors(429, code: "RATE", title: "Slow", detail: "down")))
        do {
            _ = try await HTTPStub.withSession(failing) { session in
                try await ASCStub.service(failing, session: session).fetchApps(limit: 5, bundleId: "com.x", name: "X")
            }
            Issue.record("expected error")
        } catch let AppStoreServiceError.apiError(status, message) {
            #expect(status == 429)
            #expect(message == "Slow (RATE): down")
        }
        let query = failing.log.requests.first?.query ?? ""
        #expect(query.contains("com.x"))
    }

    @Test("List endpoints return empty arrays on undocumented success responses")
    func listUndocumented() async throws {
        let router = StubRouter()
            .on("GET", "certificates_getCollection", ASCStub.undocumented)
            .on("GET", "bundleIds_getCollection", ASCStub.undocumented)
            .on("GET", "apps_getCollection", ASCStub.undocumented)
            .on("GET", "devices_getCollection", ASCStub.undocumented)
            .on("GET", "profiles_getCollection", ASCStub.undocumented)
            .on("GET", "bundleIds_bundleIdCapabilities_getToManyRelated", ASCStub.undocumented)
        let service = try ASCStub.service(router)
        #expect(try await service.fetchCertificates().isEmpty)
        #expect(try await service.fetchBundleIds().isEmpty)
        #expect(try await service.fetchApps().isEmpty)
        #expect(try await service.fetchDevices(platform: nil).isEmpty)
        #expect(try await service.fetchProfiles().isEmpty)
        #expect(try await service.fetchCapabilities(bundleIdPortalId: "b").isEmpty)
    }

    // MARK: Certificates

    @Test("createCertificate posts CSR and handles unexpected responses")
    func createCertificate() async throws {
        let router = StubRouter()
            .on("POST", "certificates_createInstance", ASCStub.created(ASCStub.single(ASCStub.cert("new", name: "N"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let cert = try await service.createCertificate(csrContent: "CSR", certificateType: .DISTRIBUTION)
        #expect(cert.id == "new")
        let attrs = ASCStub.dataAttrs(router.log.requests.first)
        #expect(attrs["csrContent"] as? String == "CSR")
        #expect(attrs["certificateType"] as? String == "DISTRIBUTION")
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createCertificate(csrContent: "CSR", certificateType: .DEVELOPMENT)
        }
    }

    @Test("Delete endpoints return true on 204, false on 404 and other responses")
    func deleteEndpoints() async throws {
        let router = StubRouter()
            .on("DELETE", "certificates_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.undocumented)
            .on("DELETE", "bundleIds_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.undocumented)
            .on("DELETE", "profiles_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.undocumented)
        let service = try ASCStub.service(router)
        #expect(try await service.deleteCertificate(id: "c") == true)
        #expect(try await service.deleteCertificate(id: "c") == false)
        #expect(try await service.deleteCertificate(id: "c") == false)
        #expect(try await service.deleteBundleId(id: "b") == true)
        #expect(try await service.deleteBundleId(id: "b") == false)
        #expect(try await service.deleteBundleId(id: "b") == false)
        #expect(try await service.deleteProfile(id: "p") == true)
        #expect(try await service.deleteProfile(id: "p") == false)
        #expect(try await service.deleteProfile(id: "p") == false)
        #expect(router.log.requests.first?.path.hasSuffix("/v1/certificates/c") == true)
    }

    // MARK: Bundle IDs

    @Test("fetchBundleIds paginates and filters by identifier")
    func fetchBundleIds() async throws {
        let router = StubRouter()
            .on("GET", "bundleIds_getCollection", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")], next: "\(ASCStub.base)/v1/bundleIds?cursor=2")))
            .on("GET", "cursor=2", .ok(ASCStub.list([ASCStub.bundle("b2", identifier: "com.b")])))
        let ids = try await HTTPStub.withSession(router) { session in
            try await ASCStub.service(router, session: session).fetchBundleIds(identifier: "com.a")
        }
        #expect(ids.map(\.id) == ["b1", "b2"])
        #expect(router.log.requests.first?.query.contains("com.a") == true)
    }

    @Test("resolveOrCreateBundleId prefers non-SERVICES matches and creates when missing")
    func resolveOrCreateBundleId() async throws {
        let router = StubRouter()
            .on("GET", "bundleIds_getCollection",
                .ok(ASCStub.list([ASCStub.bundle("svc", identifier: "com.a", platform: "SERVICES"), ASCStub.bundle("ios", identifier: "com.a")])),
                .ok(ASCStub.list([ASCStub.bundle("svc", identifier: "com.a", platform: "SERVICES")])),
                .ok(ASCStub.list([ASCStub.bundle("other", identifier: "com.other")])),
                .ok(ASCStub.list([])))
            .on("POST", "bundleIds_createInstance", ASCStub.created(ASCStub.single(ASCStub.bundle("created", identifier: "com.a"))))
        let service = try ASCStub.service(router)
        #expect(try await service.resolveOrCreateBundleId(bundleId: "com.a") == "ios")
        #expect(try await service.resolveOrCreateBundleId(bundleId: "com.a") == "svc")
        #expect(try await service.resolveOrCreateBundleId(bundleId: "com.a") == "other")
        #expect(try await service.resolveOrCreateBundleId(bundleId: "com.a") == "created")
        let createAttrs = ASCStub.dataAttrs(router.log.requests.last)
        #expect(createAttrs["name"] as? String == "com a")
        #expect(createAttrs["identifier"] as? String == "com.a")
        #expect(createAttrs["platform"] as? String == "UNIVERSAL")
    }

    @Test("createBundleId throws on unexpected responses")
    func createBundleIdUnexpected() async throws {
        let router = StubRouter().on("POST", "bundleIds_createInstance", ASCStub.undocumented)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await ASCStub.service(router).createBundleId(identifier: "com.a", name: "A", platform: .IOS)
        }
    }

    @Test("addCapability sends Sign in with Apple consent settings; fetchCapabilities decodes list")
    func capabilities() async throws {
        let router = StubRouter()
            .on("POST", "bundleIdCapabilities_createInstance",
                ASCStub.created(ASCStub.single(ASCStub.res("bundleIdCapabilities", "cap1", #"{"capabilityType":"APPLE_ID_AUTH"}"#))),
                ASCStub.undocumented)
            .on("GET", "bundleIds_bundleIdCapabilities_getToManyRelated",
                .ok(ASCStub.list([ASCStub.res("bundleIdCapabilities", "cap1", #"{"capabilityType":"PUSH_NOTIFICATIONS"}"#)])))
        let service = try ASCStub.service(router)
        try await service.addCapability(bundleIdPortalId: "b1", capabilityType: .APPLE_ID_AUTH)
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["capabilityType"] as? String == "APPLE_ID_AUTH")
        let settings = try #require(attrs["settings"] as? [[String: Any]])
        #expect(settings.first?["key"] as? String == "APPLE_ID_AUTH_APP_CONSENT")
        try await service.addCapability(bundleIdPortalId: "b1", capabilityType: .PUSH_NOTIFICATIONS)
        #expect(ASCStub.dataAttrs(router.log.requests[1])["settings"] == nil)
        let caps = try await service.fetchCapabilities(bundleIdPortalId: "b1")
        #expect(caps.map(\.id) == ["cap1"])
        #expect(router.log.requests[2].path.hasSuffix("/v1/bundleIds/b1/bundleIdCapabilities") == true)
    }

    // MARK: Devices

    @Test("fetchDevices paginates; string variant filters by name and limit")
    func fetchDevices() async throws {
        let router = StubRouter()
            .on("GET", "devices_getCollection", .ok(ASCStub.list([
                ASCStub.device("d1", name: "Orkun iPhone"),
                ASCStub.device("d2", name: "Office iPad", cls: "IPAD"),
                ASCStub.device("d3", name: "orkun ipad", cls: "IPAD"),
            ], next: "\(ASCStub.base)/v1/devices?cursor=2")))
            .on("GET", "cursor=2", .ok(ASCStub.list([ASCStub.device("d4", name: "Orkun Mac", cls: "MAC")])))
        let named = try await HTTPStub.withSession(router) { session in
            try await ASCStub.service(router, session: session).fetchDevices(matchingName: " Orkun ", platform: "ios", status: "enabled", udid: nil, limit: 2)
        }
        #expect(named.map(\.id) == ["d1", "d3"])
        let query = router.log.requests.first?.query ?? ""
        #expect(query.contains("IOS"))
        #expect(query.contains("ENABLED"))

        let all = try await HTTPStub.withSession(router) { session in
            try await ASCStub.service(router, session: session).fetchDevices(matchingName: "  ", platform: "bogus", status: "bogus", udid: "U", limit: nil)
        }
        #expect(all.count == 4)
    }

    @Test("registerDevice and disableDevice build payloads and reject unexpected responses")
    func registerAndDisableDevice() async throws {
        let router = StubRouter()
            .on("POST", "devices_createInstance", ASCStub.created(ASCStub.single(ASCStub.device("d1"))), ASCStub.undocumented)
            .on("PATCH", "devices_updateInstance", .ok(ASCStub.single(ASCStub.device("d1"))), ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let device = try await service.registerDevice(name: "Phone", udid: "U1", platform: "macos")
        #expect(device.id == "d1")
        let attrs = ASCStub.dataAttrs(router.log.requests[0])
        #expect(attrs["platform"] as? String == "MAC_OS")
        #expect(attrs["udid"] as? String == "U1")
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.registerDevice(name: "Phone", udid: "U1")
        }
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.registerDevice(name: "Phone", udid: "U1", platform: "android")
        }

        let disabled = try await service.disableDevice(id: "d1")
        #expect(disabled.id == "d1")
        #expect(ASCStub.dataAttrs(router.log.requests.last)["status"] as? String == "DISABLED")
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.disableDevice(id: "d1")
        }
    }

    @Test("findDevice matches by UDID, id, or name")
    func findDevice() async throws {
        let devices = ASCStub.list([
            ASCStub.device("d1", name: "Alpha", udid: "AAA"),
            ASCStub.device("d2", name: "Beta", udid: "BBB"),
        ])
        let router = StubRouter().on("GET", "devices_getCollection", .ok(devices))
        let service = try ASCStub.service(router)
        #expect(try await service.findDevice(udid: "  ") == nil)
        #expect(try await service.findDevice(udid: "bbb")?.id == "d2")
        #expect(try await service.findDevice(udid: "ZZZ") == nil)
        #expect(try await service.findDevice(identifier: "") == nil)
        #expect(try await service.findDevice(identifier: "d2")?.id == "d2")
        #expect(try await service.findDevice(identifier: "aaa")?.id == "d1")
        #expect(try await service.findDevice(identifier: "beta")?.id == "d2")
        #expect(try await service.findDevice(identifier: "gamma") == nil)
    }

    // MARK: Profiles

    @Test("fetchProfiles paginates and filters by name")
    func fetchProfiles() async throws {
        let router = StubRouter()
            .on("GET", "profiles_getCollection", .ok(ASCStub.list([ASCStub.profile("p1")], next: "\(ASCStub.base)/v1/profiles?cursor=2")))
            .on("GET", "cursor=2", .ok(ASCStub.list([ASCStub.profile("p2", expiration: "2030-01-01T00:00:00.000+00:00")])))
        let profiles = try await HTTPStub.withSession(router) { session in
            try await ASCStub.service(router, session: session).fetchProfiles(name: "match X")
        }
        #expect(profiles.map(\.id) == ["p1", "p2"])
        #expect(router.log.requests.first?.query.contains("match") == true)
    }

    @Test("createProfile decodes content, retries on 409 conflict, and validates responses")
    func createProfile() async throws {
        let content = Data("profile-bytes".utf8).base64EncodedString()
        let router = StubRouter()
            .on("POST", "profiles_createInstance",
                .status(409, ASCStub.errors(409, code: "CONFLICT", title: "Dup", detail: "taken")),
                ASCStub.created(ASCStub.single(ASCStub.profile("p1", uuid: "U-1", content: content))),
                ASCStub.created(ASCStub.single(ASCStub.profile("p2", content: content))),
                ASCStub.created(ASCStub.single(ASCStub.profile("p3"))),
                ASCStub.undocumented)
        let service = try ASCStub.service(router)
        let created = try await service.createProfile(name: "match AppStore com.a", profileType: .IOS_APP_STORE, bundleIdPortalId: "b1", certificateId: "c1", deviceIds: ["d1"])
        #expect(created.id == "p1")
        #expect(created.uuid == "U-1")
        #expect(created.name.hasPrefix("match AppStore com.a "))
        #expect(created.profileData == Data("profile-bytes".utf8))
        #expect(router.log.count == 2)
        let retryAttrs = ASCStub.dataAttrs(router.log.requests[1])
        #expect((retryAttrs["name"] as? String)?.hasPrefix("match AppStore com.a ") == true)
        let rel = (ASCStub.json(router.log.requests[1].body)["data"] as? [String: Any])?["relationships"] as? [String: Any]
        #expect(((rel?["devices"] as? [String: Any])?["data"] as? [[String: Any]])?.first?["id"] as? String == "d1")

        let noUUID = try await service.createProfile(name: "n", profileType: .IOS_APP_STORE, bundleIdPortalId: "b1", certificateId: "c1")
        #expect(noUUID.name == "n")
        #expect(!noUUID.uuid.isEmpty)

        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createProfile(name: "n", profileType: .IOS_APP_STORE, bundleIdPortalId: "b1", certificateId: "c1")
        }
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createProfile(name: "n", profileType: .IOS_APP_STORE, bundleIdPortalId: "b1", certificateId: "c1")
        }
    }

    // MARK: Nuke

    @Test("nuke revokes matching certificates and deletes matching profiles")
    func nuke() async throws {
        let router = StubRouter()
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([ASCStub.cert("c1"), ASCStub.cert("c2")])))
            .on("DELETE", "certificates_deleteInstance", ASCStub.noContent, ASCStub.notFound)
            .on("GET", "profiles_getCollection", .ok(ASCStub.list([
                ASCStub.profile("p1", type: "IOS_APP_STORE"),
                ASCStub.profile("p2", type: "IOS_APP_DEVELOPMENT"),
                ASCStub.profile("p3", type: "IOS_APP_STORE"),
            ])))
            .on("DELETE", "profiles_deleteInstance", ASCStub.noContent, ASCStub.notFound)
        let result = try await ASCStub.service(router).nuke(type: "appstore")
        #expect(result.revokedCertIds == ["c1"])
        #expect(result.deletedProfileIds == ["p1"])
        let certQuery = router.log.requests.first?.query ?? ""
        #expect(certQuery.contains("IOS_DISTRIBUTION"))
    }
}

// MARK: - Profiles extension

@Suite("AppStoreService Profiles Coverage")
struct AppStoreServiceProfilesCoverageTests {
    private let content = Data("prof".utf8).base64EncodedString()

    @Test("createProvisioningProfile validates bundle ID and auto-selects certificate")
    func createAppStoreProfile() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("nested/out.mobileprovision").path
        let router = StubRouter()
            .on("GET", "bundleIds_getCollection", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([ASCStub.cert("c1", name: "Dist Cert")])))
            .on("POST", "profiles_createInstance", ASCStub.created(ASCStub.single(ASCStub.profile("p1", uuid: "U", content: content))))
        let service = try ASCStub.service(router)

        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createProvisioningProfile(bundleId: "  ")
        }

        let result = try await service.createProvisioningProfile(bundleId: " com.a ", outputPath: out)
        #expect(result.bundleId == "com.a")
        #expect(result.selectedCertificateId == "c1")
        #expect(result.selectedCertificateName == "Dist Cert")
        #expect(result.includedDeviceCount == 0)
        #expect(result.profileType == .IOS_APP_STORE)
        #expect(result.profile.uuid == "U")
        #expect(result.savedURL?.path == out)
        #expect(try Data(contentsOf: URL(fileURLWithPath: out)) == Data("prof".utf8))
        let attrs = ASCStub.dataAttrs(router.log.requests.last)
        #expect(attrs["name"] as? String == "match AppStore com.a")
    }

    @Test("createProvisioningProfile derives names per type and platform")
    func profileNames() async throws {
        func makeRouter() -> StubRouter {
            StubRouter()
                .on("GET", "bundleIds_getCollection", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
                .on("GET", "devices_getCollection", .ok(ASCStub.list([ASCStub.device("d1"), ASCStub.device("m1", cls: "MAC")])))
                .on("POST", "profiles_createInstance", ASCStub.created(ASCStub.single(ASCStub.profile("p1", content: content))))
        }
        let cases: [(type: String, platform: String, expected: String, devices: Int)] = [
            ("development", "ios", "match Development com.a", 1),
            ("adhoc", "ios", "match AdHoc com.a", 1),
            ("enterprise", "ios", "match InHouse com.a", 0),
            ("developer-id", "macos", "match DeveloperID com.a macos", 0),
            ("dev", "macos", "match Development com.a macos", 1),
        ]
        for testCase in cases {
            let router = makeRouter()
            let result = try await ASCStub.service(router).createProvisioningProfile(
                bundleId: "com.a", type: testCase.type, platform: testCase.platform, certificateId: " c9 "
            )
            #expect(result.selectedCertificateId == "c9")
            #expect(result.selectedCertificateName == nil)
            #expect(result.includedDeviceCount == testCase.devices, "\(testCase.type)")
            #expect(ASCStub.dataAttrs(router.log.requests.last)["name"] as? String == testCase.expected)
        }

        // Explicit name and explicit devices skip lookups.
        let router = makeRouter()
        let result = try await ASCStub.service(router).createProvisioningProfile(
            bundleId: "com.a", type: "development", name: " Custom ", certificateId: "c9", deviceIds: ["x", "y"]
        )
        #expect(result.includedDeviceCount == 2)
        #expect(result.profile.name == "Custom")
        #expect(router.log.requests.contains { $0.operationID == "devices_getCollection" } == false)
    }

    @Test("createProvisioningProfile fails without certificates or devices")
    func profileFailures() async throws {
        let noCerts = StubRouter()
            .on("GET", "bundleIds_getCollection", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([])))
        do {
            _ = try await ASCStub.service(noCerts).createProvisioningProfile(bundleId: "com.a")
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound {}

        let noDevices = StubRouter()
            .on("GET", "bundleIds_getCollection", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
            .on("GET", "devices_getCollection", .ok(ASCStub.list([ASCStub.device("m1", cls: "MAC")])))
        do {
            _ = try await ASCStub.service(noDevices).createProvisioningProfile(bundleId: "com.a", type: "adhoc", certificateId: "c1")
            Issue.record("expected invalidResponse")
        } catch AppStoreServiceError.invalidResponse {}

        await #expect(throws: AppStoreServiceError.self) {
            _ = try await ASCStub.service(StubRouter()).createProvisioningProfile(bundleId: "com.a", type: "weird")
        }
    }

    @Test("deleteProvisioningProfile handles direct id, name/uuid matching, and misses")
    func deleteProvisioningProfile() async throws {
        let router = StubRouter()
            .on("DELETE", "profiles_deleteInstance", ASCStub.noContent)
            .on("GET", "profiles_getCollection", .ok(ASCStub.list([
                ASCStub.profile("p1", name: "One", uuid: "U1"),
                ASCStub.profile("p2", name: "Two", uuid: "U2"),
            ])))
        let service = try ASCStub.service(router)

        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.deleteProvisioningProfile(name: " ", uuid: nil, portalId: "")
        }

        let direct = try await service.deleteProvisioningProfile(portalId: " p9 ")
        #expect(direct.deleted)
        #expect(direct.matchedProfile == nil)
        #expect(direct.targetDescription == "p9")

        let byUUID = try await service.deleteProvisioningProfile(uuid: "U2")
        #expect(byUUID.matchedProfile?.id == "p2")
        #expect(byUUID.deleted)

        let byName = try await service.deleteProvisioningProfile(name: "One")
        #expect(byName.matchedProfile?.id == "p1")
        #expect(byName.targetDescription == "One")

        let byIdWithUUID = try await service.deleteProvisioningProfile(uuid: "nope", portalId: "p2")
        #expect(byIdWithUUID.matchedProfile?.id == "p2")

        let miss = try await service.deleteProvisioningProfile(uuid: "missing")
        #expect(miss.deleted == false)
        #expect(miss.matchedProfile == nil)
    }

    @Test("pruneProfiles finds invalid/expired profiles, supports dry runs, and records failures")
    func pruneProfiles() async throws {
        let profiles = ASCStub.list([
            ASCStub.profile("p1", name: "Invalid", state: "INVALID"),
            ASCStub.profile("p2", name: "Expired", expiration: "2001-01-01T00:00:00Z"),
            ASCStub.profile("p3", name: "Gone", state: "INVALID"),
            ASCStub.profile("p4", name: "Broken", state: "INVALID"),
            ASCStub.profile("p5", name: "Fresh", expiration: "2999-01-01T00:00:00Z"),
        ])
        let router = StubRouter()
            .on("GET", "profiles_getCollection", .ok(profiles))
            .on("DELETE", "profiles_deleteInstance", ASCStub.noContent, ASCStub.noContent, ASCStub.notFound, ASCStub.serverError)
        let service = try ASCStub.service(router)

        let invalidOnly = try await service.inspectProfilesForPruning()
        #expect(invalidOnly.map(\.profile.id) == ["p1", "p3", "p4"])

        let dry = try await service.pruneProfiles(includeExpired: true, dryRun: true)
        #expect(dry.isDryRun)
        #expect(dry.candidates.map(\.reason) == ["INVALID", "EXPIRED", "INVALID", "INVALID"])
        #expect(dry.deletedCount == 0)

        let real = try await service.pruneProfiles(includeExpired: true)
        #expect(real.deletedCount == 2)
        #expect(real.failedProfiles.map(\.name) == ["Gone", "Broken"])
        #expect(real.failedProfiles.first?.error == "Profile was already absent.")

        let emptyRouter = StubRouter().on("GET", "profiles_getCollection", .ok(ASCStub.list([])))
        let empty = try await ASCStub.service(emptyRouter).pruneProfiles()
        #expect(empty.candidates.isEmpty)
        #expect(empty.isDryRun == false)
    }

    @Test("fetchActiveProfileUUIDs and fetchActiveDeviceIds filter by platform/type/state")
    func activeQueries() async throws {
        let router = StubRouter()
            .on("GET", "profiles_getCollection", .ok(ASCStub.list([
                ASCStub.profile("p1", type: "IOS_APP_STORE", uuid: "A"),
                ASCStub.profile("p2", type: "IOS_APP_STORE", state: "INVALID", uuid: "B"),
                ASCStub.profile("p3", type: "IOS_APP_DEVELOPMENT", uuid: "C"),
                ASCStub.profile("p4", type: "IOS_APP_STORE"),
            ])))
            .on("GET", "devices_getCollection", .ok(ASCStub.list([
                ASCStub.device("d1"), ASCStub.device("m1", cls: "MAC"), ASCStub.device("t1", cls: "APPLE_TV"),
            ])))
        let service = try ASCStub.service(router)
        #expect(try await service.fetchActiveProfileUUIDs(platform: "ios", type: "appstore") == ["A"])
        #expect(try await service.fetchActiveDeviceIds(for: " Mac ") == ["m1"])
        #expect(router.log.requests.last?.query.contains("MAC_OS") == true)
        #expect(try await service.fetchActiveDeviceIds(for: "ios") == ["d1"])
        #expect(router.log.requests.last?.query.contains("IOS") == true)
    }
}

// MARK: - Certificates extension

@Suite("AppStoreService Certificates Coverage")
struct AppStoreServiceCertificatesCoverageTests {

    @Test("createSigningCertificateData revokes the certificate when Apple returns no content")
    func createSigningCertificateRollback() async throws {
        let router = StubRouter()
            .on("POST", "certificates_createInstance", ASCStub.created(ASCStub.single(ASCStub.cert("c1", name: "Appitool Development"))))
            .on("DELETE", "certificates_deleteInstance", ASCStub.noContent)
        let service = try ASCStub.service(router)
        do {
            _ = try await service.createSigningCertificateData(type: "development", name: " Custom CN ")
            Issue.record("expected invalidResponse")
        } catch AppStoreServiceError.invalidResponse {}
        let csr = ASCStub.dataAttrs(router.log.requests[0])["csrContent"] as? String
        #expect(csr?.contains("BEGIN CERTIFICATE REQUEST") == true)
        #expect(router.log.requests[1].operationID == "certificates_deleteInstance")
        #expect(router.log.requests[1].path.hasSuffix("/v1/certificates/c1") == true)

        do {
            _ = try await service.createSigningCertificate(type: "distribution", outputDirectory: NSTemporaryDirectory())
            Issue.record("expected invalidResponse")
        } catch AppStoreServiceError.invalidResponse {}

        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.createSigningCertificateData(type: "bogus")
        }
    }

    @Test("deleteSigningCertificate handles direct id, serial/name matching, and misses")
    func deleteSigningCertificate() async throws {
        let router = StubRouter()
            .on("DELETE", "certificates_deleteInstance", ASCStub.noContent)
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([
                ASCStub.cert("c1", name: "One", serial: "S1"),
                ASCStub.cert("c2", name: "Two", serial: "S2"),
            ])))
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.deleteSigningCertificate(portalId: "", name: " ", serialNumber: nil)
        }
        let direct = try await service.deleteSigningCertificate(portalId: "c7")
        #expect(direct.deleted)
        #expect(direct.targetDescription == "c7")

        let bySerial = try await service.deleteSigningCertificate(serialNumber: "S2")
        #expect(bySerial.matchedCertificate?.id == "c2")
        let byName = try await service.deleteSigningCertificate(name: "One")
        #expect(byName.matchedCertificate?.id == "c1")
        let byId = try await service.deleteSigningCertificate(portalId: "c2", name: "zzz")
        #expect(byId.matchedCertificate?.id == "c2")
        let miss = try await service.deleteSigningCertificate(name: "Nope")
        #expect(miss.deleted == false)
        #expect(miss.matchedCertificate == nil)
    }

    @Test("pruneCertificates finds expired certificates, supports dry runs, and records failures")
    func pruneCertificates() async throws {
        let router = StubRouter()
            .on("GET", "certificates_getCollection", .ok(ASCStub.list([
                ASCStub.cert("c1", name: "Old1", expiration: "2001-01-01T00:00:00Z"),
                ASCStub.cert("c2", name: "Old2", expiration: "2002-01-01T00:00:00Z"),
                ASCStub.cert("c3", expiration: "2003-01-01T00:00:00Z"),
                ASCStub.cert("c4", name: "New", expiration: "2999-01-01T00:00:00Z"),
                ASCStub.cert("c5", name: "NoDate"),
            ])))
            .on("DELETE", "certificates_deleteInstance", ASCStub.noContent, ASCStub.notFound, ASCStub.serverError)
        let service = try ASCStub.service(router)
        let dry = try await service.pruneCertificates(typeFilter: "distribution", dryRun: true)
        #expect(dry.candidates.map(\.id) == ["c1", "c2", "c3"])
        #expect(dry.isDryRun)
        #expect(router.log.requests.first?.query.contains("MAC_APP_DISTRIBUTION") == true)

        let real = try await service.pruneCertificates()
        #expect(real.deletedCount == 1)
        #expect(real.failedCertificates.map(\.name) == ["Old2", "unnamed"])
        #expect(real.failedCertificates.first?.error == "Certificate was already absent.")

        let emptyRouter = StubRouter().on("GET", "certificates_getCollection", .ok(ASCStub.list([])))
        let empty = try await ASCStub.service(emptyRouter).pruneCertificates(typeFilter: "unknown")
        #expect(empty.candidates.isEmpty)
    }
}

// MARK: - Identifiers extension

@Suite("AppStoreService Identifiers Coverage")
struct AppStoreServiceIdentifiersCoverageTests {

    @Test("findBundleId / deleteBundleIdByIdentifier / fetchCapabilitiesForIdentifier")
    func lookups() async throws {
        let router = StubRouter()
            .on("GET", "bundleIds_getCollection",
                .ok(ASCStub.list([ASCStub.bundle("b0", identifier: "com.a.other"), ASCStub.bundle("b1", identifier: "com.a")])))
            .on("DELETE", "bundleIds_deleteInstance", ASCStub.noContent)
            .on("GET", "bundleIds_bundleIdCapabilities_getToManyRelated",
                .ok(ASCStub.list([ASCStub.res("bundleIdCapabilities", "cap1", #"{"capabilityType":"ICLOUD"}"#)])))
        let service = try ASCStub.service(router)
        #expect(try await service.findBundleId(identifier: " com.a ")?.id == "b1")
        let deleted = try await service.deleteBundleIdByIdentifier(identifier: "com.a")
        #expect(deleted.found)
        #expect(deleted.portalId == "b1")
        let notFound = try await service.deleteBundleIdByIdentifier(identifier: "com.missing")
        #expect(notFound.found == false)
        #expect(notFound.portalId == nil)

        let caps = try await service.fetchCapabilitiesForIdentifier(identifier: "com.a")
        #expect(caps.bundleId.id == "b1")
        #expect(caps.capabilities.map(\.id) == ["cap1"])
        do {
            _ = try await service.fetchCapabilitiesForIdentifier(identifier: "com.missing")
            Issue.record("expected notFound")
        } catch AppStoreServiceError.notFound {}
    }

    @Test("registerBundleIdWithCapabilities validates input and collects capability failures")
    func register() async throws {
        let router = StubRouter()
            .on("POST", "bundleIds_createInstance", ASCStub.created(ASCStub.single(ASCStub.bundle("b1", identifier: "com.a"))))
            .on("POST", "bundleIdCapabilities_createInstance",
                ASCStub.created(ASCStub.single(ASCStub.res("bundleIdCapabilities", "cap1"))),
                ASCStub.serverError)
        let service = try ASCStub.service(router)
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.registerBundleIdWithCapabilities(identifier: " ")
        }
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.registerBundleIdWithCapabilities(identifier: "com.a", platform: "android")
        }
        await #expect(throws: AppStoreServiceError.self) {
            _ = try await service.registerBundleIdWithCapabilities(identifier: "com.a", capabilities: ["not-a-capability"])
        }
        let result = try await service.registerBundleIdWithCapabilities(
            identifier: "com.a", name: " My App ", platform: "ios", capabilities: ["push", " ", "icloud"]
        )
        #expect(result.bundleId.id == "b1")
        #expect(result.enabledCapabilities == [.PUSH_NOTIFICATIONS])
        #expect(result.failedCapabilities.map(\.capability) == [.ICLOUD])
        #expect(result.failedCapabilities.first?.error.contains("500") == true)
        let createAttrs = ASCStub.dataAttrs(router.log.first { $0.operationID == "bundleIds_createInstance" })
        #expect(createAttrs["name"] as? String == "My App")
        #expect(createAttrs["platform"] as? String == "IOS")
    }
}

// MARK: - Pure helpers

@Suite("AppleServices Helpers Coverage")
struct AppleServicesHelpersCoverageTests {

    @Test("FlexibleDateTranscoder encodes and decodes many ISO 8601 variants")
    func transcoder() throws {
        let transcoder = FlexibleDateTranscoder()
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let encoded = try transcoder.encode(date)
        #expect(encoded == "2023-11-14T22:13:20.500Z")
        #expect(try transcoder.decode(encoded) == date)
        #expect(try transcoder.decode("2023-11-14T22:13:20Z") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try transcoder.decode("2023-11-14T22:13:20.000") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try transcoder.decode("2023-11-14T22:13:20") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(throws: DecodingError.self) { try transcoder.decode("not a date") }
    }

    @Test("CSRGenerator produces a PEM private key and CSR")
    func csr() throws {
        let result = try CSRGenerator.generate(commonName: "Appitool Test")
        #expect(result.privateKeyPEM.contains("PRIVATE KEY"))
        #expect(result.csrPEM.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
    }

    @Test("P12Exporter reports unreadable inputs without spawning processes")
    func p12ExporterErrors() async throws {
        #expect(P12ExporterError.conversionFailed("a").errorDescription == "Failed to convert DER certificate to PEM: a")
        #expect(P12ExporterError.exportFailed("b").errorDescription == "Failed to export PKCS#12 archive: b")
        #expect(P12ExporterError.fileReadError("c").errorDescription == "Failed to read exported PKCS#12 file: c")

        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.p12")
        await #expect(throws: P12ExporterError.self) {
            try await P12Exporter.export(cerPath: dir.appendingPathComponent("missing.cer").path, keyPath: "/nonexistent", to: dest)
        }
        let cer = dir.appendingPathComponent("c.cer")
        try Data([0x30]).write(to: cer)
        await #expect(throws: P12ExporterError.self) {
            try await P12Exporter.export(cerPath: cer.path, keyPath: dir.appendingPathComponent("missing.pem").path, to: dest)
        }
    }

    @Test("AppleTypeMapper parses bundle platforms, capabilities and certificate types")
    func mapperBasics() throws {
        #expect(try AppleTypeMapper.parseBundleIdPlatform(" Universal ") == .UNIVERSAL)
        #expect(try AppleTypeMapper.parseBundleIdPlatform("ios") == .IOS)
        #expect(try AppleTypeMapper.parseBundleIdPlatform("mac") == .MAC_OS)
        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parseBundleIdPlatform("tvos") }

        let aliases: [String: Components.Schemas.CapabilityType] = [
            "push": .PUSH_NOTIFICATIONS, "iap": .IN_APP_PURCHASE, "game_center": .GAME_CENTER, "icloud": .ICLOUD,
            "apple-sign-in": .APPLE_ID_AUTH, "app-groups": .APP_GROUPS, "associated_domains": .ASSOCIATED_DOMAINS,
            "apple-pay": .APPLE_PAY, "healthkit": .HEALTHKIT, "homekit": .HOMEKIT, "sirikit": .SIRIKIT,
            "passbook": .WALLET, "nfc": .NFC_TAG_READING, "maps": .MAPS, "personal-vpn": .PERSONAL_VPN,
            "network-extensions": .NETWORK_EXTENSIONS, "wifi-info": .ACCESS_WIFI_INFORMATION,
            "data-protection": .DATA_PROTECTION, "autofill-credential-provider": .AUTOFILL_CREDENTIAL_PROVIDER,
            "classkit": .CLASSKIT, "multipath": .MULTIPATH, "inter-app-audio": .INTER_APP_AUDIO,
            "wireless-accessory-configuration": .WIRELESS_ACCESSORY_CONFIGURATION,
            "system-extension-install": .SYSTEM_EXTENSION_INSTALL, "user-management": .USER_MANAGEMENT,
            "coremedia-hls-low-latency": .COREMEDIA_HLS_LOW_LATENCY, "network-custom-protocol": .NETWORK_CUSTOM_PROTOCOL,
            "hot-spot": .HOT_SPOT, "access-wifi_information": .ACCESS_WIFI_INFORMATION,
        ]
        for (raw, expected) in aliases {
            #expect(AppleTypeMapper.parseCapability(raw) == expected, "\(raw)")
        }
        #expect(AppleTypeMapper.parseCapability("nonsense") == nil)
        for descriptor in AppleTypeMapper.supportedCapabilities {
            #expect(AppleTypeMapper.parseCapability(descriptor.key)?.rawValue == descriptor.enumName, "\(descriptor.key)")
        }
        let custom = AppleTypeMapper.CapabilityDescriptor(category: "c", key: "k", enumName: "E", description: "d")
        #expect(custom.key == "k")

        let certTypes: [String: Components.Schemas.CertificateType] = [
            "dev": .DEVELOPMENT, "dist": .DISTRIBUTION, "developerid": .DEVELOPER_ID_APPLICATION,
            "ios-development": .IOS_DEVELOPMENT, "ios-distribution": .IOS_DISTRIBUTION,
            "mac-development": .MAC_APP_DEVELOPMENT, "mac-distribution": .MAC_APP_DISTRIBUTION,
            "mac-installer": .MAC_INSTALLER_DISTRIBUTION,
        ]
        for (raw, expected) in certTypes {
            #expect(try AppleTypeMapper.parseCertificateType(raw).certType == expected)
        }
        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parseCertificateType("x") }

        #expect(AppleTypeMapper.parseCertificateQueryFilter(" ") == nil)
        #expect(AppleTypeMapper.parseCertificateQueryFilter("dev") == [.DEVELOPMENT, .IOS_DEVELOPMENT, .MAC_APP_DEVELOPMENT])
        #expect(AppleTypeMapper.parseCertificateQueryFilter("direct") == [.DEVELOPER_ID_APPLICATION])
        #expect(AppleTypeMapper.parseCertificateQueryFilter("ios-distribution") == [.IOS_DISTRIBUTION, .DISTRIBUTION])
        #expect(AppleTypeMapper.parseCertificateQueryFilter("ios-development") == [.IOS_DEVELOPMENT, .DEVELOPMENT])
        #expect(AppleTypeMapper.parseCertificateQueryFilter("mac-distribution") == [.MAC_APP_DISTRIBUTION])
        #expect(AppleTypeMapper.parseCertificateQueryFilter("mac-development") == [.MAC_APP_DEVELOPMENT])
        #expect(AppleTypeMapper.parseCertificateQueryFilter("other") == nil)

        #expect(AppleTypeMapper.parseDevicePlatformFilter("mac") == .MAC_OS)
        #expect(AppleTypeMapper.parseDevicePlatformFilter("universal") == .UNIVERSAL)
        #expect(AppleTypeMapper.parseDevicePlatformFilter("ios") == .IOS)
        #expect(AppleTypeMapper.parseDevicePlatformFilter("x") == nil)
        #expect(AppleTypeMapper.parseDeviceStatusFilter("active") == .ENABLED)
        #expect(AppleTypeMapper.parseDeviceStatusFilter("inactive") == .DISABLED)
        #expect(AppleTypeMapper.parseDeviceStatusFilter("x") == nil)
    }

    @Test("AppleTypeMapper maps profile types, certificate types and device filters per platform")
    func mapperProfiles() throws {
        let profileCases: [(String, String, Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload)] = [
            ("app-store", "ios", .IOS_APP_STORE), ("ad-hoc", "ios", .IOS_APP_ADHOC), ("dev", "ios", .IOS_APP_DEVELOPMENT), ("inhouse", "ios", .IOS_APP_INHOUSE),
            ("appstore", "tvos", .TVOS_APP_STORE), ("adhoc", "tvos", .TVOS_APP_ADHOC), ("development", "tvos", .TVOS_APP_DEVELOPMENT), ("enterprise", "tvos", .TVOS_APP_INHOUSE),
            ("appstore", "mac", .MAC_APP_STORE), ("adhoc", "macos", .MAC_APP_DEVELOPMENT), ("direct", "macos", .MAC_APP_DIRECT),
            ("appstore", "catalyst", .MAC_CATALYST_APP_STORE), ("dev", "catalyst", .MAC_CATALYST_APP_DEVELOPMENT), ("developer_id", "catalyst", .MAC_CATALYST_APP_DIRECT),
        ]
        for (type, platform, expected) in profileCases {
            #expect(try AppleTypeMapper.mapProfileType(type: type, platform: platform) == expected, "\(type) \(platform)")
        }
        for platform in ["ios", "tvos", "macos", "catalyst", "watchos"] {
            #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.mapProfileType(type: "weird", platform: platform) }
        }

        #expect(AppleTypeMapper.appleCertificateTypesForProfile(type: "dev", platform: "macos") == [.DEVELOPMENT, .MAC_APP_DEVELOPMENT])
        #expect(AppleTypeMapper.appleCertificateTypesForProfile(type: "development", platform: "ios") == [.DEVELOPMENT, .IOS_DEVELOPMENT])
        #expect(AppleTypeMapper.appleCertificateTypesForProfile(type: "adhoc", platform: "mac") == [.DISTRIBUTION, .MAC_APP_DISTRIBUTION])
        #expect(AppleTypeMapper.appleCertificateTypesForProfile(type: "appstore", platform: "ios") == [.DISTRIBUTION, .IOS_DISTRIBUTION])
        #expect(AppleTypeMapper.appleCertificateTypesForProfile(type: "direct", platform: "macos") == [.DEVELOPER_ID_APPLICATION])
        #expect(AppleTypeMapper.appleCertificateTypesForProfile(type: "other", platform: "ios") == [.DISTRIBUTION, .IOS_DISTRIBUTION])

        func device(_ id: String, _ cls: Components.Schemas.Device.attributesPayload.deviceClassPayload?) -> Components.Schemas.Device {
            .init(_type: .devices, id: id, attributes: cls.map { .init(deviceClass: $0) })
        }
        let devices = [device("none", nil), device("phone", .IPHONE), device("mac", .MAC), device("tv", .APPLE_TV), device("watch", .APPLE_WATCH)]
        #expect(AppleTypeMapper.filterDeviceIds(devices, for: "ios") == ["none", "phone"])
        #expect(AppleTypeMapper.filterDeviceIds(devices, for: "tvos") == ["none", "tv"])
        #expect(AppleTypeMapper.filterDeviceIds(devices, for: "catalyst") == ["none", "mac"])
        #expect(AppleTypeMapper.filterDeviceIds(devices, for: "other") == ["none", "phone", "mac", "tv", "watch"])

        #expect(AppleTypeMapper.matchesProfileType(profTypeStr: "IOS_APP_STORE", targetType: "appstore", platform: "ios"))
        #expect(AppleTypeMapper.matchesProfileType(profTypeStr: "TVOS_APP_ADHOC", targetType: "adhoc", platform: "tvos"))
        #expect(AppleTypeMapper.matchesProfileType(profTypeStr: "MAC_APP_DEVELOPMENT", targetType: "dev", platform: "mac"))
        #expect(AppleTypeMapper.matchesProfileType(profTypeStr: "MAC_CATALYST_APP_DIRECT", targetType: "enterprise", platform: "catalyst"))
        #expect(AppleTypeMapper.matchesProfileType(profTypeStr: "MAC_APP_DIRECT", targetType: "developer-id", platform: "macos"))
        #expect(!AppleTypeMapper.matchesProfileType(profTypeStr: "IOS_APP_STORE", targetType: "weird", platform: "ios"))
        #expect(!AppleTypeMapper.matchesProfileType(profTypeStr: "IOS_APP_STORE", targetType: "appstore", platform: "watchos"))
        #expect(!AppleTypeMapper.matchesProfileType(profTypeStr: "TVOS_APP_STORE", targetType: "appstore", platform: "ios"))
    }

    @Test("AppleTypeMapper parses user roles, platforms and screenshot display types")
    func mapperRolesAndScreenshots() throws {
        #expect(try AppleTypeMapper.parseUserRole("support") == .CUSTOMER_SUPPORT)
        #expect(try AppleTypeMapper.parseUserRole("reports") == .ACCESS_TO_REPORTS)
        #expect(try AppleTypeMapper.parseUserRole("app manager") == .APP_MANAGER)
        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parseUserRole("boss") }
        #expect(try AppleTypeMapper.parseUserRoles(["admin", " ", "ADMIN", "developer"]) == [.ADMIN, .DEVELOPER])
        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parseUserRoles([" "]) }
        #expect(try AppleTypeMapper.parseUserRoleQueryFilter("finance").rawValue == "FINANCE")
        #expect(try AppleTypeMapper.parseUserInvitationRoleQueryFilter("sales").rawValue == "SALES")

        #expect(try AppleTypeMapper.parsePlatform("ios") == .IOS)
        #expect(try AppleTypeMapper.parsePlatform("mac-os") == .MAC_OS)
        #expect(try AppleTypeMapper.parsePlatform("tv") == .TV_OS)
        #expect(try AppleTypeMapper.parsePlatform("vision-pro") == .VISION_OS)
        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parsePlatform("android") }

        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parseScreenshotDisplayType(" ") }
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("iphone_6.9") == .APP_IPHONE_67)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("APP_IPAD_97") == .APP_IPAD_97)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("ipad pro 3gen 11") == .APP_IPAD_PRO_3GEN_11)
        #expect(try AppleTypeMapper.parseScreenshotDisplayType("watch_ultra") == .APP_WATCH_ULTRA)
        #expect(throws: AppStoreServiceError.self) { try AppleTypeMapper.parseScreenshotDisplayType("toaster") }
        for descriptor in AppleTypeMapper.supportedScreenshotDisplayTypes {
            let parsed = try AppleTypeMapper.parseScreenshotDisplayType(descriptor.key)
            #expect(AppleTypeMapper.cliKey(for: parsed) == descriptor.key)
        }
        let descriptor = AppleTypeMapper.ScreenshotDisplayTypeDescriptor(category: "c", key: "k", enumName: "E", description: "d")
        #expect(descriptor.aliases.isEmpty)
    }
}
