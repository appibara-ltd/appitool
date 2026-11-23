import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct ApplePruneProfilesCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune-profiles",
        abstract: "Deletes all invalid (and optionally expired) provisioning profiles from Apple Developer Portal."
    )

    var destructiveCommandDescription: String { "apple prune-profiles" }

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Flag(name: .shortAndLong, help: "Preview profiles to be pruned without deleting them.")
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Also prune expired profiles in addition to INVALID profiles.")
    var includeExpired: Bool = false

    func execute() async throws {
        let service = try appleCredentials.requireService()

        Log("🔍 Inspecting provisioning profiles on Apple Developer Portal...".dim)
        let result = try await service.pruneProfiles(includeExpired: includeExpired, dryRun: dryRun)

        if result.candidates.isEmpty {
            let scopeMsg = includeExpired ? "invalid or expired" : "invalid"
            Log("🟢 No \(scopeMsg) provisioning profiles found on Apple Developer Portal. Portal is clean!".green.bold)
            return
        }

        let modePrefix = dryRun ? "[Dry Run] ".yellow.bold : ""
        Log("\n\(modePrefix)Found \(result.candidates.count) candidate profile(s) for pruning:".bold)

        for (p, reason) in result.candidates {
            let nameStr = p.attributes?.name ?? "unnamed"
            let uuidStr = p.attributes?.uuid ?? "-"
            let typeStr = p.attributes?.profileType?.rawValue ?? "UNKNOWN"
            let reasonStr = reason == "INVALID" ? "INVALID".red.bold : "EXPIRED".yellow.bold

            Log("  • ".cyan + "\(nameStr)".bold + " [Reason: \(reasonStr), Type: \(typeStr), UUID: \(uuidStr), Portal ID: \(p.id)]".dim)
        }
        Log("")

        if dryRun {
            Log("🟡️ Dry run complete. No profiles were modified. Re-run without --dry-run (-d) to delete them.".yellow)
            return
        }

        for (p, _) in result.candidates {
            let nameStr = p.attributes?.name ?? "unnamed"
            if let fail = result.failedProfiles.first(where: { $0.name == nameStr }) {
                Log("  🔴 Failed to delete '\(nameStr)': \(fail.error)".red)
            } else {
                Log("  🟢 Pruned: ".green + "\(nameStr)".bold)
            }
        }

        Log("\n🟢 Pruning finished: \(result.deletedCount) profile(s) deleted".green.bold + (result.failedProfiles.count > 0 ? ", \(result.failedProfiles.count) failed/skipped.".yellow : "."))
    }
}
