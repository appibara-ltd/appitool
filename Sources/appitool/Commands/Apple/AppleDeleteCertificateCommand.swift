import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteCertificateCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-certificate",
        abstract: "Deletes (revokes) a Certificate from Apple Developer Portal."
    )

    var destructiveCommandDescription: String { "apple delete-certificate" }

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .shortAndLong, help: "Certificate Portal ID to delete.")
    var portalId: String?

    @Option(name: .shortAndLong, help: "Certificate name to delete.")
    var name: String?

    @Option(name: .shortAndLong, help: "Certificate serial number to delete.")
    var serialNumber: String?

    func execute() async throws {
        guard (portalId != nil && !portalId!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
              (name != nil && !name!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
              (serialNumber != nil && !serialNumber!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw CommandError("Missing target certificate. Provide -p, --portal-id, -n, --name, or -s, --serial-number.")
        }

        let service = try appleCredentials.requireService()

        let targetDescription = name ?? serialNumber ?? portalId ?? "unknown"
        Log("🔍 Searching for certificate '\(targetDescription)' on Apple Developer Portal...".dim)

        let result = try await service.deleteSigningCertificate(
            portalId: portalId,
            name: name,
            serialNumber: serialNumber
        )

        if result.deleted {
            let displayName = result.matchedCertificate?.attributes?.name ?? result.targetDescription
            Log("🟢 Successfully deleted certificate '\(displayName)' from Apple Developer Portal.".green.bold)
            Log("🟡️ Note: Any provisioning profiles tied to this certificate have been invalidated by Apple.".dim)
        } else {
            Log("🟡️ Certificate '\(result.targetDescription)' does not exist on Apple Developer Portal (already absent).".yellow)
        }
    }
}
