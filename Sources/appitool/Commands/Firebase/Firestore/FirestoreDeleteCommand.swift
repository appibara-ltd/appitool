import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirestoreDeleteCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Deletes a Cloud Firestore document by path."
    )

    @OptionGroup
    var firestore: FirestoreOptions

    @Argument(help: "Firestore document path to delete (e.g. users/alice).")
    var path: String

    @Flag(name: .shortAndLong, help: "Check whether the document exists without deleting it.")
    var dryRun: Bool = false

    func execute() async throws {
        let (service, projectId, databaseId) = try firestore.resolveServiceAndProject()
        let normalized = FirebaseService.normalizeFirestorePath(path)

        guard FirebaseService.isDocumentPath(normalized) else {
            throw FirestoreServiceError.invalidPath(
                "Invalid document path '\(path)'. Expected an even number of segments (e.g. users/alice)."
            )
        }

        if dryRun {
            Log("🔍 [Dry Run] Checking Firestore document '\(normalized)' in project [\(projectId)]...".dim)
            if let existing = try await service.getFirestoreDocument(
                projectId: projectId,
                databaseId: databaseId,
                documentPath: normalized
            ) {
                let targetPath = existing.relativePath.isEmpty ? normalized : existing.relativePath
                Log("🔍 [Dry Run] Document '\(targetPath)' exists and would be deleted.".yellow)
            } else {
                Log("🟡 Document '\(normalized)' does not exist in Firestore database '\(databaseId)'.".yellow)
            }
            return
        }

        Log("🗑️  Deleting Firestore document '\(normalized)' in project [\(projectId)]...".dim)
        try await service.deleteFirestoreDocument(
            projectId: projectId,
            databaseId: databaseId,
            documentPath: normalized
        )
        Log("🟢 Successfully deleted Firestore document '\(normalized)'.".green.bold)
    }
}
