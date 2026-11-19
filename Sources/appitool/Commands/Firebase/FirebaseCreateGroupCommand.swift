import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseCreateGroupCommand: BaseCommand {
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

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject()

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
