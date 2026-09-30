import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleCreateCertificateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-certificate",
        abstract: "Creates a new signing certificate on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Certificate type: development, distribution, developer-id. Defaults to distribution.")
    var type: String = "distribution"

    @Option(name: .shortAndLong, help: "Common Name (CN) for the CSR subject. Defaults to auto-generated.")
    var name: String?

    @Option(name: .shortAndLong, help: "Output directory to save certificate and private key files. Defaults to ~/.appitool/certs/{type}/.")
    var output: String?

    @Flag(name: .long, help: "Also export a .p12 (PKCS#12) archive containing the certificate and private key.")
    var p12: Bool = false

    @Option(name: .customLong("p12-password"), help: "Password for the exported .p12 (PKCS#12) archive (defaults to 'appitool' if omitted).")
    var p12Password: String?

    @Flag(name: .customLong("save-to-keychain"), help: "Import the certificate and private key into 'appitool' Keychain (creating it if needed), then delete .p12 from ~/.appitool once verified.")
    var saveToKeychain: Bool = false

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        guard let (_, typeLabel) = try? AppleTypeMapper.parseCertificateType(type) else {
            print("Error: ".red.bold + "Unsupported certificate type '\(type)'.")
            print("💡 Supported types: development, distribution, developer-id, ios-development, ios-distribution, mac-development, mac-distribution, mac-installer".yellow)
            return
        }

        print("🔐 Generating RSA 2048-bit private key and CSR...".dim)
        print("🚀 Submitting CSR to Apple Developer Portal for \(typeLabel) certificate...".dim)

        let result: CreateCertificateResult
        do {
            result = try await service.createSigningCertificate(
                type: type,
                name: name,
                outputDirectory: output,
                exportP12: p12,
                p12Password: p12Password,
                saveToKeychain: saveToKeychain
            )
        } catch {
            print("Error: ".red.bold + "Failed to create certificate: \(error.localizedDescription)")
            return
        }

        let portalId = result.certificate.id
        let serialNumber = result.certificate.attributes?.serialNumber ?? "-"
        let expirationDate = result.certificate.attributes?.expirationDate?.description ?? "-"

        print("\n✓ Certificate created successfully!".green.bold)
        print("  • Type: ".cyan + "\(result.typeLabel)".bold)
        print("  • Name: ".cyan + "\(result.commonName)")
        print("  • Portal ID: ".cyan + "\(portalId)")
        print("  • Serial: ".cyan + "\(serialNumber)")
        print("  • Expires: ".cyan + "\(expirationDate)")
        print("\n📁 Saved resources:".bold)
        if FileManager.default.fileExists(atPath: result.cerFile.path) {
            print("  • Certificate: ".cyan + "\(result.cerFile.path)")
        }
        if FileManager.default.fileExists(atPath: result.keyFile.path) {
            print("  • Private Key: ".cyan + "\(result.keyFile.path)")
        }
        if let p12Dest = result.p12File, FileManager.default.fileExists(atPath: p12Dest.path) {
            let passSuffix = " (password: \(result.p12Password))".dim
            print("  • PKCS#12: ".cyan + "\(p12Dest.path)" + passSuffix)
        }
        if result.keychainImported {
            let kcName = result.keychainName ?? "appitool"
            print("  • Keychain: ".cyan + "\(kcName).keychain-db (verified)".green.bold)
        }

        if !result.keychainImported {
            print("\n⚠️  Keep the private key safe! It cannot be re-downloaded from Apple.".yellow.bold)
        }
        print("")
    }
}
