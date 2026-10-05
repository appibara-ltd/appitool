import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleListCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-certificates",
        abstract: "Lists Certificates registered on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by certificate type (e.g. distribution, development, developer_id).")
    var type: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        let certTypes = type.flatMap { AppleTypeMapper.parseCertificateQueryFilter($0) }

        Log("🔍 Fetching certificates from Apple Developer Portal...".dim)
        let certs = try await service.fetchCertificates(types: certTypes, limit: limit)

        if certs.isEmpty {
            if let filter = type {
                Log("No certificates matching '\(filter)' found on Apple Developer Portal.".yellow)
            } else {
                Log("No certificates found on Apple Developer Portal.".yellow)
            }
            return
        }

        Log("\nFound \(certs.count) certificate(s):".bold)
        let now = Date()
        for cert in certs {
            let nameStr = cert.attributes?.name ?? "unnamed"
            let typeStr = cert.attributes?.certificateType?.rawValue ?? "UNKNOWN"
            let serialStr = cert.attributes?.serialNumber ?? "-"

            let expirationStr: String
            let isExpired: Bool
            if let date = cert.attributes?.expirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                expirationStr = formatter.string(from: date)
                isExpired = date < now
            } else {
                expirationStr = "-"
                isExpired = false
            }
            let statusStr = isExpired ? "EXPIRED".red.bold : "ACTIVE".green

            Log("  • ".cyan + "\(nameStr)".bold + " [Portal ID: \(cert.id), Type: \(typeStr), Status: \(statusStr), Serial: \(serialStr), Expires: \(expirationStr)]".dim)
        }
        Log("")
    }
}
