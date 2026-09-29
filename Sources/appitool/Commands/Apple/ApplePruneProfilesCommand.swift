import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct ApplePruneProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune-profiles",
        abstract: "Deletes all invalid (and optionally expired) provisioning profiles from Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Flag(name: .shortAndLong, help: "Preview profiles to be pruned without deleting them.")
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Also prune expired profiles in addition to INVALID profiles.")
    var includeExpired: Bool = false

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        print("🔍 Inspecting provisioning profiles on Apple Developer Portal...".dim)
        let profiles = try await service.fetchProfiles()

        let now = Date()
        let toPrune = profiles.compactMap { profile in
            let isInvalid = profile.attributes?.profileState == .INVALID
            let isExpired = includeExpired && (profile.attributes?.expirationDate != nil) && (profile.attributes!.expirationDate! < now)

            if isInvalid {
                return (profile: profile, reason: "INVALID")
            } else if isExpired {
                return (profile: profile, reason: "EXPIRED")
            }
            return nil
        }

        if toPrune.isEmpty {
            let scopeMsg = includeExpired ? "invalid or expired" : "invalid"
            print("✓ No \(scopeMsg) provisioning profiles found on Apple Developer Portal. Portal is clean!".green.bold)
            return
        }

        let modePrefix = dryRun ? "[Dry Run] ".yellow.bold : ""
        print("\n\(modePrefix)Found \(toPrune.count) candidate profile(s) for pruning:".bold)

        for (p, reason) in toPrune {
            let nameStr = p.attributes?.name ?? "unnamed"
            let uuidStr = p.attributes?.uuid ?? "-"
            let typeStr = p.attributes?.profileType?.rawValue ?? "UNKNOWN"
            let reasonStr = reason == "INVALID" ? "INVALID".red.bold : "EXPIRED".yellow.bold

            print("  • ".cyan + "\(nameStr)".bold + " [Reason: \(reasonStr), Type: \(typeStr), UUID: \(uuidStr), Portal ID: \(p.id)]".dim)
        }
        print("")

        if dryRun {
            print("ℹ️ Dry run complete. No profiles were modified. Re-run without --dry-run (-d) to delete them.".yellow)
            return
        }

        var deletedCount = 0
        var failedCount = 0

        for (p, _) in toPrune {
            let nameStr = p.attributes?.name ?? "unnamed"
            do {
                let success = try await service.deleteProfile(id: p.id)
                if success {
                    deletedCount += 1
                    print("  ✓ Pruned: ".green + "\(nameStr)".bold)
                } else {
                    failedCount += 1
                    print("  ⚠️ Already deleted: ".yellow + "\(nameStr)")
                }
            } catch {
                failedCount += 1
                print("  ❌ Failed to delete '\(nameStr)': \(error.localizedDescription)".red)
            }
        }

        print("\n✓ Pruning finished: \(deletedCount) profile(s) deleted".green.bold + (failedCount > 0 ? ", \(failedCount) failed/skipped.".yellow : "."))
    }
}
