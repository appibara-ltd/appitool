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
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        print("🔍 Inspecting certificates on Apple Developer Portal...".dim)
        let result = try await service.pruneCertificates(typeFilter: type, dryRun: dryRun)

        if result.candidates.isEmpty {
            let filterDesc = type.map { " (\($0))" } ?? ""
            print("✓ No expired certificates\(filterDesc) found on Apple Developer Portal. Portal is clean!".green.bold)
            return
        }

        let modePrefix = dryRun ? "[Dry Run] ".yellow.bold : ""
        print("\n\(modePrefix)Found \(result.candidates.count) expired certificate(s) for pruning:".bold)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        for cert in result.candidates {
            let nameStr = cert.attributes?.name ?? "unnamed"
            let typeStr = cert.attributes?.certificateType?.rawValue ?? "UNKNOWN"
            let serialStr = cert.attributes?.serialNumber ?? "-"
            let expirationStr = cert.attributes?.expirationDate.map { formatter.string(from: $0) } ?? "-"

            print("  • ".cyan + "\(nameStr)".bold + " [Reason: " + "EXPIRED".red.bold + ", Type: \(typeStr), Serial: \(serialStr), Expires: \(expirationStr), Portal ID: \(cert.id)]".dim)
        }
        print("")

        if dryRun {
            print("ℹ️ Dry run complete. No certificates were modified. Re-run without --dry-run (-d) to delete them.".yellow)
            return
        }

        for cert in result.candidates {
            let nameStr = cert.attributes?.name ?? "unnamed"
            if let fail = result.failedCertificates.first(where: { $0.name == nameStr }) {
                print("  ❌ Failed to delete '\(nameStr)': \(fail.error)".red)
            } else {
                print("  ✓ Pruned: ".green + "\(nameStr)".bold)
            }
        }

        print("\n✓ Pruning finished: \(result.deletedCount) certificate(s) deleted".green.bold + (result.failedCertificates.count > 0 ? ", \(result.failedCertificates.count) failed/skipped.".yellow : "."))
        if result.deletedCount > 0 {
            print("ℹ️ Note: Any provisioning profiles that were tied to these pruned certificates have been invalidated by Apple.".dim)
        }
    }
}
