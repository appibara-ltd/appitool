import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseListUsersCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-users",
        abstract: "Lists Firebase Authentication users with optional search and anonymous filtering."
    )

    enum AnonymousFilter: String, ExpressibleByArgument, CaseIterable, Sendable {
        case all
        case only
        case exclude
    }

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "Maximum number of users to return (defaults to 100).")
    var limit: Int = 100

    @Option(name: .long, help: "Search users by email or UID.")
    var search: String?

    @Option(name: .long, help: "Filter by anonymous status (all, only, exclude; defaults to all).")
    var anonymous: AnonymousFilter = .all

    @Option(name: .long, help: "Pagination token to fetch the next page of users.")
    var pageToken: String?

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject()

        let targetLimit = max(1, limit)
        let searchQuery = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = (searchQuery?.isEmpty == false)

        Log("🔍 Fetching Firebase Auth users for project [\(project)]...".dim)

        var matchedUsers: [FirebaseAuthUser] = []
        var currentToken: String? = pageToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentToken?.isEmpty == true {
            currentToken = nil
        }

        // 1. Fast path: If search query is provided on the first page, try exact lookup first
        if currentToken == nil, let query = searchQuery, !query.isEmpty {
            let exactMatches: [FirebaseAuthUser]
            if query.contains("@") {
                exactMatches = (try? await service.lookupAuthUsers(project: project, emails: [query])) ?? []
            } else {
                exactMatches = (try? await service.lookupAuthUsers(project: project, uids: [query])) ?? []
            }

            let filteredExact = exactMatches.filter { matchesFilters($0, searchQuery: query) }
            if !filteredExact.isEmpty {
                matchedUsers.append(contentsOf: filteredExact)
            }
        }

        // 2. Paginate through batchGet if we need more results (or for partial search / listing)
        if matchedUsers.count < targetLimit {
            let pageSize = hasSearch || anonymous != .all ? 500 : min(targetLimit, 500)

            repeat {
                let (pageUsers, nextToken) = try await service.listAuthUsers(
                    project: project,
                    maxResults: pageSize,
                    pageToken: currentToken
                )

                currentToken = nextToken

                for user in pageUsers {
                    if matchedUsers.contains(where: { $0.localId == user.localId }) {
                        continue
                    }
                    if matchesFilters(user, searchQuery: searchQuery) {
                        matchedUsers.append(user)
                        if matchedUsers.count >= targetLimit {
                            break
                        }
                    }
                }
            } while currentToken != nil && matchedUsers.count < targetLimit
        }

        if matchedUsers.isEmpty {
            Log("No matching Firebase Auth users found for project: \(project)".yellow)
            return
        }

        Log("\nFound \(matchedUsers.count) user(s):".bold)
        for user in matchedUsers {
            let uid = user.localId
            let identity: String
            if user.isAnonymous {
                identity = "Anonymous".yellow
            } else if let email = user.email, !email.isEmpty {
                let verifiedBadge = (user.emailVerified == true) ? "✓".green : "unverified".dim
                identity = "\(email.bold) (\(verifiedBadge))"
            } else if let phone = user.phoneNumber, !phone.isEmpty {
                identity = phone.bold
            } else {
                identity = (user.displayName ?? "User").bold
            }

            let displayPart = (user.displayName?.isEmpty == false) ? " - \(user.displayName!)" : ""
            let providers = user.providerUserInfo?.compactMap(\.providerId).joined(separator: ", ") ?? ""
            let providerPart = !providers.isEmpty ? " [Providers: \(providers)]".cyan : ""
            let statusPart = (user.disabled == true) ? " [DISABLED]".red.bold : ""
            let createdPart = formatEpochMillis(user.createdAt).map { " (Created: \($0))".dim } ?? ""

            Log("  • ".cyan + "\(identity)\(displayPart)" + " [UID: \(uid)]".green + providerPart + statusPart + createdPart)
        }

        if let nextToken = currentToken, !nextToken.isEmpty {
            Log("\n⏭️  Next Page Token: ".dim + "\(nextToken)".yellow)
            Log("   Fetch next page with: ".dim + "appitool firebase list-users -l \(targetLimit) -t \"\(nextToken)\"".cyan)
        }
        Log("")
    }

    private func matchesFilters(_ user: FirebaseAuthUser, searchQuery: String?) -> Bool {
        switch anonymous {
        case .all:
            break
        case .only:
            if !user.isAnonymous { return false }
        case .exclude:
            if user.isAnonymous { return false }
        }

        if let query = searchQuery?.lowercased(), !query.isEmpty {
            let uidMatch = user.localId.lowercased().contains(query)
            let emailMatch = user.email?.lowercased().contains(query) == true
            let providerEmailMatch = user.providerUserInfo?.contains(where: { $0.email?.lowercased().contains(query) == true }) == true
            if !uidMatch && !emailMatch && !providerEmailMatch {
                return false
            }
        }

        return true
    }

    private func formatEpochMillis(_ raw: String?) -> String? {
        guard let raw, let ms = Double(raw) else { return nil }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
