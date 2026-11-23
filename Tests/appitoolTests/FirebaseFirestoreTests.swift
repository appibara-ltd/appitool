import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import appitool
import GoogleServices

@Suite("Firebase Firestore Tests", .serialized)
struct FirebaseFirestoreTests {

    private static let testRSAKeyPEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAxwIi0clkvVY5ADLcTDoO+PTOnBKzggUueuBIUroZdgBDu0Ar
    Q5eiOpC/e1Mcm7nMXhFbr/75l+h87wjoRAqEk6Bt3ZVoP5y3svI3F2p+rTmLMfet
    1R2l7sStipnZl2I+4wCJtILEKOaxO3+fu0EdOJMH/DobcRdZrdIlh2URkjMYA0j7
    VBUBcqHxDTzQQwiWhdTWptyFxGoksRYWNGim+hH2pOGC5z45IGab5xggvD9//V6a
    DEM/4KTwdRMrtdlh/AqAM3KNqAmVRHo8esICJVvadb6PcfQ5CFyz8OE7EY9f8DEH
    BUMyWusbVc7UOfAPFnQNyVeXUzuxV4GL7w5MkQIDAQABAoIBAQCI29EyULv08az1
    lASob20IjOLhtoK4sfOLEV7rdYw4+GmcBr86Fre8avskRr3v4lDHiExztnfTnlD8
    2jVRRaJzG+sybaNpy88RQz3b3qMLYf11+Y0UePU6RQvLu45Ga4wv9Ji/CQb50dyk
    vFoPHvKHi6X8McHZfmNwBItGl50D2uNKcg9mJp4bRHNAhwan4GLCrDC0zhf34+JW
    tddl9Z1sNCBiHORB3dnBVj4Y5LGA7oqgwHkGp1Y+LXs4QQo/t2fa9kOlXkxIXs15
    +x7QMr6+g6OMf7/ov0XhYmHFa7A2GgD+tjnbhjqD18/qSONxryE/3YsoYxn3E+pA
    pJaIh8YhAoGBAPql+yv0D4YWTogpH/gRZd2GfKcSZG2tFbdYmb3yLShovNk/nA2h
    8sRxNpuQJL5qyRCa7tIk7wNCit53aQyb4Zrp6bfawAYhENdqpUx/nZbX79pzkEMj
    SzoPhOWh/TQHybidxWlwvmmeV9KBWsmjkSvoqGJfmtPBTEU6W79PkxoFAoGBAMtB
    5UxHO8sHnD9utzulgLfd5RmjT+6GS9CbXJTPKP4HdRn/YBKdfnb+uyG7Xpwe3U2p
    DmFt1431bbTxFmFlDH1RpEijY/Ex9TK4H3pZ2p5Y+/pIQQRoBUJbQQz7pZ3+Eehj
    ee/59sVuMFEN1wjs8VkUbIjD3fHfciiBtsJKUBIdAoGAcMI487YRQcZJQBIYMrZI
    +FanP1YT3g9OxLPUPlJzpEkyJB3sq2le2KcB5Qv8q7lIiPLaW6mH6RSHeruHg8eg
    v9tZbH+5gUhg1jhA8uA6WgD9A26XyMxY7F7M761nRn/2bNp1VBEHaGZ2pdnRqQKv
    rWw2TEMsWPUNxdsSKUe4Kq0CgYBWp00+a9AOCryOPoFXqINr3+ngOEPHiPGhidq6
    hmcPhdZiswEebo6P5KGbC+qV3IK0rTI4Tz/qgYu37GCCPTZJ5xiG70GYfpfue5jP
    7KbLg1xJo6w0WLSFSao+Arrk1ICF9oLx0DtoiEWJCMF4SKvMMmzjEb35dC2TH1nv
    Ewd38QKBgA/hvHE3lwUcslPft3v/jBNaxOtOl3JK+OIDRk1J7ILEi4pDVMvbEJ50
    Hb9Zvy1e97OvjbpOUuAQkLR+y1WE+05NQm02FRpGH+F4x4JlfN1heULlnne3f6Uj
    ja3yzIwBAvLxcp6jMdSW+7bjxB3bwAU2e1Yqtzpqt3WTG5HxzOuK
    -----END RSA PRIVATE KEY-----
    """

    private var sampleServiceAccountJSON: String {
        let escapedKey = Self.testRSAKeyPEM.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {
          "type": "service_account",
          "project_id": "my-firestore-project",
          "private_key_id": "key_id_abc",
          "private_key": "\(escapedKey)",
          "client_email": "firestore-sa@my-firestore-project.iam.gserviceaccount.com",
          "client_id": "1122334455",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "https://oauth2.googleapis.com/token"
        }
        """
    }

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        struct RecordedRequest {
            let method: String
            let url: URL
            let authorization: String?
            let body: Data?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var requestHandler: ((RecordedRequest) throws -> (Int, Data))?
        nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

        static func reset(handler: @escaping (RecordedRequest) throws -> (Int, Data)) {
            lock.withLock {
                recorded = []
                requestHandler = handler
            }
        }

        static func takeRecordedRequests() -> [RecordedRequest] {
            lock.withLock {
                let copy = recorded
                recorded = []
                requestHandler = nil
                return copy
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: bufferSize)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                if !data.isEmpty {
                    bodyData = data
                }
            }

            let captured = RecordedRequest(
                method: request.httpMethod ?? "GET",
                url: request.url!,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: bodyData
            )

            let currentHandler: ((RecordedRequest) throws -> (Int, Data))? = Self.lock.withLock {
                Self.recorded.append(captured)
                return Self.requestHandler
            }

            guard let currentHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }

            do {
                let (statusCode, data) = try currentHandler(captured)
                let response = HTTPURLResponse(
                    url: captured.url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeMockedService(
        handler: @escaping (MockURLProtocol.RecordedRequest) throws -> (Int, Data)
    ) throws -> FirebaseService {
        MockURLProtocol.reset { req in
            if req.url.host == "oauth2.googleapis.com" {
                let tokenJSON = #"{"access_token":"test_firestore_token","expires_in":3600,"token_type":"Bearer"}"#
                return (200, Data(tokenJSON.utf8))
            }
            return try handler(req)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return try FirebaseService(key: sampleServiceAccountJSON, urlSession: session)
    }

    // MARK: - JSON & Firestore Value Codec Tests

    @Test("Encodes and decodes FirestoreJSONValue and FirestoreValue including string integers, empty containers, and special types")
    func valueCodecRoundTrips() throws {
        let jsonInput = #"""
        {
          "flag": true,
          "count": 42,
          "ratio": 3.5,
          "note": "hello",
          "empty": null,
          "tags": ["ios", "swift"],
          "nested": { "enabled": false, "retries": 2 }
        }
        """#
        let decodedPlain = try JSONDecoder().decode([String: FirestoreJSONValue].self, from: Data(jsonInput.utf8))
        #expect(decodedPlain["flag"] == .bool(true))
        #expect(decodedPlain["count"] == .integer(42))
        #expect(decodedPlain["ratio"] == .double(3.5))
        #expect(decodedPlain["note"] == .string("hello"))
        #expect(decodedPlain["empty"] == .null)
        #expect(decodedPlain["tags"] == .array([.string("ios"), .string("swift")]))

        let firestoreMap = FirestoreValue.map(decodedPlain.mapValues { FirestoreValue.fromJSON($0) })
        let wireData = try JSONEncoder().encode(firestoreMap)
        let wireJSON = try JSONSerialization.jsonObject(with: wireData) as? [String: Any]
        let mapValue = try #require(wireJSON?["mapValue"] as? [String: Any])
        let wireFields = try #require(mapValue["fields"] as? [String: Any])
        let countPayload = try #require(wireFields["count"] as? [String: Any])
        #expect(countPayload["integerValue"] as? String == "42")

        let decodedWire = try JSONDecoder().decode(FirestoreValue.self, from: wireData)
        #expect(decodedWire.toJSON() == .object(decodedPlain))

        // Special wire types & empty arrayValue/mapValue
        let specialWireJSON = #"""
        {
          "mapValue": {
            "fields": {
              "ts": { "timestampValue": "2026-11-23T12:00:00Z" },
              "loc": { "geoPointValue": { "latitude": 41.0082, "longitude": 28.9784 } },
              "ref": { "referenceValue": "projects/p/databases/(default)/documents/users/u1" },
              "raw": { "bytesValue": "AQID" },
              "emptyArr": { "arrayValue": {} },
              "emptyMap": { "mapValue": {} }
            }
          }
        }
        """#
        let special = try JSONDecoder().decode(FirestoreValue.self, from: Data(specialWireJSON.utf8))
        guard case .map(let specialFields) = special else {
            Issue.record("Expected map value")
            return
        }
        #expect(specialFields["ts"] == .timestamp("2026-11-23T12:00:00Z"))
        #expect(specialFields["loc"] == .geoPoint(latitude: 41.0082, longitude: 28.9784))
        #expect(specialFields["ref"] == .reference("projects/p/databases/(default)/documents/users/u1"))
        #expect(specialFields["raw"] == .bytes("AQID"))
        #expect(specialFields["emptyArr"] == .array([]))
        #expect(specialFields["emptyMap"] == .map([:]))
    }

    // MARK: - Query Filter & OrderBy Parsing Tests

    @Test("Parses Firestore --where filters and --order-by clauses cleanly")
    func queryParsing() throws {
        let eqBare = try FirestoreQueryFilter.parse("status == active")
        #expect(eqBare == FirestoreQueryFilter(fieldPath: "status", op: .equal, value: .string("active")))

        let eqLogin = try FirestoreQueryFilter.parse("login==true")
        #expect(eqLogin == FirestoreQueryFilter(fieldPath: "login", op: .equal, value: .boolean(true)))

        let neq = try FirestoreQueryFilter.parse("deleted != null")
        #expect(neq == FirestoreQueryFilter(fieldPath: "deleted", op: .notEqual, value: .null))

        let lt = try FirestoreQueryFilter.parse("score < 99.5")
        #expect(lt == FirestoreQueryFilter(fieldPath: "score", op: .lessThan, value: .double(99.5)))

        let lte = try FirestoreQueryFilter.parse("age <= 30")
        #expect(lte == FirestoreQueryFilter(fieldPath: "age", op: .lessThanOrEqual, value: .integer(30)))

        let gt = try FirestoreQueryFilter.parse("note > \"a in b\"")
        #expect(gt == FirestoreQueryFilter(fieldPath: "note", op: .greaterThan, value: .string("a in b")))

        let gte = try FirestoreQueryFilter.parse("profile.level >= 5")
        #expect(gte == FirestoreQueryFilter(fieldPath: "profile.level", op: .greaterThanOrEqual, value: .integer(5)))

        let contains = try FirestoreQueryFilter.parse("tags array-contains \"ios\"")
        #expect(contains == FirestoreQueryFilter(fieldPath: "tags", op: .arrayContains, value: .string("ios")))

        let inFilter = try FirestoreQueryFilter.parse(#"role in ["admin", "editor"]"#)
        #expect(inFilter == FirestoreQueryFilter(fieldPath: "role", op: .in, value: .array([.string("admin"), .string("editor")])))

        let notIn = try FirestoreQueryFilter.parse(#"tier not-in [1, 2]"#)
        #expect(notIn == FirestoreQueryFilter(fieldPath: "tier", op: .notIn, value: .array([.integer(1), .integer(2)])))

        let containsAny = try FirestoreQueryFilter.parse(#"flags ARRAY-CONTAINS-ANY ["beta", "alpha"]"#)
        #expect(containsAny == FirestoreQueryFilter(fieldPath: "flags", op: .arrayContainsAny, value: .array([.string("beta"), .string("alpha")])))

        #expect(try FirestoreOrderBy.parse("createdAt") == FirestoreOrderBy(fieldPath: "createdAt", descending: false))
        #expect(try FirestoreOrderBy.parse("name asc") == FirestoreOrderBy(fieldPath: "name", descending: false))
        #expect(try FirestoreOrderBy.parse("createdAt DESC") == FirestoreOrderBy(fieldPath: "createdAt", descending: true))

        for bad in ["", "   ", "== 1", "age >=", "role in admin", "foo bar == 1"] {
            #expect(throws: FirestoreServiceError.self) {
                _ = try FirestoreQueryFilter.parse(bad)
            }
        }
        for badOrder in ["", "field side", "a b c"] {
            #expect(throws: FirestoreServiceError.self) {
                _ = try FirestoreOrderBy.parse(badOrder)
            }
        }
    }

    @Test("Validates Firestore paths and builds single vs composite structured queries")
    func pathAndStructuredQueryBuilder() throws {
        #expect(FirebaseService.normalizeFirestorePath(" /users/alice/ ") == "users/alice")
        #expect(FirebaseService.isCollectionPath("users"))
        #expect(FirebaseService.isCollectionPath("users/alice/orders"))
        #expect(!FirebaseService.isCollectionPath("users/alice"))
        #expect(!FirebaseService.isCollectionPath(""))

        #expect(FirebaseService.isDocumentPath("users/alice"))
        #expect(FirebaseService.isDocumentPath("users/alice/orders/ord1"))
        #expect(!FirebaseService.isDocumentPath("users"))
        #expect(!FirebaseService.isDocumentPath("users//alice"))

        let singleBody = try FirebaseService.buildStructuredQueryBody(
            collectionId: "users",
            filters: [FirestoreQueryFilter(fieldPath: "active", op: .equal, value: .boolean(true))],
            orderBy: [FirestoreOrderBy(fieldPath: "createdAt", descending: true)],
            limit: 10,
            allDescendants: true
        )
        let singleJSON = try #require(try JSONSerialization.jsonObject(with: singleBody) as? [String: Any])
        let singleQuery = try #require(singleQueryDict(singleJSON))
        let singleWhere = try #require(singleQuery["where"] as? [String: Any])
        #expect(singleWhere["fieldFilter"] != nil)
        #expect(singleWhere["compositeFilter"] == nil)

        let multiBody = try FirebaseService.buildStructuredQueryBody(
            collectionId: "users",
            filters: [
                FirestoreQueryFilter(fieldPath: "active", op: .equal, value: .boolean(true)),
                FirestoreQueryFilter(fieldPath: "age", op: .greaterThanOrEqual, value: .integer(18)),
            ],
            limit: 25
        )
        let multiJSON = try #require(try JSONSerialization.jsonObject(with: multiBody) as? [String: Any])
        let multiQuery = try #require(singleQueryDict(multiJSON))
        let multiWhere = try #require(multiQuery["where"] as? [String: Any])
        let composite = try #require(multiWhere["compositeFilter"] as? [String: Any])
        #expect(composite["op"] as? String == "AND")
        let subFilters = try #require(composite["filters"] as? [[String: Any]])
        #expect(subFilters.count == 2)
    }

    private func singleQueryDict(_ root: [String: Any]) -> [String: Any]? {
        root["structuredQuery"] as? [String: Any]
    }

    // MARK: - Firestore REST Service Tests

    @Test("Executes collections, list, get, set, query, delete, 404, and 403 error paths against mocked URLSession")
    func firestoreRestOperations() async throws {
        // 1. listFirestoreCollections
        let serviceCollections = try makeMockedService { _ in
            (200, Data(#"{"collectionIds":["users","orders"],"nextPageToken":"tok_next"}"#.utf8))
        }
        defer { _ = MockURLProtocol.takeRecordedRequests() }
        let (cols, colToken) = try await serviceCollections.listFirestoreCollections(
            projectId: "my-firestore-project",
            documentPath: "tenants/t1",
            pageSize: 20
        )
        #expect(cols == ["users", "orders"])
        #expect(colToken == "tok_next")
        let colRequests = MockURLProtocol.takeRecordedRequests().filter { $0.url.host == "firestore.googleapis.com" }
        #expect(colRequests.count == 1)
        #expect(colRequests.first?.method == "POST")
        #expect(colRequests.first?.authorization == "Bearer test_firestore_token")
        #expect(colRequests.first?.url.path == "/v1/projects/my-firestore-project/databases/(default)/documents/tenants/t1:listCollectionIds")

        // 2. listFirestoreDocuments
        let listJSON = #"""
        {
          "documents": [
            {
              "name": "projects/my-firestore-project/databases/(default)/documents/users/alice",
              "fields": { "role": { "stringValue": "admin" }, "level": { "integerValue": "5" } },
              "createTime": "2026-11-23T10:00:00Z",
              "updateTime": "2026-11-23T11:00:00Z"
            }
          ]
        }
        """#
        let serviceList = try makeMockedService { _ in (200, Data(listJSON.utf8)) }
        let (docs, _) = try await serviceList.listFirestoreDocuments(
            projectId: "my-firestore-project",
            collectionPath: "users",
            pageSize: 15,
            orderBy: "level desc"
        )
        #expect(docs.count == 1)
        #expect(docs.first?.documentId == "alice")
        #expect(docs.first?.relativePath == "users/alice")
        #expect(docs.first?.plainFields["level"] == .integer(5))
        let listReq = try #require(MockURLProtocol.takeRecordedRequests().last(where: { $0.url.host == "firestore.googleapis.com" }))
        #expect(listReq.method == "GET")
        let listQueryItems = URLComponents(url: listReq.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(listQueryItems.contains(URLQueryItem(name: "pageSize", value: "15")))
        #expect(listQueryItems.contains(URLQueryItem(name: "orderBy", value: "level desc")))

        // 3. getFirestoreDocument (200 and 404 -> nil)
        let service404 = try makeMockedService { _ in (404, Data(#"{"error":{"code":404,"message":"Not found"}}"#.utf8)) }
        let missingDoc = try await service404.getFirestoreDocument(projectId: "my-firestore-project", documentPath: "users/missing")
        #expect(missingDoc == nil)
        _ = MockURLProtocol.takeRecordedRequests()

        // 4. setFirestoreDocument (merge PATCH + collection POST + invalid merge on collection)
        let savedDocJSON = #"""
        {
          "name": "projects/my-firestore-project/databases/(default)/documents/users/alice",
          "fields": { "app-version": { "stringValue": "1.2.0" }, "active": { "booleanValue": true } }
        }
        """#
        let serviceMerge = try makeMockedService { _ in (200, Data(savedDocJSON.utf8)) }
        let merged = try await serviceMerge.setFirestoreDocument(
            projectId: "my-firestore-project",
            path: "users/alice",
            fields: ["active": .bool(true), "app-version": .string("1.2.0")],
            merge: true
        )
        #expect(merged.documentId == "alice")
        let mergeReq = try #require(MockURLProtocol.takeRecordedRequests().last(where: { $0.url.host == "firestore.googleapis.com" }))
        #expect(mergeReq.method == "PATCH")
        let maskValues = URLComponents(url: mergeReq.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "updateMask.fieldPaths" }
            .compactMap(\.value) ?? []
        #expect(maskValues == ["active", "`app-version`"])

        let serviceCreate = try makeMockedService { _ in (200, Data(savedDocJSON.utf8)) }
        _ = try await serviceCreate.setFirestoreDocument(
            projectId: "my-firestore-project",
            path: "users",
            fields: ["active": .bool(true)],
            merge: false
        )
        let createReq = try #require(MockURLProtocol.takeRecordedRequests().last(where: { $0.url.host == "firestore.googleapis.com" }))
        #expect(createReq.method == "POST")
        #expect(createReq.url.path == "/v1/projects/my-firestore-project/databases/(default)/documents/users")

        do {
            _ = try await serviceCreate.setFirestoreDocument(
                projectId: "my-firestore-project",
                path: "users",
                fields: ["active": .bool(true)],
                merge: true
            )
            Issue.record("Expected invalidInput when merge is used with a collection path")
        } catch FirestoreServiceError.invalidInput {
            // Expected
        }

        // 5. queryFirestoreDocuments on nested subcollection
        let runQueryJSON = #"""
        [
          {
            "document": {
              "name": "projects/my-firestore-project/databases/(default)/documents/users/alice/orders/ord1",
              "fields": { "total": { "integerValue": "100" } }
            },
            "readTime": "2026-11-23T12:00:00Z"
          },
          {
            "readTime": "2026-11-23T12:00:00Z"
          }
        ]
        """#
        let serviceQuery = try makeMockedService { _ in (200, Data(runQueryJSON.utf8)) }
        let queried = try await serviceQuery.queryFirestoreDocuments(
            projectId: "my-firestore-project",
            collectionPath: "users/alice/orders",
            filters: [try FirestoreQueryFilter.parse("total >= 50")],
            limit: 5
        )
        #expect(queried.count == 1)
        #expect(queried.first?.documentId == "ord1")
        let queryReq = try #require(MockURLProtocol.takeRecordedRequests().last(where: { $0.url.host == "firestore.googleapis.com" }))
        #expect(queryReq.method == "POST")
        #expect(queryReq.url.path == "/v1/projects/my-firestore-project/databases/(default)/documents/users/alice:runQuery")

        // 6. deleteFirestoreDocument
        let serviceDelete = try makeMockedService { _ in (200, Data("{}".utf8)) }
        try await serviceDelete.deleteFirestoreDocument(projectId: "my-firestore-project", documentPath: "users/alice")
        let deleteReq = try #require(MockURLProtocol.takeRecordedRequests().last(where: { $0.url.host == "firestore.googleapis.com" }))
        #expect(deleteReq.method == "DELETE")
        #expect(deleteReq.url.path == "/v1/projects/my-firestore-project/databases/(default)/documents/users/alice")

        // 7. HTTP 403 Permission Denied error parsing
        let error403JSON = #"{"error":{"code":403,"message":"Missing or insufficient permissions.","status":"PERMISSION_DENIED"}}"#
        let service403 = try makeMockedService { _ in (403, Data(error403JSON.utf8)) }
        defer { _ = MockURLProtocol.takeRecordedRequests() }
        do {
            _ = try await service403.getFirestoreDocument(projectId: "my-firestore-project", documentPath: "users/alice")
            Issue.record("Expected FirestoreServiceError.apiError for HTTP 403")
        } catch FirestoreServiceError.apiError(let status, let message) {
            #expect(status == 403)
            #expect(message == "PERMISSION_DENIED: Missing or insufficient permissions.")
        }
    }

    // MARK: - Project ID Resolution & CLI Parsing Tests

    @Test("FirebaseProjectOptions.requireProjectId prioritizes CLI > FIREBASE_PROJECT_ID > GOOGLE_PROJECT_ID > Service Account project_id")
    func requireProjectIdPrecedence() throws {
        let keys = ["FIREBASE_PROJECT_ID", "GOOGLE_PROJECT_ID", "FIREBASE_IOS_APP_ID"]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, EnvLoader.value(for: $0) ?? "") })
        defer {
            for (key, value) in originals {
                EnvLoader.setEnvironmentVariable(key: key, value: value, overwrite: true)
            }
        }

        for key in keys {
            EnvLoader.setEnvironmentVariable(key: key, value: "", overwrite: true)
        }
        // App ID numeric fallback must NOT be used for Firestore string project IDs.
        EnvLoader.setEnvironmentVariable(key: "FIREBASE_IOS_APP_ID", value: "1:999888777:ios:abc", overwrite: true)

        let emptyOpts = try FirebaseProjectOptions.parse([])
        #expect(throws: ValidationError.self) {
            _ = try emptyOpts.requireProjectId(fallbackServiceProjectId: nil)
        }
        #expect(try emptyOpts.requireProjectId(fallbackServiceProjectId: "sa-proj") == "sa-proj")

        EnvLoader.setEnvironmentVariable(key: "GOOGLE_PROJECT_ID", value: "google-proj", overwrite: true)
        #expect(try emptyOpts.requireProjectId(fallbackServiceProjectId: "sa-proj") == "google-proj")

        EnvLoader.setEnvironmentVariable(key: "FIREBASE_PROJECT_ID", value: "firebase-proj", overwrite: true)
        #expect(try emptyOpts.requireProjectId(fallbackServiceProjectId: "sa-proj") == "firebase-proj")

        let cliOpts = try FirebaseProjectOptions.parse(["--project", "cli-proj"])
        #expect(try cliOpts.requireProjectId(fallbackServiceProjectId: "sa-proj") == "cli-proj")
    }

    @Test("FirebaseCommand parses all six Firestore subcommands and options")
    func firebaseFirestoreCLISubcommandParsing() throws {
        let collections = try #require(
            try FirebaseCommand.parseAsRoot(["firestore", "collections", "users/alice", "-l", "20", "--json"]) as? FirestoreCollectionsCommand
        )
        #expect(collections.path == "users/alice")
        #expect(collections.limit == 20)
        #expect(collections.json == true)

        let list = try #require(
            try FirebaseCommand.parseAsRoot(["firestore", "list", "users", "-l", "25", "--order-by", "createdAt desc", "--database", "staging"]) as? FirestoreListCommand
        )
        #expect(list.path == "users")
        #expect(list.limit == 25)
        #expect(list.orderBy == "createdAt desc")
        #expect(list.firestore.database == "staging")

        let get = try #require(
            try FirebaseCommand.parseAsRoot(["firestore", "get", "users/alice", "--json"]) as? FirestoreGetCommand
        )
        #expect(get.path == "users/alice")
        #expect(get.json == true)

        let set = try #require(
            try FirebaseCommand.parseAsRoot(["firestore", "set", "users/alice", "--data", #"{"active":true}"#, "--merge", "--json"]) as? FirestoreSetCommand
        )
        #expect(set.path == "users/alice")
        #expect(set.data == #"{"active":true}"#)
        #expect(set.merge == true)
        #expect(set.json == true)

        let delete = try #require(
            try FirebaseCommand.parseAsRoot(["firestore", "delete", "users/alice", "--dry-run"]) as? FirestoreDeleteCommand
        )
        #expect(delete.path == "users/alice")
        #expect(delete.dryRun == true)

        let query = try #require(
            try FirebaseCommand.parseAsRoot([
                "firestore", "query", "orders",
                "-w", "status == paid",
                "-w", "total >= 100",
                "--order-by", "createdAt desc",
                "-l", "10",
                "--all-descendants",
                "--json",
            ]) as? FirestoreQueryCommand
        )
        #expect(query.path == "orders")
        #expect(query.filters == ["status == paid", "total >= 100"])
        #expect(query.orderBy == ["createdAt desc"])
        #expect(query.limit == 10)
        #expect(query.allDescendants == true)
        #expect(query.json == true)
    }
}
