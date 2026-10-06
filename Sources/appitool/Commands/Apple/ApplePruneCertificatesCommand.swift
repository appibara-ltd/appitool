import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct ApplePruneCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune-certificates",
        abstract: "Deletes (revokes) all expired certificates from Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Flag(name: .shortAndLong, help: "Preview certificates to be pruned without deleting them.")
    var dryRun: Bool = false

    @Option(name: .shortAndLong, help: "Filter pruning by certificate type (e.g. distribution, development).")
    var type: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        Log("🔍 Inspecting certificates on Apple Developer Portal...".dim)
        let result = try await service.pruneCertificates(typeFilter: type, dryRun: dryRun)

        if result.candidates.isEmpty {
            let filterDesc = type.map { " (\($0))" } ?? ""
            Log("🟢 No expired certificates\(filterDesc) found on Apple Developer Portal. Portal is clean!".green.bold)
            return
        }

        let modePrefix = dryRun ? "[Dry Run] ".yellow.bold : ""
        Log("\n\(modePrefix)Found \(result.candidates.count) expired certificate(s) for pruning:".bold)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        for cert in result.candidates {
            let nameStr = cert.attributes?.name ?? "unnamed"
            let typeStr = cert.attributes?.certificateType?.rawValue ?? "UNKNOWN"
            let serialStr = cert.attributes?.serialNumber ?? "-"
            let expirationStr = cert.attributes?.expirationDate.map { formatter.string(from: $0) } ?? "-"

            Log("  • ".cyan + "\(nameStr)".bold + " [Reason: " + "EXPIRED".red.bold + ", Type: \(typeStr), Serial: \(serialStr), Expires: \(expirationStr), Portal ID: \(cert.id)]".dim)
        }
        Log("")

        if dryRun {
            Log("🟡️ Dry run complete. No certificates were modified. Re-run without --dry-run (-d) to delete them.".yellow)
            return
        }

        for cert in result.candidates {
            let nameStr = cert.attributes?.name ?? "unnamed"
            if let fail = result.failedCertificates.first(where: { $0.name == nameStr }) {
                Log("  🔴 Failed to delete '\(nameStr)': \(fail.error)".red)
            } else {
                Log("  🟢 Pruned: ".green + "\(nameStr)".bold)
            }
        }

        Log("\n🟢 Pruning finished: \(result.deletedCount) certificate(s) deleted".green.bold + (result.failedCertificates.count > 0 ? ", \(result.failedCertificates.count) failed/skipped.".yellow : "."))
        if result.deletedCount > 0 {
            Log("🟡️ Note: Any provisioning profiles that were tied to these pruned certificates have been invalidated by Apple.".dim)
        }
    }
}
