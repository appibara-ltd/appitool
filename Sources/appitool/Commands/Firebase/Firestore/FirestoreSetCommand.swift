import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirestoreSetCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Creates or updates a Cloud Firestore document (or creates with an auto-ID when given a collection path)."
    )

    @OptionGroup
    var firestore: FirestoreOptions

    @Argument(help: "Firestore document path (e.g. users/alice) or collection path to auto-generate an ID (e.g. users).")
    var path: String

    @Option(name: .shortAndLong, help: "JSON object string with document fields (e.g. '{\"role\":\"admin\",\"active\":true}').")
    var data: String?

    @Option(name: .shortAndLong, help: "Path to a JSON file containing document fields.")
    var file: String?

    @Flag(name: .shortAndLong, help: "Merge provided top-level fields into an existing document instead of overwriting all fields.")
    var merge: Bool = false

    @Flag(name: .long, help: "Output raw JSON.")
    var json: Bool = false

    func execute() async throws {
        let inlineData = FirestoreCommandHelpers.trimmedNonEmpty(data)
        let filePathRaw = FirestoreCommandHelpers.trimmedNonEmpty(file)

        if (inlineData != nil) == (filePathRaw != nil) {
            throw CommandError("Provide exactly one of -d, --data <json> or -f, --file <path>.")
        }

        let payloadData: Data
        if let inlineData {
            payloadData = Data(inlineData.utf8)
        } else if var resolvedPath = filePathRaw {
            if resolvedPath.hasPrefix("~/") || resolvedPath.hasPrefix("~\\") {
                let subpath = String(resolvedPath.dropFirst(2))
                resolvedPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(subpath).path
            }
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                throw CommandError("JSON file not found at '\(resolvedPath)'.")
            }
            payloadData = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
        } else {
            throw CommandError("Provide -d, --data <json> or -f, --file <path>.")
        }

        let fields: [String: FirestoreJSONValue]
        do {
            fields = try JSONDecoder().decode([String: FirestoreJSONValue].self, from: payloadData)
        } catch {
            throw CommandError("Invalid document JSON payload: expected a JSON object of field keys and values (\(error.localizedDescription)).")
        }

        let (service, projectId, databaseId) = try firestore.resolveServiceAndProject()

        if !json {
            Log("✍️  Writing Firestore document at '\(path)' in project [\(projectId)]...".dim)
        }

        let document = try await service.setFirestoreDocument(
            projectId: projectId,
            databaseId: databaseId,
            path: path,
            fields: fields,
            merge: merge
        )

        if json {
            try FirestoreCommandHelpers.printJSON(document.toJSONObject())
            return
        }

        Log("\n🟢 Document saved successfully!".green.bold)
        try FirestoreCommandHelpers.logDocument(document)
        Log("")
    }
}
