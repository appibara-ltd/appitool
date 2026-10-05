import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleListProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-profiles",
        abstract: "Lists Provisioning Profiles registered on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by provisioning profile name.")
    var name: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        Log("🔍 Fetching provisioning profiles from Apple Developer Portal...".dim)
        let profiles = try await service.fetchProfiles(limit: limit, name: name)

        if profiles.isEmpty {
            if let filter = name {
                Log("No provisioning profiles matching '\(filter)' found on Apple Developer Portal.".yellow)
            } else {
                Log("No provisioning profiles found on Apple Developer Portal.".yellow)
            }
            return
        }

        Log("\nFound \(profiles.count) provisioning profile(s):".bold)
        for profile in profiles {
            let nameStr = profile.attributes?.name ?? "unnamed"
            let typeStr = profile.attributes?.profileType?.rawValue ?? "UNKNOWN"
            let state = profile.attributes?.profileState
            let stateStr: String
            if state == .ACTIVE {
                stateStr = "ACTIVE".green
            } else if let s = state {
                stateStr = s.rawValue.red
            } else {
                stateStr = "UNKNOWN".yellow
            }
            let uuidStr = profile.attributes?.uuid ?? "-"
            let expirationStr: String
            if let date = profile.attributes?.expirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                expirationStr = formatter.string(from: date)
            } else {
                expirationStr = "-"
            }

            let portalId = profile.id

            Log("  • ".cyan + "\(nameStr)".bold + " [Portal ID: \(portalId), UUID: \(uuidStr), Type: \(typeStr), State: \(stateStr), Expires: \(expirationStr)]".dim)
        }
        Log("")
    }
}
