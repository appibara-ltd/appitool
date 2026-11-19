import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseListGroupsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-groups",
        abstract: "Lists tester groups registered in a Firebase project."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "Maximum number of groups to return (1-1000; defaults to 25).")
    var limit: Int?

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject()

        Log("🔍 Fetching tester groups for Firebase project [\(project)]...".dim)
        let (rawGroups, _) = try await service.listGroups(project: project, pageSize: limit)

        let groups: [FirebaseAppDistributionGroup] = {
            if let limit, limit > 0 {
                return Array(rawGroups.prefix(limit))
            }
            return rawGroups
        }()

        if groups.isEmpty {
            Log("No tester groups found for Firebase project: \(project)".yellow)
            return
        }

        Log("\nFound \(groups.count) tester group(s):".bold)
        for g in groups {
            let display = g.displayName ?? "-"
            let name = g.name ?? "-"
            let alias = name.components(separatedBy: "/").last ?? "-"
            let testers = g.testerCount ?? 0
            let releases = g.releaseCount ?? 0

            Log("  • ".cyan + "\(display)".bold + " [Alias: \(alias)]".green + " (Testers: \(testers), Releases: \(releases))".dim)
        }
        Log("")
    }
}
