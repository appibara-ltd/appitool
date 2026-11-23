import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirestoreCollectionsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "collections",
        abstract: "Lists root collection IDs or subcollection IDs under a Cloud Firestore document."
    )

    @OptionGroup
    var firestore: FirestoreOptions

    @Argument(help: "Optional parent document path to list subcollections under (e.g. users/alice).")
    var path: String?

    @Option(name: .shortAndLong, help: "Maximum number of collection IDs to return (defaults to 100).")
    var limit: Int = 100

    @Option(name: [.customShort("t"), .long], help: "Pagination token to fetch the next page of collection IDs.")
    var pageToken: String?

    @Flag(name: .long, help: "Output raw JSON.")
    var json: Bool = false

    func execute() async throws {
        let (service, projectId, databaseId) = try firestore.resolveServiceAndProject()
        let parentPath = FirestoreCommandHelpers.trimmedNonEmpty(path)

        if !json {
            let scope = parentPath.map { "document '\($0)'" } ?? "database '\(databaseId)' root"
            Log("🔍 Fetching Firestore collections at \(scope) in project [\(projectId)]...".dim)
        }

        let (collectionIds, nextPageToken) = try await service.listFirestoreCollections(
            projectId: projectId,
            databaseId: databaseId,
            documentPath: parentPath,
            pageSize: max(1, limit),
            pageToken: FirestoreCommandHelpers.trimmedNonEmpty(pageToken)
        )

        if json {
            var payload: [String: FirestoreJSONValue] = [
                "collectionIds": .array(collectionIds.map { .string($0) }),
            ]
            if let nextPageToken, !nextPageToken.isEmpty {
                payload["nextPageToken"] = .string(nextPageToken)
            }
            try FirestoreCommandHelpers.printJSON(.object(payload))
            return
        }

        if collectionIds.isEmpty {
            Log("No Firestore collections found.".yellow)
            return
        }

        Log("\nFound \(collectionIds.count) collection(s):".bold)
        for id in collectionIds {
            Log("  • ".cyan + id.bold)
        }

        if let nextPageToken, !nextPageToken.isEmpty {
            Log("\n⏭️  Next Page Token: ".dim + nextPageToken.yellow)
        }
        Log("")
    }
}
