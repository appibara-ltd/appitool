import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirestoreListCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Lists documents in a Cloud Firestore collection."
    )

    @OptionGroup
    var firestore: FirestoreOptions

    @Argument(help: "Firestore collection path (e.g. users or users/alice/orders).")
    var path: String

    @Option(name: .shortAndLong, help: "Maximum number of documents to return (defaults to 50).")
    var limit: Int = 50

    @Option(name: .long, help: "Sort order expression (e.g. 'createdAt desc').")
    var orderBy: String?

    @Option(name: .long, help: "Pagination token to fetch the next page of documents.")
    var pageToken: String?

    @Flag(name: .long, help: "Output raw JSON.")
    var json: Bool = false

    func execute() async throws {
        let (service, projectId, databaseId) = try firestore.resolveServiceAndProject()

        if !json {
            Log("🔍 Listing Firestore documents in '\(path)' for project [\(projectId)]...".dim)
        }

        let (documents, nextPageToken) = try await service.listFirestoreDocuments(
            projectId: projectId,
            databaseId: databaseId,
            collectionPath: path,
            pageSize: max(1, limit),
            pageToken: CLIValues.trimmedNonEmpty(pageToken),
            orderBy: CLIValues.trimmedNonEmpty(orderBy)
        )

        if json {
            var payload: [String: FirestoreJSONValue] = [
                "documents": .array(documents.map { $0.toJSONObject() }),
            ]
            if let nextPageToken, !nextPageToken.isEmpty {
                payload["nextPageToken"] = .string(nextPageToken)
            }
            try FirestoreCommandHelpers.printJSON(.object(payload))
            return
        }

        if documents.isEmpty {
            Log("No documents found in collection '\(path)'.".yellow)
            return
        }

        Log("\nFound \(documents.count) document(s):".bold)
        for doc in documents {
            try FirestoreCommandHelpers.logDocument(doc)
        }

        if let nextPageToken, !nextPageToken.isEmpty {
            Log("\n⏭️  Next Page Token: ".dim + nextPageToken.yellow)
        }
        Log("")
    }
}
