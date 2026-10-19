import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseDeleteUserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-user",
        abstract: "Deletes Firebase Authentication user(s) by UID, email, or all anonymous users."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "UID (localId) of the user to delete.")
    var uid: String?

    @Option(name: .shortAndLong, help: "Email address of the user to delete.")
    var email: String?

    @Flag(name: .shortAndLong, help: "Delete all anonymous users in the project.")
    var anonymous: Bool = false

    @Flag(name: .shortAndLong, help: "Preview users to be deleted without actually deleting them.")
    var dryRun: Bool = false

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let trimmedUid = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if anonymous && ((trimmedUid?.isEmpty == false) || (trimmedEmail?.isEmpty == false)) {
            Log("Error: ".red.bold + "Cannot combine -a, --anonymous with -u, --uid or -e, --email.")
            throw ExitCode.failure
        }

        guard anonymous || (trimmedUid?.isEmpty == false) || (trimmedEmail?.isEmpty == false) else {
            Log("Error: ".red.bold + "Missing target user. Provide -u, --uid, -e, --email, or -a, --anonymous.")
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

        if anonymous {
            Log("🔍 Scanning for anonymous Firebase Auth users in project [\(project)]...".dim)

            var anonymousUsers: [FirebaseAuthUser] = []
            var pageToken: String? = nil

            repeat {
                let (pageUsers, nextToken) = try await service.listAuthUsers(
                    project: project,
                    maxResults: 1000,
                    pageToken: pageToken
                )
                pageToken = nextToken
                let pageAnon = pageUsers.filter(\.isAnonymous)
                anonymousUsers.append(contentsOf: pageAnon)
            } while pageToken != nil

            guard !anonymousUsers.isEmpty else {
                Log("🟡 No anonymous Firebase Auth users found in project [\(project)].".yellow)
                return
            }

            Log("Found \(anonymousUsers.count) anonymous user(s) in project [\(project)].".bold)

            if dryRun {
                Log("🔍 [Dry Run] The following anonymous user(s) would be deleted:".cyan)
                for user in anonymousUsers.prefix(20) {
                    Log("  • UID: \(user.localId)".dim)
                }
                if anonymousUsers.count > 20 {
                    Log("  • ... and \(anonymousUsers.count - 20) more anonymous user(s).".dim)
                }
                Log("🔍 [Dry Run] No users were deleted.".yellow)
                return
            }

            Log("🗑️  Deleting \(anonymousUsers.count) anonymous user(s) from project [\(project)]...".dim)

            let chunkSize = 500
            var totalDeleted = 0
            var allErrors: [String] = []

            let uids = anonymousUsers.map(\.localId)
            for startIndex in stride(from: 0, to: uids.count, by: chunkSize) {
                let endIndex = min(startIndex + chunkSize, uids.count)
                let chunk = Array(uids[startIndex..<endIndex])
                let errors = try await service.deleteAuthUsers(project: project, uids: chunk, force: true)
                let successCount = chunk.count - errors.count
                totalDeleted += successCount
                allErrors.append(contentsOf: errors)
            }

            if !allErrors.isEmpty {
                for err in allErrors.prefix(10) {
                    Log("⚠️  \(err)".yellow)
                }
                if allErrors.count > 10 {
                    Log("⚠️  ...and \(allErrors.count - 10) more errors.".yellow)
                }
            }

            if totalDeleted > 0 {
                Log("🟢 Successfully deleted \(totalDeleted) anonymous user(s) from project [\(project)].".green.bold)
            }

            if !allErrors.isEmpty {
                throw ExitCode.failure
            }
            return
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

        if dryRun {
            Log("🔍 [Dry Run] Target user '\(targetLabel)' would be deleted from project [\(project)].".yellow)
            return
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
