import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseCreateGroupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-group",
        abstract: "Creates a new tester group (or retrieves existing if already present)."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "Unique alias/ID for the group (e.g. 'internal', 'qa-team').")
    var alias: String

    @Option(name: .shortAndLong, help: "Human-readable display name for the group (e.g. 'Internal Testers').")
    var name: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try projectOptions.makeService() else {
            Log("Error: ".red.bold + "Missing Google credentials (configure GOOGLE_KEY in .env or via --google-key).")
            return
        }

        guard let project = projectOptions.resolveProject() else {
            Log("Error: ".red.bold + "Missing project identifier (configure FIREBASE_PROJECT_ID in .env, or provide -p, --project).")
            return
        }

        let displayName = name ?? alias
        Log("👥 Creating or getting tester group '\(displayName)' (alias: \(alias)) in project [\(project)]...".dim)

        let group = try await service.createOrGetGroup(
            project: project,
            groupAlias: alias,
            displayName: displayName
        )

        let resolvedName = group.name ?? "-"
        let resolvedAlias = resolvedName.components(separatedBy: "/").last ?? alias
        Log("🟢 Tester group ready: ".green.bold + "\(group.displayName ?? displayName)".bold + " [Alias: \(resolvedAlias), Name: \(resolvedName)]".dim)
    }
}
