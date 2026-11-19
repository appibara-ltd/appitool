import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseExportUsersCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-users",
        abstract: "Exports all Firebase Authentication users to a CSV file in the current directory."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .shortAndLong, help: "Filter by anonymous status (all, only, exclude; defaults to all).")
    var anonymous: FirebaseListUsersCommand.AnonymousFilter = .all

    @Option(name: .shortAndLong, help: "Output CSV filename or path (defaults to firebase_users_<project>.csv in the current directory).")
    var output: String?

    func execute() async throws {
        let service = try projectOptions.requireService()
        let project = try projectOptions.requireProject()

        Log("🔍 Fetching all Firebase Auth users for project [\(project)]...".dim)

        var allUsers: [FirebaseAuthUser] = []
        var pageToken: String? = nil

        repeat {
            let (pageUsers, nextToken) = try await service.listAuthUsers(
                project: project,
                maxResults: 1000,
                pageToken: pageToken
            )

            for user in pageUsers {
                switch anonymous {
                case .all:
                    allUsers.append(user)
                case .only:
                    if user.isAnonymous { allUsers.append(user) }
                case .exclude:
                    if !user.isAnonymous { allUsers.append(user) }
                }
            }

            pageToken = nextToken
        } while pageToken != nil

        let fm = FileManager.default
        let resolvedOutputPath: String
        if let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: output).expandingTildeInPath
            if expanded.hasPrefix("/") {
                resolvedOutputPath = expanded
            } else {
                resolvedOutputPath = URL(fileURLWithPath: fm.currentDirectoryPath)
                    .appendingPathComponent(expanded)
                    .path
            }
        } else {
            let safeProject = project.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            resolvedOutputPath = URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("firebase_users_\(safeProject).csv")
                .path
        }

        var csvLines: [String] = []
        csvLines.append("uid,email,email_verified,display_name,phone_number,photo_url,is_anonymous,disabled,providers,created_at,last_login_at")

        for user in allUsers {
            let providers = user.providerUserInfo?.compactMap(\.providerId).joined(separator: ";") ?? ""
            let createdIso = formatIsoDate(user.createdAt) ?? ""
            let lastLoginIso = formatIsoDate(user.lastLoginAt) ?? ""

            let row: [String] = [
                escapeCSV(user.localId),
                escapeCSV(user.email ?? ""),
                escapeCSV(user.emailVerified.map { $0 ? "true" : "false" } ?? ""),
                escapeCSV(user.displayName ?? ""),
                escapeCSV(user.phoneNumber ?? ""),
                escapeCSV(user.photoUrl ?? ""),
                escapeCSV(user.isAnonymous ? "true" : "false"),
                escapeCSV(user.disabled == true ? "true" : "false"),
                escapeCSV(providers),
                escapeCSV(createdIso),
                escapeCSV(lastLoginIso),
            ]
            csvLines.append(row.joined(separator: ","))
        }

        let csvContent = csvLines.joined(separator: "\n") + "\n"
        let outputUrl = URL(fileURLWithPath: resolvedOutputPath)
        try csvContent.write(to: outputUrl, atomically: true, encoding: .utf8)

        Log("🟢 Exported \(allUsers.count) user(s) to: ".green.bold + "\(outputUrl.path)".cyan)
    }

    private func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    private func formatIsoDate(_ rawMillis: String?) -> String? {
        guard let rawMillis, let ms = Double(rawMillis) else { return nil }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
