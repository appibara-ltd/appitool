import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteCertificateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-certificate",
        abstract: "Deletes (revokes) a Certificate from Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Certificate Portal ID to delete.")
    var portalId: String?

    @Option(name: .shortAndLong, help: "Certificate name to delete.")
    var name: String?

    @Option(name: .shortAndLong, help: "Certificate serial number to delete.")
    var serialNumber: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let trimmedId = portalId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSerial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedId != nil && !trimmedId!.isEmpty) ||
              (trimmedName != nil && !trimmedName!.isEmpty) ||
              (trimmedSerial != nil && !trimmedSerial!.isEmpty) else {
            print("Error: ".red.bold + "Missing target certificate. Provide -p, --portal-id, -n, --name, or -s, --serial-number.")
            return
        }

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        // Direct delete if only portal ID is provided
        if let directId = trimmedId, trimmedName == nil, trimmedSerial == nil {
            print("🗑️ Deleting certificate by ID ".red + "\(directId)".bold + "...".dim)
            do {
                let deleted = try await service.deleteCertificate(id: directId)
                if deleted {
                    print("✓ Successfully deleted certificate (Portal ID: \(directId)) from Apple Developer Portal.".green.bold)
                    print("ℹ️ Note: Any provisioning profiles tied to this certificate have been invalidated by Apple.".dim)
                } else {
                    print("ℹ️ Certificate (Portal ID: '\(directId)') was not found on Apple Developer Portal (already absent).".yellow)
                }
            } catch {
                print("Error: ".red.bold + "Failed to delete certificate: \(error.localizedDescription)")
            }
            return
        }

        let targetDescription = trimmedName ?? trimmedSerial ?? trimmedId ?? "unknown"
        print("🔍 Searching for certificate '\(targetDescription)' on Apple Developer Portal...".dim)
        let certs = try await service.fetchCertificates()

        let matched = certs.first { cert in
            if let targetId = trimmedId, cert.id == targetId {
                return true
            }
            if let targetSerial = trimmedSerial, cert.attributes?.serialNumber == targetSerial {
                return true
            }
            if let targetName = trimmedName, cert.attributes?.name == targetName {
                return true
            }
            return false
        }

        guard let targetCert = matched else {
            print("ℹ️ Certificate '\(targetDescription)' does not exist on Apple Developer Portal (already absent).".yellow)
            return
        }

        let certName = targetCert.attributes?.name ?? "unnamed"
        let certType = targetCert.attributes?.certificateType?.rawValue ?? "UNKNOWN"
        let portalId = targetCert.id

        print("🗑️ Deleting certificate ".red + "\(certName)".bold + " [Type: \(certType), Portal ID: \(portalId)]...".dim)

        do {
            let deleted = try await service.deleteCertificate(id: portalId)
            if deleted {
                print("✓ Successfully deleted certificate '\(certName)' from Apple Developer Portal.".green.bold)
                print("ℹ️ Note: Any provisioning profiles tied to this certificate have been invalidated by Apple.".dim)
            } else {
                print("ℹ️ Certificate '\(certName)' was not found or already deleted on Apple Developer Portal.".yellow)
            }
        } catch {
            print("Error: ".red.bold + "Failed to delete certificate: \(error.localizedDescription)")
        }
    }
}
