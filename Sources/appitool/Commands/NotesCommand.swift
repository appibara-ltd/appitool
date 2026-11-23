import ArgumentParser
import Foundation
import Rainbow

struct NotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Generates formatted release notes from git commits between two tags or revisions."
    )

    @Option(name: .long, help: "Starting tag or revision (e.g., v1.0.0).")
    var from: String?

    @Option(name: .long, help: "Ending tag or revision (defaults to HEAD if --from is given).")
    var to: String?

    @Option(name: .shortAndLong, help: "Path to write the generated markdown file.")
    var output: String?

    @Option(name: .long, help: "Filter auto-detected tags by prefix (e.g., v, ios-v, android-).")
    var tagPrefix: String?

    func run() async throws {
        let task = GenerateReleaseNotesTask()
        let result = try await task.run(
            .init(
                from: from,
                to: to,
                outputPath: output,
                tagPrefix: tagPrefix
            )
        )
        let markdown = result.notes

        if markdown.isEmpty {
            Log("ℹ️ No commits found for the specified range.".yellow)
            return
        }

        if let output {
            let fullPath = output.hasPrefix("/") ? output : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(output).path
            Log("📝 Release notes saved to: \(fullPath)".green.bold)
        } else {
            Log(markdown)
        }
    }
}
