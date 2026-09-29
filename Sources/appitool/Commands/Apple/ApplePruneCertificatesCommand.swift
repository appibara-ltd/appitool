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

        var certTypes: [Operations.certificates_getCollection.Input.Query.filter_lbrack_certificateType_rbrack_PayloadPayload]? = nil
        if let typeFilter = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !typeFilter.isEmpty {
            switch typeFilter {
            case "distribution", "dist":
                certTypes = [.DISTRIBUTION, .IOS_DISTRIBUTION, .MAC_APP_DISTRIBUTION]
            case "development", "dev":
                certTypes = [.DEVELOPMENT, .IOS_DEVELOPMENT, .MAC_APP_DEVELOPMENT]
            case "developer-id", "developer_id", "direct":
                certTypes = [.DEVELOPER_ID_APPLICATION]
            case "ios-distribution":
                certTypes = [.IOS_DISTRIBUTION, .DISTRIBUTION]
            case "ios-development":
                certTypes = [.IOS_DEVELOPMENT, .DEVELOPMENT]
            case "mac-distribution":
                certTypes = [.MAC_APP_DISTRIBUTION]
            case "mac-development":
                certTypes = [.MAC_APP_DEVELOPMENT]
            default:
                break
            }
        }

        print("🔍 Inspecting certificates on Apple Developer Portal...".dim)
        let certs = try await service.fetchCertificates(types: certTypes)

        let now = Date()
        let toPrune = certs.filter { cert in
            guard let expirationDate = cert.attributes?.expirationDate else { return false }
            return expirationDate < now
        }

        if toPrune.isEmpty {
            let filterDesc = type.map { " (\($0))" } ?? ""
            print("✓ No expired certificates\(filterDesc) found on Apple Developer Portal. Portal is clean!".green.bold)
            return
        }

        let modePrefix = dryRun ? "[Dry Run] ".yellow.bold : ""
        print("\n\(modePrefix)Found \(toPrune.count) expired certificate(s) for pruning:".bold)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        for cert in toPrune {
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

        var deletedCount = 0
        var failedCount = 0

        for cert in toPrune {
            let nameStr = cert.attributes?.name ?? "unnamed"
            do {
                let success = try await service.deleteCertificate(id: cert.id)
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

        print("\n✓ Pruning finished: \(deletedCount) certificate(s) deleted".green.bold + (failedCount > 0 ? ", \(failedCount) failed/skipped.".yellow : "."))
        if deletedCount > 0 {
            print("ℹ️ Note: Any provisioning profiles that were tied to these pruned certificates have been invalidated by Apple.".dim)
        }
    }
}
