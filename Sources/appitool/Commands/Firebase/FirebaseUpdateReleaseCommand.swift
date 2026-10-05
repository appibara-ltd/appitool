import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseUpdateReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-release",
        abstract: "Updates an existing release (attaches release notes or distributes to tester groups/emails)."
    )

    @OptionGroup
    var credentials: FirebaseCredentialsOptions

    @Option(name: .long, help: "Full release resource id (release ID).")
    var releaseId: String

    @Option(name: .long, help: "New release notes text to attach to the release.")
    var releaseNotes: String?

    @Option(name: .long, help: "Comma-separated tester group aliases to distribute to.")
    var testGroups: String?

    @Option(name: .long, help: "Comma-separated tester emails to distribute to.")
    var testerEmails: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try credentials.makeService() else {
            Log("Error: ".red.bold + "Missing Google credentials (configure GOOGLE_KEY in .env or via --google-key).")
            return
        }

        // Resolve full release resource name if only release ID was provided
        let resolvedReleaseName: String
        if releaseId.hasPrefix("projects/") {
            resolvedReleaseName = releaseId
        } else {
            guard let appId = credentials.resolveAppId() else {
                Log("Error: ".red.bold + "When specifying a release ID without full resource name, Firebase App ID is required (--firebase-app-id).")
                return
            }
            let segments = appId.split(separator: ":")
            let projectNumber = segments.count >= 2 ? String(segments[1]) : "-"
            resolvedReleaseName = "projects/\(projectNumber)/apps/\(appId)/releases/\(releaseId)"
        }

        var anyUpdated = false

        // 1. Update release notes if provided
        if let notes = releaseNotes {
            Log("📝 Updating release notes for [\(resolvedReleaseName)]...".dim)
            try await service.addReleaseNotes(releaseName: resolvedReleaseName, releaseNotes: notes)
            Log("✓ Release notes updated successfully.".green)
            anyUpdated = true
        }

        // 2. Distribute to tester groups or emails if provided
        let parsedGroups = testGroups?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parsedEmails = testerEmails?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        if (parsedGroups != nil && !parsedGroups!.isEmpty) || (parsedEmails != nil && !parsedEmails!.isEmpty) {
            let groupsDesc = parsedGroups?.joined(separator: ", ") ?? "none"
            let emailsDesc = parsedEmails?.joined(separator: ", ") ?? "none"
            Log("👥 Distributing [\(resolvedReleaseName)] to groups: [\(groupsDesc)], emails: [\(emailsDesc)]...".dim)

            try await service.distribute(
                releaseName: resolvedReleaseName,
                groupAliases: parsedGroups,
                testerEmails: parsedEmails
            )
            Log("✓ Release distributed successfully.".green)
            anyUpdated = true
        }

        if !anyUpdated {
            Log("⚠️  No updates specified. Use -r, --release-notes, -t, --test-groups, or -e, --tester-emails.".yellow)
        }
    }
}
