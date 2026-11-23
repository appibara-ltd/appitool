import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors originating from Cloud Firestore REST API v1 operations or CLI query/input parsing.
package enum FirestoreServiceError: LocalizedError, Sendable, Equatable {
    case invalidPath(String)
    case invalidInput(String)
    case invalidQuery(String)
    case apiError(status: Int, message: String)
    case invalidResponse(String)

    package var errorDescription: String? {
        switch self {
        case .invalidPath(let message),
             .invalidInput(let message),
             .invalidQuery(let message),
             .invalidResponse(let message):
            return message
        case .apiError(let status, let message):
            return "Firestore API Error (HTTP \(status)): \(message)"
        }
    }
}

/// Cross-platform `Sendable` representation of arbitrary JSON values for Cloud Firestore CLI I/O.
package enum FirestoreJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([FirestoreJSONValue])
    case object([String: FirestoreJSONValue])

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int64.self) {
            self = .integer(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([FirestoreJSONValue].self) {
            self = .array(arrayVal)
        } else if let objectVal = try? container.decode([String: FirestoreJSONValue].self) {
            self = .object(objectVal)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value for Cloud Firestore."
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let fields):
            try container.encode(fields)
        }
    }

    /// Formats this value as sorted, pretty-printed JSON text.
    package func prettyJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decodes a JSON text value (supporting top-level fragments such as booleans, numbers, or strings).
    package static func parseFragment(_ raw: String) -> FirestoreJSONValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wrapped = "[\(trimmed)]"
        guard let data = wrapped.data(using: .utf8),
              let array = try? JSONDecoder().decode([FirestoreJSONValue].self, from: data),
              array.count == 1,
              let first = array.first else {
            return nil
        }
        return first
    }
}

/// Typed representation of Cloud Firestore REST API v1 `Value` objects.
package enum FirestoreValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    case timestamp(String)
    case string(String)
    case bytes(String)
    case reference(String)
    case geoPoint(latitude: Double, longitude: Double)
    case array([FirestoreValue])
    case map([String: FirestoreValue])

    private enum CodingKeys: String, CodingKey {
        case nullValue
        case booleanValue
        case integerValue
        case doubleValue
        case timestampValue
        case stringValue
        case bytesValue
        case referenceValue
        case geoPointValue
        case arrayValue
        case mapValue
    }

    private struct GeoPointPayload: Codable {
        let latitude: Double?
        let longitude: Double?
    }

    private struct ArrayPayload: Codable {
        let values: [FirestoreValue]?
    }

    private struct MapPayload: Codable {
        let fields: [String: FirestoreValue]?
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.nullValue) {
            self = .null
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .booleanValue) {
            self = .boolean(value)
        } else if container.contains(.integerValue) {
            if let str = try? container.decode(String.self, forKey: .integerValue),
               let parsed = Int64(str) {
                self = .integer(parsed)
            } else if let num = try? container.decode(Int64.self, forKey: .integerValue) {
                self = .integer(num)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .integerValue,
                    in: container,
                    debugDescription: "Invalid integerValue in Firestore response."
                )
            }
        } else if container.contains(.doubleValue) {
            if let num = try? container.decode(Double.self, forKey: .doubleValue) {
                self = .double(num)
            } else if let str = try? container.decode(String.self, forKey: .doubleValue),
                      let num = Double(str) {
                self = .double(num)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .doubleValue,
                    in: container,
                    debugDescription: "Invalid doubleValue in Firestore response."
                )
            }
        } else if let value = try container.decodeIfPresent(String.self, forKey: .timestampValue) {
            self = .timestamp(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .stringValue) {
            self = .string(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .bytesValue) {
            self = .bytes(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .referenceValue) {
            self = .reference(value)
        } else if let point = try container.decodeIfPresent(GeoPointPayload.self, forKey: .geoPointValue) {
            self = .geoPoint(latitude: point.latitude ?? 0, longitude: point.longitude ?? 0)
        } else if let array = try container.decodeIfPresent(ArrayPayload.self, forKey: .arrayValue) {
            self = .array(array.values ?? [])
        } else if let map = try container.decodeIfPresent(MapPayload.self, forKey: .mapValue) {
            self = .map(map.fields ?? [:])
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unrecognized Firestore Value payload."
                )
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encodeNil(forKey: .nullValue)
        case .boolean(let value):
            try container.encode(value, forKey: .booleanValue)
        case .integer(let value):
            try container.encode(String(value), forKey: .integerValue)
        case .double(let value):
            try container.encode(value, forKey: .doubleValue)
        case .timestamp(let value):
            try container.encode(value, forKey: .timestampValue)
        case .string(let value):
            try container.encode(value, forKey: .stringValue)
        case .bytes(let value):
            try container.encode(value, forKey: .bytesValue)
        case .reference(let value):
            try container.encode(value, forKey: .referenceValue)
        case .geoPoint(let latitude, let longitude):
            try container.encode(GeoPointPayload(latitude: latitude, longitude: longitude), forKey: .geoPointValue)
        case .array(let values):
            try container.encode(ArrayPayload(values: values), forKey: .arrayValue)
        case .map(let fields):
            try container.encode(MapPayload(fields: fields), forKey: .mapValue)
        }
    }

    /// Converts a plain `FirestoreJSONValue` into a Firestore REST `FirestoreValue`.
    package static func fromJSON(_ json: FirestoreJSONValue) -> FirestoreValue {
        switch json {
        case .null:
            return .null
        case .bool(let value):
            return .boolean(value)
        case .integer(let value):
            return .integer(value)
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map { fromJSON($0) })
        case .object(let fields):
            return .map(fields.mapValues { fromJSON($0) })
        }
    }

    /// Converts this Firestore REST `FirestoreValue` into a plain `FirestoreJSONValue`.
    package func toJSON() -> FirestoreJSONValue {
        switch self {
        case .null:
            return .null
        case .boolean(let value):
            return .bool(value)
        case .integer(let value):
            return .integer(value)
        case .double(let value):
            return .double(value)
        case .timestamp(let value),
             .string(let value),
             .bytes(let value),
             .reference(let value):
            return .string(value)
        case .geoPoint(let latitude, let longitude):
            return .object([
                "latitude": .double(latitude),
                "longitude": .double(longitude),
            ])
        case .array(let values):
            return .array(values.map { $0.toJSON() })
        case .map(let fields):
            return .object(fields.mapValues { $0.toJSON() })
        }
    }
}

/// Cloud Firestore REST API v1 `Document` model.
package struct FirestoreDocument: Codable, Equatable, Sendable {
    package let name: String?
    package let fields: [String: FirestoreValue]?
    package let createTime: String?
    package let updateTime: String?

    package init(
        name: String? = nil,
        fields: [String: FirestoreValue]? = nil,
        createTime: String? = nil,
        updateTime: String? = nil
    ) {
        self.name = name
        self.fields = fields
        self.createTime = createTime
        self.updateTime = updateTime
    }

    /// The document ID (final path segment of `name`).
    package var documentId: String {
        name?.split(separator: "/").last.map(String.init) ?? ""
    }

    /// The document path relative to `.../documents/` (e.g. `users/alice`).
    package var relativePath: String {
        guard let name else { return "" }
        if let range = name.range(of: "/documents/") {
            return String(name[range.upperBound...])
        }
        return name
    }

    /// Document fields converted into plain `FirestoreJSONValue` values.
    package var plainFields: [String: FirestoreJSONValue] {
        (fields ?? [:]).mapValues { $0.toJSON() }
    }

    /// Converts the document into a JSON object suitable for `--json` CLI output.
    package func toJSONObject() -> FirestoreJSONValue {
        var obj: [String: FirestoreJSONValue] = [
            "id": .string(documentId),
            "path": .string(relativePath),
            "fields": .object(plainFields),
        ]
        if let createTime {
            obj["createTime"] = .string(createTime)
        }
        if let updateTime {
            obj["updateTime"] = .string(updateTime)
        }
        return .object(obj)
    }
}

/// Structured query filter parsed from CLI `--where` expressions.
package struct FirestoreQueryFilter: Equatable, Sendable {
    package enum Operator: String, Sendable {
        case equal = "EQUAL"
        case notEqual = "NOT_EQUAL"
        case lessThan = "LESS_THAN"
        case lessThanOrEqual = "LESS_THAN_OR_EQUAL"
        case greaterThan = "GREATER_THAN"
        case greaterThanOrEqual = "GREATER_THAN_OR_EQUAL"
        case arrayContains = "ARRAY_CONTAINS"
        case `in` = "IN"
        case notIn = "NOT_IN"
        case arrayContainsAny = "ARRAY_CONTAINS_ANY"
    }

    package let fieldPath: String
    package let op: Operator
    package let value: FirestoreValue

    package init(fieldPath: String, op: Operator, value: FirestoreValue) {
        self.fieldPath = fieldPath
        self.op = op
        self.value = value
    }

    /// Parses a filter expression such as `"status == active"`, `"age >= 18"`, or `"tags array-contains \"ios\""`.
    package static func parse(_ expression: String) throws -> FirestoreQueryFilter {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FirestoreServiceError.invalidQuery("Filter expression cannot be empty.")
        }

        // Match word operators (`in`, `not-in`, `array-contains`, `array-contains-any`) or symbol operators
        // after a valid non-empty field token so values containing `=` or `in` do not cause false splits.
        let pattern = #"^((?:`[^`]+`|[^\s<>=!]+)(?:\.(?:`[^`]+`|[^\s<>=!]+))*)(?:\s*(<=|>=|==|!=|<|>)\s*|\s+(array-contains-any|array-contains|not-in|in)\s+)(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let fieldRange = Range(match.range(at: 1), in: trimmed),
              let rhsRange = Range(match.range(at: 4), in: trimmed) else {
            throw FirestoreServiceError.invalidQuery(
                "Invalid --where expression '\(expression)'. Expected format: \"<field> <op> <value>\" (e.g. \"age >= 18\" or \"status == active\")."
            )
        }

        let fieldPath = String(trimmed[fieldRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = String(trimmed[rhsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fieldPath.isEmpty, !rawValue.isEmpty else {
            throw FirestoreServiceError.invalidQuery("Filter field and value cannot be empty in '\(expression)'.")
        }

        let opToken: String
        if let symbolRange = Range(match.range(at: 2), in: trimmed) {
            opToken = String(trimmed[symbolRange])
        } else if let wordRange = Range(match.range(at: 3), in: trimmed) {
            opToken = String(trimmed[wordRange]).lowercased()
        } else {
            throw FirestoreServiceError.invalidQuery("Missing comparison operator in '\(expression)'.")
        }

        let op: Operator
        switch opToken {
        case "==": op = .equal
        case "!=": op = .notEqual
        case "<": op = .lessThan
        case "<=": op = .lessThanOrEqual
        case ">": op = .greaterThan
        case ">=": op = .greaterThanOrEqual
        case "array-contains": op = .arrayContains
        case "in": op = .in
        case "not-in": op = .notIn
        case "array-contains-any": op = .arrayContainsAny
        default:
            throw FirestoreServiceError.invalidQuery("Unsupported filter operator '\(opToken)'.")
        }

        let jsonValue = FirestoreJSONValue.parseFragment(rawValue) ?? .string(rawValue)
        if op == .in || op == .notIn || op == .arrayContainsAny {
            guard case .array = jsonValue else {
                throw FirestoreServiceError.invalidQuery(
                    "Operator '\(opToken)' requires a JSON array value (e.g. '\(fieldPath) \(opToken) [\"a\", \"b\"]')."
                )
            }
        }

        return FirestoreQueryFilter(
            fieldPath: fieldPath,
            op: op,
            value: FirestoreValue.fromJSON(jsonValue)
        )
    }
}

/// Structured query sort clause parsed from CLI `--order-by` expressions.
package struct FirestoreOrderBy: Equatable, Sendable {
    package let fieldPath: String
    package let descending: Bool

    package init(fieldPath: String, descending: Bool = false) {
        self.fieldPath = fieldPath
        self.descending = descending
    }

    /// Parses `"field"`, `"field asc"`, or `"field desc"` (case-insensitive).
    package static func parse(_ expression: String) throws -> FirestoreOrderBy {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FirestoreServiceError.invalidQuery("Order-by expression cannot be empty.")
        }

        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        switch parts.count {
        case 1:
            return FirestoreOrderBy(fieldPath: parts[0], descending: false)
        case 2:
            switch parts[1].lowercased() {
            case "asc", "ascending":
                return FirestoreOrderBy(fieldPath: parts[0], descending: false)
            case "desc", "descending":
                return FirestoreOrderBy(fieldPath: parts[0], descending: true)
            default:
                throw FirestoreServiceError.invalidQuery(
                    "Invalid sort direction '\(parts[1])' in '\(expression)'. Use 'asc' or 'desc'."
                )
            }
        default:
            throw FirestoreServiceError.invalidQuery(
                "Invalid --order-by expression '\(expression)'. Expected format: \"<field> [asc|desc]\"."
            )
        }
    }
}

// MARK: - Structured Query Encodable Wire Payloads

private struct RunQueryRequestPayload: Encodable {
    let structuredQuery: StructuredQueryPayload

    struct StructuredQueryPayload: Encodable {
        let from: [CollectionSelectorPayload]
        let `where`: FilterPayload?
        let orderBy: [OrderPayload]?
        let limit: Int?
    }

    struct CollectionSelectorPayload: Encodable {
        let collectionId: String
        let allDescendants: Bool?
    }

    enum FilterPayload: Encodable {
        case field(FieldFilterPayload)
        case composite(CompositeFilterPayload)

        private enum CodingKeys: String, CodingKey {
            case fieldFilter
            case compositeFilter
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .field(let payload):
                try container.encode(payload, forKey: .fieldFilter)
            case .composite(let payload):
                try container.encode(payload, forKey: .compositeFilter)
            }
        }
    }

    struct CompositeFilterPayload: Encodable {
        let op: String
        let filters: [FilterPayload]
    }

    struct FieldFilterPayload: Encodable {
        let field: FieldReferencePayload
        let op: String
        let value: FirestoreValue
    }

    struct FieldReferencePayload: Encodable {
        let fieldPath: String
    }

    struct OrderPayload: Encodable {
        let field: FieldReferencePayload
        let direction: String
    }
}

// MARK: - FirebaseService Firestore Extension

extension FirebaseService {

    // MARK: - Path & Query Helpers

    /// Normalizes a Firestore path by trimming whitespace and leading/trailing slashes.
    package static func normalizeFirestorePath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Returns `true` when the normalized path has a non-empty odd number of segments (collection path).
    package static func isCollectionPath(_ path: String) -> Bool {
        let normalized = normalizeFirestorePath(path)
        guard !normalized.isEmpty else { return false }
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: \.isEmpty) else { return false }
        return segments.count % 2 == 1
    }

    /// Returns `true` when the normalized path has a non-empty even number of segments (document path).
    package static func isDocumentPath(_ path: String) -> Bool {
        let normalized = normalizeFirestorePath(path)
        guard !normalized.isEmpty else { return false }
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: \.isEmpty) else { return false }
        return segments.count % 2 == 0
    }

    /// Serializes a Cloud Firestore `runQuery` JSON payload from typed filters, sort orders, and limit.
    package static func buildStructuredQueryBody(
        collectionId: String,
        filters: [FirestoreQueryFilter] = [],
        orderBy: [FirestoreOrderBy] = [],
        limit: Int? = nil,
        allDescendants: Bool = false
    ) throws -> Data {
        let whereClause: RunQueryRequestPayload.FilterPayload?
        if filters.isEmpty {
            whereClause = nil
        } else if filters.count == 1, let single = filters.first {
            whereClause = .field(.init(
                field: .init(fieldPath: single.fieldPath),
                op: single.op.rawValue,
                value: single.value
            ))
        } else {
            whereClause = .composite(.init(
                op: "AND",
                filters: filters.map { filter in
                    .field(.init(
                        field: .init(fieldPath: filter.fieldPath),
                        op: filter.op.rawValue,
                        value: filter.value
                    ))
                }
            ))
        }

        let orderPayloads: [RunQueryRequestPayload.OrderPayload]? = orderBy.isEmpty ? nil : orderBy.map { clause in
            .init(
                field: .init(fieldPath: clause.fieldPath),
                direction: clause.descending ? "DESCENDING" : "ASCENDING"
            )
        }

        let payload = RunQueryRequestPayload(
            structuredQuery: .init(
                from: [.init(collectionId: collectionId, allDescendants: allDescendants ? true : nil)],
                where: whereClause,
                orderBy: orderPayloads,
                limit: limit
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    // MARK: - Firestore REST API Operations

    /// Lists collection IDs under the Firestore root (`documentPath == nil`) or under a specific document path.
    package func listFirestoreCollections(
        projectId: String,
        databaseId: String = "(default)",
        documentPath: String? = nil,
        pageSize: Int = 100,
        pageToken: String? = nil
    ) async throws -> (collectionIds: [String], nextPageToken: String?) {
        let normalizedDocPath = documentPath.map(Self.normalizeFirestorePath)
        if let normalizedDocPath, !normalizedDocPath.isEmpty, !Self.isDocumentPath(normalizedDocPath) {
            throw FirestoreServiceError.invalidPath(
                "Invalid document path '\(normalizedDocPath)'. A document path must have an even number of segments (e.g. users/user123)."
            )
        }

        let endpoint = try firestoreDocumentsBaseURL(
            projectId: projectId,
            databaseId: databaseId,
            relativePath: normalizedDocPath?.isEmpty == false ? normalizedDocPath : nil,
            suffixAction: ":listCollectionIds"
        )

        struct RequestPayload: Encodable {
            let pageSize: Int
            let pageToken: String?
        }

        struct ResponsePayload: Decodable {
            let collectionIds: [String]?
            let nextPageToken: String?
        }

        let body = try JSONEncoder().encode(
            RequestPayload(
                pageSize: max(1, pageSize),
                pageToken: (pageToken?.isEmpty == false) ? pageToken : nil
            )
        )

        let data = try await sendFirestoreRequest(method: "POST", url: endpoint, body: body)
        let decoded = try JSONDecoder().decode(ResponsePayload.self, from: data)
        return (decoded.collectionIds ?? [], decoded.nextPageToken)
    }

    /// Lists documents in a Firestore collection path.
    package func listFirestoreDocuments(
        projectId: String,
        databaseId: String = "(default)",
        collectionPath: String,
        pageSize: Int = 50,
        pageToken: String? = nil,
        orderBy: String? = nil
    ) async throws -> (documents: [FirestoreDocument], nextPageToken: String?) {
        let normalized = Self.normalizeFirestorePath(collectionPath)
        guard Self.isCollectionPath(normalized) else {
            throw FirestoreServiceError.invalidPath(
                "Invalid collection path '\(collectionPath)'. Expected an odd number of segments (e.g. users or users/u1/orders)."
            )
        }

        var queryItems = [
            URLQueryItem(name: "pageSize", value: String(max(1, pageSize)))
        ]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let orderBy, !orderBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "orderBy", value: orderBy.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        let url = try firestoreDocumentsBaseURL(
            projectId: projectId,
            databaseId: databaseId,
            relativePath: normalized,
            queryItems: queryItems
        )

        struct ListDocumentsResponse: Decodable {
            let documents: [FirestoreDocument]?
            let nextPageToken: String?
        }

        let data = try await sendFirestoreRequest(method: "GET", url: url)
        let decoded = try JSONDecoder().decode(ListDocumentsResponse.self, from: data)
        return (decoded.documents ?? [], decoded.nextPageToken)
    }

    /// Fetches a single Firestore document by path, returning `nil` if the document does not exist (HTTP 404).
    package func getFirestoreDocument(
        projectId: String,
        databaseId: String = "(default)",
        documentPath: String
    ) async throws -> FirestoreDocument? {
        let normalized = Self.normalizeFirestorePath(documentPath)
        guard Self.isDocumentPath(normalized) else {
            throw FirestoreServiceError.invalidPath(
                "Invalid document path '\(documentPath)'. Expected an even number of segments (e.g. users/alice)."
            )
        }

        let url = try firestoreDocumentsBaseURL(
            projectId: projectId,
            databaseId: databaseId,
            relativePath: normalized
        )

        guard let data = try await sendOptionalFirestoreRequest(method: "GET", url: url) else {
            return nil
        }
        return try JSONDecoder().decode(FirestoreDocument.self, from: data)
    }

    /// Writes a document at a document path (`PATCH`, supporting `merge`) or creates one with an auto-ID in a collection path (`POST`).
    package func setFirestoreDocument(
        projectId: String,
        databaseId: String = "(default)",
        path: String,
        fields: [String: FirestoreJSONValue],
        merge: Bool = false
    ) async throws -> FirestoreDocument {
        let normalized = Self.normalizeFirestorePath(path)
        let encodedFields = fields.mapValues { FirestoreValue.fromJSON($0) }

        struct DocumentWritePayload: Encodable {
            let fields: [String: FirestoreValue]
        }

        let body = try JSONEncoder().encode(DocumentWritePayload(fields: encodedFields))

        if Self.isDocumentPath(normalized) {
            var queryItems: [URLQueryItem] = []
            if merge {
                for key in fields.keys.sorted() {
                    queryItems.append(URLQueryItem(name: "updateMask.fieldPaths", value: escapeFieldPathSegment(key)))
                }
            }
            let url = try firestoreDocumentsBaseURL(
                projectId: projectId,
                databaseId: databaseId,
                relativePath: normalized,
                queryItems: queryItems
            )
            let data = try await sendFirestoreRequest(method: "PATCH", url: url, body: body)
            return try JSONDecoder().decode(FirestoreDocument.self, from: data)
        } else if Self.isCollectionPath(normalized) {
            if merge {
                throw FirestoreServiceError.invalidInput(
                    "--merge requires a document path (even number of segments, e.g. users/docId)."
                )
            }
            let url = try firestoreDocumentsBaseURL(
                projectId: projectId,
                databaseId: databaseId,
                relativePath: normalized
            )
            let data = try await sendFirestoreRequest(method: "POST", url: url, body: body)
            return try JSONDecoder().decode(FirestoreDocument.self, from: data)
        } else {
            throw FirestoreServiceError.invalidPath("Firestore path '\(path)' cannot be empty or contain empty segments.")
        }
    }

    /// Deletes a Firestore document at the given document path.
    package func deleteFirestoreDocument(
        projectId: String,
        databaseId: String = "(default)",
        documentPath: String
    ) async throws {
        let normalized = Self.normalizeFirestorePath(documentPath)
        guard Self.isDocumentPath(normalized) else {
            throw FirestoreServiceError.invalidPath(
                "Invalid document path '\(documentPath)'. Expected an even number of segments (e.g. users/alice)."
            )
        }

        let url = try firestoreDocumentsBaseURL(
            projectId: projectId,
            databaseId: databaseId,
            relativePath: normalized
        )
        _ = try await sendFirestoreRequest(method: "DELETE", url: url)
    }

    /// Runs a structured query (`:runQuery`) against a Firestore collection (or collection group with `allDescendants`).
    package func queryFirestoreDocuments(
        projectId: String,
        databaseId: String = "(default)",
        collectionPath: String,
        filters: [FirestoreQueryFilter] = [],
        orderBy: [FirestoreOrderBy] = [],
        limit: Int? = 50,
        allDescendants: Bool = false
    ) async throws -> [FirestoreDocument] {
        let normalized = Self.normalizeFirestorePath(collectionPath)
        guard Self.isCollectionPath(normalized) else {
            throw FirestoreServiceError.invalidPath(
                "Invalid collection path '\(collectionPath)'. Expected an odd number of segments (e.g. users or users/u1/orders)."
            )
        }

        let segments = normalized.split(separator: "/").map(String.init)
        let collectionId = segments.last!
        let parentDocPath = segments.count > 1 ? segments.dropLast().joined(separator: "/") : nil

        let url = try firestoreDocumentsBaseURL(
            projectId: projectId,
            databaseId: databaseId,
            relativePath: parentDocPath,
            suffixAction: ":runQuery"
        )
        let body = try Self.buildStructuredQueryBody(
            collectionId: collectionId,
            filters: filters,
            orderBy: orderBy,
            limit: limit,
            allDescendants: allDescendants
        )

        struct RunQueryResponseItem: Decodable {
            let document: FirestoreDocument?
        }

        let data = try await sendFirestoreRequest(method: "POST", url: url, body: body)
        let items = try JSONDecoder().decode([RunQueryResponseItem].self, from: data)
        return items.compactMap(\.document)
    }

    // MARK: - Internal Transport & Formatting Helpers

    private func firestoreDocumentsBaseURL(
        projectId: String,
        databaseId: String,
        relativePath: String?,
        suffixAction: String? = nil,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let cleanProject = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanProject.isEmpty else {
            throw FirestoreServiceError.invalidInput("Firebase project ID cannot be empty.")
        }
        let cleanDB = databaseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDB.isEmpty else {
            throw FirestoreServiceError.invalidInput("Firestore database ID cannot be empty.")
        }

        var pathParts = [
            "/v1/projects",
            encodePathSegment(cleanProject),
            "databases",
            encodePathSegment(cleanDB),
            "documents",
        ]

        if let relativePath, !relativePath.isEmpty {
            let encodedSegments = relativePath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { encodePathSegment(String($0)) }
            pathParts.append(contentsOf: encodedSegments)
        }

        var fullPath = pathParts.joined(separator: "/")
        if let suffixAction {
            fullPath += suffixAction
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.percentEncodedPath = fullPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw FirestoreServiceError.invalidPath("Failed to construct valid Firestore URL for '\(fullPath)'.")
        }
        return url
    }

    private func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:")
        // Keep `(default)` unencoded in the path while safely encoding special characters in IDs.
        allowed.insert(charactersIn: "()")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    private func escapeFieldPathSegment(_ key: String) -> String {
        let isSimple = !key.isEmpty
            && !(key.first?.isNumber ?? true)
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        if isSimple {
            return key
        }
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        return "`\(escaped)`"
    }

    private func sendFirestoreRequest(
        method: String,
        url: URL,
        body: Data? = nil
    ) async throws -> Data {
        guard let data = try await sendOptionalFirestoreRequest(
            method: method,
            url: url,
            body: body,
            returnNilOnNotFound: false
        ) else {
            throw FirestoreServiceError.invalidResponse("Empty response from Cloud Firestore API.")
        }
        return data
    }

    private func sendOptionalFirestoreRequest(
        method: String,
        url: URL,
        body: Data? = nil,
        returnNilOnNotFound: Bool = true
    ) async throws -> Data? {
        let token = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FirestoreServiceError.invalidResponse("Invalid HTTP response received from Cloud Firestore.")
        }

        if returnNilOnNotFound && httpResponse.statusCode == 404 {
            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw FirestoreServiceError.apiError(
                status: httpResponse.statusCode,
                message: Self.extractGoogleErrorMessage(from: data, statusCode: httpResponse.statusCode)
            )
        }

        return data
    }

    private static func extractGoogleErrorMessage(from data: Data, statusCode: Int) -> String {
        struct GoogleErrorEnvelope: Decodable {
            struct ErrorBody: Decodable {
                let message: String?
                let status: String?
            }
            let error: ErrorBody?
        }

        if let decoded = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data),
           let body = decoded.error {
            let parts = [body.status, body.message].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty {
                return parts.joined(separator: ": ")
            }
        }

        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return "HTTP \(statusCode)"
    }
}
