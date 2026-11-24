import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Credentials plus the Play Console account ID used by the `google` user commands.
struct GooglePlayAccountOptions: ParsableArguments, Sendable {
    @OptionGroup
    var googleCredentials: GoogleCredentialsOptions

    @Option(name: .long, help: "Play Console account ID (the number in play.google.com/console/developers/<id>; defaults to GOOGLE_PLAY_ACCOUNT_ID in .env).")
    var accountId: String?

    func requireAccountId() throws -> String {
        guard let id = CLIValues.trimmedNonEmpty(accountId) ?? EnvLoader.value(for: "GOOGLE_PLAY_ACCOUNT_ID") else {
            throw ValidationError(
                "Missing Play Console account ID. Provide --account-id or set GOOGLE_PLAY_ACCOUNT_ID in .env (the number in play.google.com/console/developers/<id>)."
            )
        }
        return id
    }

    func requireService() throws -> GooglePlayService {
        try googleCredentials.requireService()
    }
}

enum GoogleUserSupport {
    /// Parses comma-separated permissions (`can-reply-to-reviews`, `CAN_SEE_ALL_APPS`, …).
    static func permissions(_ raw: String?, developerLevel: Bool) throws -> [String]? {
        guard let raw = CLIValues.commaSeparatedOrNil(raw) else { return nil }
        do {
            return try GooglePlayPermissions.parse(raw, developerLevel: developerLevel)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    /// Validates an ISO 8601 expiration and returns it as an RFC 3339 UTC timestamp.
    static func expiration(_ raw: String?) throws -> String? {
        guard let raw = CLIValues.trimmedNonEmpty(raw) else { return nil }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: raw) else {
            throw ValidationError("--expiration must be ISO 8601 (e.g. 2027-01-01T00:00:00Z).")
        }
        guard date > Date() else {
            throw ValidationError("--expiration must be in the future.")
        }
        return parser.string(from: date)
    }

    static func findUser(_ users: [GooglePlayUser], email: String) -> GooglePlayUser? {
        users.first { $0.email?.caseInsensitiveCompare(email) == .orderedSame }
    }

    static func displayPermission(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Prints one user with state, developer-level permissions, expiration, and per-app grants.
    static func log(_ user: GooglePlayUser) {
        Log("  • ".cyan + "\(user.email ?? "-")".bold + " [\(user.accessState ?? "-")]".dim)
        let permissions = (user.developerAccountPermissions ?? []).map(displayPermission)
        Log("    Account permissions: ".dim + (permissions.isEmpty ? "-" : permissions.joined(separator: ", ")))
        if let expiration = user.expirationTime {
            Log("    Expires: ".dim + expiration)
        }
        for grant in user.grants ?? [] {
            let appPermissions = (grant.appLevelPermissions ?? []).map(displayPermission).joined(separator: ", ")
            Log("    App \(grant.packageName ?? grant.name ?? "-"): ".dim + (appPermissions.isEmpty ? "-" : appPermissions))
        }
    }

    /// Explains common Play Developer API errors for user management.
    static func hint(for error: Error) -> String? {
        guard case GooglePlayImageError.apiError(let status, _) = error else { return nil }
        switch status {
        case 401, 403:
            return "The service account needs the 'Manage users and permissions' (admin) permission in Play Console, and --account-id / GOOGLE_PLAY_ACCOUNT_ID must be your Play Console account ID."
        case 404:
            return "Check --account-id / GOOGLE_PLAY_ACCOUNT_ID and the email address."
        case 409:
            return "The user or grant already exists; use users update or users grant to change it."
        default:
            return nil
        }
    }

    /// Runs a Play Developer API call and turns failures into explanatory command errors.
    static func run<T>(_ action: String, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as GooglePlayImageError {
            throw CommandError("Failed to \(action): \(error.localizedDescription)", hint: hint(for: error))
        }
    }
}
