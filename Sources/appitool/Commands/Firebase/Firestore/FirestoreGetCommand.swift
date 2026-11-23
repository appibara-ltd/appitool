import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirestoreGetCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetches a single Cloud Firestore document by path."
    )

    @OptionGroup
    var firestore: FirestoreOptions

    @Argument(help: "Firestore document path (e.g. users/alice).")
    var path: String

    @Flag(name: .long, help: "Output raw JSON.")
    var json: Bool = false

    func execute() async throws {
        let (service, projectId, databaseId) = try firestore.resolveServiceAndProject()

        if !json {
            Log("🔍 Fetching Firestore document '\(path)' from project [\(projectId)]...".dim)
        }

        guard let document = try await service.getFirestoreDocument(
            projectId: projectId,
            databaseId: databaseId,
            documentPath: path
        ) else {
            throw CommandError("Document '\(path)' was not found in Firestore database '\(databaseId)' (project [\(projectId)]).")
        }

        if json {
            try FirestoreCommandHelpers.printJSON(document.toJSONObject())
            return
        }

        Log("")
        try FirestoreCommandHelpers.logDocument(document)
        Log("")
    }
}
