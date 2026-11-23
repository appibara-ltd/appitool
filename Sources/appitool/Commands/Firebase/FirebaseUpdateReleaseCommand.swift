import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseUpdateReleaseCommand: BaseCommand {
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

    func execute() async throws {
        let service = try credentials.requireService()

        // Resolve full release resource name if only release ID was provided
        let resolvedReleaseName: String
        if releaseId.hasPrefix("projects/") {
            resolvedReleaseName = releaseId
        } else {
            guard let appId = credentials.resolveAppId() else {
                throw CommandError("When specifying a release ID without full resource name, Firebase App ID is required (--firebase-app-id).")
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
            Log("🟢 Release notes updated successfully.".green)
            anyUpdated = true
        }

        // 2. Distribute to tester groups or emails if provided
        let parsedGroups = CLIValues.commaSeparatedOrNil(testGroups)
        let parsedEmails = CLIValues.commaSeparatedOrNil(testerEmails)

        if (parsedGroups != nil && !parsedGroups!.isEmpty) || (parsedEmails != nil && !parsedEmails!.isEmpty) {
            let groupsDesc = parsedGroups?.joined(separator: ", ") ?? "none"
            let emailsDesc = parsedEmails?.joined(separator: ", ") ?? "none"
            Log("👥 Distributing [\(resolvedReleaseName)] to groups: [\(groupsDesc)], emails: [\(emailsDesc)]...".dim)

            try await service.distribute(
                releaseName: resolvedReleaseName,
                groupAliases: parsedGroups,
                testerEmails: parsedEmails
            )
            Log("🟢 Release distributed successfully.".green)
            anyUpdated = true
        }

        if !anyUpdated {
            Log("🚧 No updates specified. Use --release-notes, --test-groups, or --tester-emails.".yellow)
        }
    }
}
