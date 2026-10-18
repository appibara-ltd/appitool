import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseDeleteUserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-user",
        abstract: "Deletes a Firebase Authentication user by UID or email."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "UID (localId) of the user to delete.")
    var uid: String?

    @Option(name: .shortAndLong, help: "Email address of the user to delete.")
    var email: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let trimmedUid = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedUid?.isEmpty == false) || (trimmedEmail?.isEmpty == false) else {
            Log("Error: ".red.bold + "Missing target user. Provide -u, --uid or -e, --email.")
            throw ExitCode.failure
        }

        guard let service = try projectOptions.makeService() else {
            Log("Error: ".red.bold + "Missing Google credentials (configure GOOGLE_KEY in .env or via -g, --google-key).")
            throw ExitCode.failure
        }

        guard let project = projectOptions.resolveProject() else {
            Log("Error: ".red.bold + "Missing project identifier (configure FIREBASE_PROJECT_ID in .env, or provide -p, --project).")
            throw ExitCode.failure
        }

        let targetUid: String
        let targetLabel: String

        if let u = trimmedUid, !u.isEmpty {
            targetUid = u
            targetLabel = u
        } else if let mail = trimmedEmail, !mail.isEmpty {
            Log("🔍 Looking up Firebase Auth user with email '\(mail)' in project [\(project)]...".dim)
            let matches = try await service.lookupAuthUsers(project: project, emails: [mail])
            guard let matched = matches.first else {
                Log("🟡 User with email '\(mail)' not found in Firebase project [\(project)].".yellow)
                return
            }
            targetUid = matched.localId
            targetLabel = "\(mail) [UID: \(matched.localId)]"
        } else {
            throw ExitCode.failure
        }

        Log("🗑️  Deleting Firebase Auth user '\(targetLabel)' from project [\(project)]...".dim)
        do {
            try await service.deleteAuthUser(project: project, uid: targetUid)
            Log("🟢 Successfully deleted Firebase Auth user '\(targetLabel)'.".green.bold)
        } catch {
            Log("Error: ".red.bold + "Failed to delete user: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
