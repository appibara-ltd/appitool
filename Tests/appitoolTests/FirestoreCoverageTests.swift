import Foundation
import Testing
@testable import appitool
@testable import GoogleServices

@Suite("Firestore Coverage Tests")
struct FirestoreCoverageTests {

    private func decodeValue(_ json: String) throws -> FirestoreValue {
        try JSONDecoder().decode(FirestoreValue.self, from: Data(json.utf8))
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Models

    @Test("Error descriptions expose the message or the HTTP status")
    func errorDescriptions() {
        #expect(FirestoreServiceError.invalidPath("p").errorDescription == "p")
        #expect(FirestoreServiceError.invalidInput("i").errorDescription == "i")
        #expect(FirestoreServiceError.invalidQuery("q").errorDescription == "q")
        #expect(FirestoreServiceError.invalidResponse("r").errorDescription == "r")
        #expect(FirestoreServiceError.apiError(status: 403, message: "m").errorDescription == "Firestore API Error (HTTP 403): m")
    }

    @Test("Plain JSON values round-trip through encoding and pretty printing")
    func jsonValueEncoding() throws {
        let value = FirestoreJSONValue.object([
            "n": .null, "b": .bool(true), "i": .integer(3), "d": .double(1.5), "s": .string("a/b"), "a": .array([.integer(1)]),
        ])
        #expect(try encodeJSON(value) == #"{"a":[1],"b":true,"d":1.5,"i":3,"n":null,"s":"a\/b"}"#)
        let pretty = try value.prettyJSONString()
        #expect(pretty.contains("\"s\" : \"a/b\""))
        #expect(try JSONDecoder().decode(FirestoreJSONValue.self, from: Data(#"{"x":[null,1.25,"s",false]}"#.utf8))
            == .object(["x": .array([.null, .double(1.25), .string("s"), .bool(false)])]))
        #expect(FirestoreJSONValue.parseFragment("  ") == nil)
        #expect(FirestoreJSONValue.parseFragment("1, 2") == nil)
        #expect(FirestoreJSONValue.parseFragment("unquoted") == nil)
    }

    @Test("Firestore values decode every wire representation and reject invalid payloads")
    func firestoreValueDecoding() throws {
        #expect(try decodeValue(#"{"integerValue":"12"}"#) == .integer(12))
        #expect(try decodeValue(#"{"integerValue":13}"#) == .integer(13))
        #expect(try decodeValue(#"{"doubleValue":"2.5"}"#) == .double(2.5))
        #expect(try decodeValue(#"{"bytesValue":"AAE="}"#) == .bytes("AAE="))
        #expect(try decodeValue(#"{"referenceValue":"projects/p/databases/(default)/documents/u/1"}"#) == .reference("projects/p/databases/(default)/documents/u/1"))
        #expect(try decodeValue(#"{"geoPointValue":{"latitude":1.5}}"#) == .geoPoint(latitude: 1.5, longitude: 0))
        #expect(try decodeValue(#"{"arrayValue":{}}"#) == .array([]))
        #expect(try decodeValue(#"{"mapValue":{}}"#) == .map([:]))
        #expect(throws: DecodingError.self) { _ = try decodeValue(#"{"integerValue":"abc"}"#) }
        #expect(throws: DecodingError.self) { _ = try decodeValue(#"{"doubleValue":"abc"}"#) }
        #expect(throws: DecodingError.self) { _ = try decodeValue(#"{"unknownValue":1}"#) }
    }

    @Test("Firestore values encode to their wire keys and convert to plain JSON")
    func firestoreValueEncoding() throws {
        #expect(try encodeJSON(FirestoreValue.null) == #"{"nullValue":null}"#)
        #expect(try encodeJSON(FirestoreValue.double(1.5)) == #"{"doubleValue":1.5}"#)
        #expect(try encodeJSON(FirestoreValue.timestamp("t")) == #"{"timestampValue":"t"}"#)
        #expect(try encodeJSON(FirestoreValue.bytes("b")) == #"{"bytesValue":"b"}"#)
        #expect(try encodeJSON(FirestoreValue.reference("r")) == #"{"referenceValue":"r"}"#)
        #expect(try encodeJSON(FirestoreValue.geoPoint(latitude: 1, longitude: 2)) == #"{"geoPointValue":{"latitude":1,"longitude":2}}"#)
        #expect(try encodeJSON(FirestoreValue.array([.boolean(true)])) == #"{"arrayValue":{"values":[{"booleanValue":true}]}}"#)
        #expect(try encodeJSON(FirestoreValue.map(["k": .integer(1)])) == #"{"mapValue":{"fields":{"k":{"integerValue":"1"}}}}"#)

        #expect(FirestoreValue.geoPoint(latitude: 1, longitude: 2).toJSON() == .object(["latitude": .double(1), "longitude": .double(2)]))
        #expect(FirestoreValue.reference("r").toJSON() == .string("r"))
        #expect(FirestoreValue.null.toJSON() == .null)
        #expect(FirestoreValue.fromJSON(.null) == .null)
        #expect(FirestoreValue.fromJSON(.double(2)) == .double(2))
    }

    @Test("Documents expose IDs, relative paths, and JSON objects")
    func documents() {
        let doc = FirestoreDocument(name: "projects/p/databases/(default)/documents/users/alice", fields: ["a": .integer(1)], createTime: "c", updateTime: "u")
        #expect(doc.toJSONObject() == .object([
            "id": .string("alice"), "path": .string("users/alice"), "fields": .object(["a": .integer(1)]),
            "createTime": .string("c"), "updateTime": .string("u"),
        ]))
        #expect(FirestoreDocument(name: "users/bob").relativePath == "users/bob")
        #expect(FirestoreDocument().relativePath == "")
        #expect(FirestoreDocument().documentId == "")
        #expect(FirestoreDocument().toJSONObject() == .object(["id": .string(""), "path": .string(""), "fields": .object([:])]))
    }

    @Test("Filter and order-by parsing reject malformed expressions")
    func parsingErrors() throws {
        #expect(throws: FirestoreServiceError.self) { _ = try FirestoreQueryFilter.parse("   ") }
        #expect(throws: FirestoreServiceError.self) { _ = try FirestoreQueryFilter.parse("justafield") }
        #expect(throws: FirestoreServiceError.self) { _ = try FirestoreQueryFilter.parse("tags in ios") }
        #expect(try FirestoreQueryFilter.parse("tags NOT-IN [1]").op == .notIn)
        #expect(try FirestoreQueryFilter.parse("tags array-contains-any [\"a\"]").op == .arrayContainsAny)
        #expect(try FirestoreQueryFilter.parse("a != b").op == .notEqual)
        #expect(try FirestoreQueryFilter.parse("a < 1").op == .lessThan)
        #expect(try FirestoreQueryFilter.parse("a <= 1").op == .lessThanOrEqual)
        #expect(try FirestoreQueryFilter.parse("a > 1").op == .greaterThan)

        #expect(throws: FirestoreServiceError.self) { _ = try FirestoreOrderBy.parse("") }
        #expect(throws: FirestoreServiceError.self) { _ = try FirestoreOrderBy.parse("age sideways") }
        #expect(throws: FirestoreServiceError.self) { _ = try FirestoreOrderBy.parse("a b c") }
        #expect(try FirestoreOrderBy.parse("age Ascending") == FirestoreOrderBy(fieldPath: "age"))
        #expect(try FirestoreOrderBy.parse("age descending").descending)
    }

    // MARK: - REST Operations

    @Test("Operations validate paths and identifiers before sending requests")
    func pathValidation() async throws {
        let router = StubRouter()
        try await DefaultNetworkStub.firebase(router) { service in
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.listFirestoreCollections(projectId: "p", documentPath: "users") }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.listFirestoreDocuments(projectId: "p", collectionPath: "users/u1") }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.getFirestoreDocument(projectId: "p", documentPath: "users") }
            await #expect(throws: FirestoreServiceError.self) { try await service.deleteFirestoreDocument(projectId: "p", documentPath: "users") }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.queryFirestoreDocuments(projectId: "p", collectionPath: "users/u1") }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.setFirestoreDocument(projectId: "p", path: "users", fields: [:], merge: true) }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.setFirestoreDocument(projectId: "p", path: "a//b", fields: [:]) }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.getFirestoreDocument(projectId: " ", documentPath: "u/1") }
            await #expect(throws: FirestoreServiceError.self) { _ = try await service.getFirestoreDocument(projectId: "p", databaseId: " ", documentPath: "u/1") }
        }
        #expect(!router.log.requests.contains { $0.url.host == "firestore.googleapis.com" })
    }

    @Test("Requests carry paging, ordering, merge masks, and nested query parents")
    func requestConstruction() async throws {
        let router = StubRouter()
            .on("POST", ":listCollectionIds", .ok(#"{"collectionIds":["orders"],"nextPageToken":"n"}"#))
            .on("POST", ":runQuery", .ok(#"[{"document":{"name":"projects/p/databases/(default)/documents/users/u1/orders/o1"}},{"readTime":"t"}]"#))
            .on("PATCH", "/documents/users/u1", .ok(#"{"name":"projects/p/databases/(default)/documents/users/u1"}"#))
            .on("GET", "/documents/users", .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let collections = try await service.listFirestoreCollections(projectId: "p", documentPath: "users/u1", pageSize: 0, pageToken: "tok")
            #expect(collections.collectionIds == ["orders"])
            let docs = try await service.listFirestoreDocuments(projectId: "p", collectionPath: "users", pageSize: 0, pageToken: "pt", orderBy: " age desc ")
            #expect(docs.documents.isEmpty)
            #expect(docs.nextPageToken == nil)
            let written = try await service.setFirestoreDocument(projectId: "p", path: "users/u1", fields: ["plain": .integer(1), "1st": .bool(true), "we`ird\\": .null], merge: true)
            #expect(written.documentId == "u1")
            let results = try await service.queryFirestoreDocuments(projectId: "p", collectionPath: "users/u1/orders", limit: nil, allDescendants: true)
            #expect(results.map(\.documentId) == ["o1"])
        }
        let list = try #require(router.log.first { $0.path.hasSuffix(":listCollectionIds") })
        #expect(list.path.hasSuffix("/documents/users/u1:listCollectionIds"))
        #expect(list.json()["pageSize"] as? Int == 1)
        #expect(list.json()["pageToken"] as? String == "tok")
        let docs = try #require(router.log.first { $0.method == "GET" })
        #expect(docs.query.contains("pageSize=1"))
        #expect(docs.query.contains("pageToken=pt"))
        #expect(docs.query.contains("orderBy=age%20desc"))
        let patch = try #require(router.log.first { $0.method == "PATCH" })
        let mask = patch.url.query?.removingPercentEncoding ?? ""
        #expect(mask.contains("updateMask.fieldPaths=`1st`"))
        #expect(mask.contains("updateMask.fieldPaths=plain"))
        #expect(mask.contains("updateMask.fieldPaths=`we\\`ird\\\\`"))
        let query = try #require(router.log.first { $0.path.hasSuffix(":runQuery") })
        #expect(query.path.hasSuffix("/documents/users/u1:runQuery"))
        let structured = query.json()["structuredQuery"] as? [String: Any]
        #expect((structured?["from"] as? [[String: Any]])?.first?["allDescendants"] as? Bool == true)
        #expect(structured?["limit"] == nil)
    }

    @Test("Missing documents return nil and empty collection listings decode as empty")
    func emptyResponses() async throws {
        let router = StubRouter()
            .on("GET", "/documents/users/ghost", .status(404))
            .on("POST", ":listCollectionIds", .ok("{}"))
        try await DefaultNetworkStub.firebase(router) { service in
            let doc = try await service.getFirestoreDocument(projectId: "p", documentPath: "users/ghost")
            #expect(doc == nil)
            let root = try await service.listFirestoreCollections(projectId: "p", documentPath: "")
            #expect(root.collectionIds.isEmpty)
        }
        #expect(router.log.first { $0.path.hasSuffix(":listCollectionIds") }?.path.hasSuffix("/documents:listCollectionIds") == true)
    }

    @Test("HTTP errors carry Google status and message, raw text, or the status code")
    func errorMessages() async throws {
        let router = StubRouter().on("DELETE", "/documents/u/",
            .status(403, #"{"error":{"status":"PERMISSION_DENIED","message":"Missing permissions"}}"#),
            .status(404, "  not here  "),
            .status(500, ""),
            .status(400, #"{"error":{"status":""}}"#))
        let errors = try await DefaultNetworkStub.firebase(router) { service in
            var collected: [FirestoreServiceError] = []
            for id in ["1", "2", "3", "4"] {
                do {
                    try await service.deleteFirestoreDocument(projectId: "p", documentPath: "u/\(id)")
                } catch let error as FirestoreServiceError {
                    collected.append(error)
                }
            }
            return collected
        }
        #expect(errors == [
            .apiError(status: 403, message: "PERMISSION_DENIED: Missing permissions"),
            .apiError(status: 404, message: "not here"),
            .apiError(status: 500, message: "HTTP 500"),
            .apiError(status: 400, message: #"{"error":{"status":""}}"#),
        ])
    }
}
