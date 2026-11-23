import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirestoreQueryCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Runs a structured query against a Cloud Firestore collection."
    )

    @OptionGroup
    var firestore: FirestoreOptions

    @Argument(help: "Firestore collection path to query (e.g. users or users/alice/orders).")
    var path: String

    @Option(name: [.customShort("w"), .customLong("where")], help: "Filter expression (repeatable), e.g. -w 'status == active' -w 'age >= 18'.")
    var filters: [String] = []

    @Option(name: .shortAndLong, help: "Sort clause (repeatable), e.g. -o 'createdAt desc'.")
    var orderBy: [String] = []

    @Option(name: .shortAndLong, help: "Maximum number of documents to return (defaults to 50).")
    var limit: Int = 50

    @Flag(name: .long, help: "Query across all descendant collections matching the collection ID (collection group query).")
    var allDescendants: Bool = false

    @Flag(name: .long, help: "Output raw JSON.")
    var json: Bool = false

    func execute() async throws {
        let parsedFilters = try filters.map { try FirestoreQueryFilter.parse($0) }
        let parsedOrders = try orderBy.map { try FirestoreOrderBy.parse($0) }
        let (service, projectId, databaseId) = try firestore.resolveServiceAndProject()

        if !json {
            Log("🔍 Querying Firestore collection '\(path)' in project [\(projectId)]...".dim)
        }

        let documents = try await service.queryFirestoreDocuments(
            projectId: projectId,
            databaseId: databaseId,
            collectionPath: path,
            filters: parsedFilters,
            orderBy: parsedOrders,
            limit: max(1, limit),
            allDescendants: allDescendants
        )

        if json {
            let payload: [String: FirestoreJSONValue] = [
                "documents": .array(documents.map { $0.toJSONObject() }),
            ]
            try FirestoreCommandHelpers.printJSON(.object(payload))
            return
        }

        if documents.isEmpty {
            Log("No documents matched the query in '\(path)'.".yellow)
            return
        }

        Log("\nMatched \(documents.count) document(s):".bold)
        for doc in documents {
            try FirestoreCommandHelpers.logDocument(doc)
        }
        Log("")
    }
}
