import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Root subcommand for Cloud Firestore collection inspection, document CRUD, and structured queries.
struct FirebaseFirestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firestore",
        abstract: "Inspects, queries, writes, and deletes Cloud Firestore collections and documents.",
        subcommands: [
            FirestoreCollectionsCommand.self,
            FirestoreListCommand.self,
            FirestoreGetCommand.self,
            FirestoreSetCommand.self,
            FirestoreDeleteCommand.self,
            FirestoreQueryCommand.self,
        ]
    )
}

/// Shared CLI options and helper formatting utilities for Cloud Firestore subcommands.
struct FirestoreOptions: ParsableArguments, Sendable {
    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .long, help: "Cloud Firestore database ID (defaults to '(default)').")
    var database: String = "(default)"

    func resolveServiceAndProject() throws -> (service: FirebaseService, projectId: String, databaseId: String) {
        let service = try projectOptions.requireService()
        let projectId = try projectOptions.requireProjectId(fallbackServiceProjectId: service.serviceAccountProjectId)
        let dbId = database.trimmingCharacters(in: .whitespacesAndNewlines)
        return (service, projectId, dbId.isEmpty ? "(default)" : dbId)
    }
}

enum FirestoreCommandHelpers {
    static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func printJSON(_ value: FirestoreJSONValue) throws {
        print(try value.prettyJSONString())
    }

    static func logDocument(_ document: FirestoreDocument) throws {
        let pathLabel = document.relativePath.isEmpty ? document.documentId : document.relativePath
        Log("  • ".cyan + "\(pathLabel)".bold)
        if let createTime = document.createTime {
            Log("    Created: ".dim + createTime)
        }
        if let updateTime = document.updateTime {
            Log("    Updated: ".dim + updateTime)
        }
        let jsonFields = try FirestoreJSONValue.object(document.plainFields).prettyJSONString()
        for line in jsonFields.components(separatedBy: .newlines) {
            Log("    \(line)")
        }
    }
}
