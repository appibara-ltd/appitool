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

        let certType: Components.Schemas.CertificateType
        let typeLabel: String
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development", "dev":
            certType = .DEVELOPMENT
            typeLabel = "Development"
        case "distribution", "dist":
            certType = .DISTRIBUTION
            typeLabel = "Distribution"
        case "developer-id", "developer_id", "developerid":
            certType = .DEVELOPER_ID_APPLICATION
            typeLabel = "Developer ID Application"
        case "ios-development":
            certType = .IOS_DEVELOPMENT
            typeLabel = "iOS Development"
        case "ios-distribution":
            certType = .IOS_DISTRIBUTION
            typeLabel = "iOS Distribution"
        case "mac-development":
            certType = .MAC_APP_DEVELOPMENT
            typeLabel = "Mac Development"
        case "mac-distribution":
            certType = .MAC_APP_DISTRIBUTION
            typeLabel = "Mac App Distribution"
        case "mac-installer":
            certType = .MAC_INSTALLER_DISTRIBUTION
            typeLabel = "Mac Installer Distribution"
        default:
            print("Error: ".red.bold + "Unsupported certificate type '\(type)'.")
            print("💡 Supported types: development, distribution, developer-id, ios-development, ios-distribution, mac-development, mac-distribution, mac-installer".yellow)
            return
        }

        let cn = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Appitool \(typeLabel)"

        // 1. Generate RSA 2048-bit private key and CSR using swift-certificates
        print("🔐 Generating RSA 2048-bit private key and CSR...".dim)
        let csrResult: CSRGenerator.CSRResult
        do {
            csrResult = try CSRGenerator.generate(commonName: cn)
        } catch {
            print("Error: ".red.bold + "Failed to generate RSA private key and CSR: \(error.localizedDescription)")
            return
        }

        // 2. Submit CSR to Apple Developer Portal
        print("🚀 Submitting CSR to Apple Developer Portal for \(typeLabel) certificate...".dim)
        let certificate: Components.Schemas.Certificate
        do {
            certificate = try await service.createCertificate(csrContent: csrResult.csrPEM, certificateType: certType)
        } catch {
            print("Error: ".red.bold + "Failed to create certificate: \(error.localizedDescription)")
            return
        }

        guard let base64Cert = certificate.attributes?.certificateContent,
              let cerData = Data(base64Encoded: base64Cert, options: [.ignoreUnknownCharacters]) else {
            print("Error: ".red.bold + "Apple Developer Portal returned invalid certificate content.")
            return
        }

        // 3. Save files to output directory (default: ~/.appitool/certs/{type}/)
        let resolvedOutput: String
        if let userOutput = output {
            resolvedOutput = userOutput
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            resolvedOutput = "\(home)/.appitool/certs/\(type.lowercased())/"
        }
        let outputDir = URL(fileURLWithPath: resolvedOutput)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let certName = certificate.attributes?.name ?? cn
        let sanitizedName = certName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        // Save .cer (DER format)
        let cerFile = outputDir.appendingPathComponent("\(sanitizedName).cer")
        try cerData.write(to: cerFile)

        // Save private key .pem
        let keyFile = outputDir.appendingPathComponent("\(sanitizedName).private_key.pem")
        try Data(csrResult.privateKeyPEM.utf8).write(to: keyFile)

        // Optionally export .p12
        var p12File: URL? = nil
        let shouldExportP12 = p12 || p12Password != nil || saveToKeychain
        let resolvedP12Password = p12Password ?? "appitool"
        if shouldExportP12 {
            let dest = outputDir.appendingPathComponent("\(sanitizedName).p12")
            do {
                try P12Exporter.export(
                    cerData: cerData,
                    privateKeyPEM: csrResult.privateKeyPEM,
                    to: dest,
                    password: resolvedP12Password
                )
                p12File = dest
            } catch {
                print("⚠️  Warning: Failed to export .p12 archive: \(error.localizedDescription)".yellow)
            }
        }

        // 4. Optionally import into macOS 'appitool' Keychain
        var keychainImportSucceeded = false
        if saveToKeychain {
            guard let p12Path = p12File?.path else {
                print("Error: ".red.bold + "Cannot save to Keychain because .p12 archive generation failed.")
                return
            }

            print("🔐 Importing certificate and private key into 'appitool' Keychain...".dim)
            do {
                let keychainManager = KeychainManager(keychainName: "appitool", keychainPassword: "")
                try await keychainManager.prepareKeychainIfNeeded()
                try await keychainManager.importP12(
                    p12Path: p12Path,
                    password: resolvedP12Password,
                    cerPath: cerFile.path
                )

                keychainImportSucceeded = true
                print("✓ Successfully imported into 'appitool' Keychain!".green.bold)

                // Once securely imported, delete .p12 if located under ~/.appitool
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let appitoolPrefix = "\(home)/.appitool"
                if p12Path.hasPrefix(appitoolPrefix) || p12Path.contains("/.appitool/") {
                    if (try? FileManager.default.removeItem(atPath: p12Path)) != nil {
                        print("  🗑️  Cleaned up local .p12 from \(p12Path) (safely preserved in 'appitool' Keychain).".dim)
                    }
                }
            } catch {
                print("Error: ".red.bold + "Failed to import into Keychain: \(error.localizedDescription)")
            }
        }

        // 5. Print result
        let portalId = certificate.id
        let serialNumber = certificate.attributes?.serialNumber ?? "-"
        let expirationDate = certificate.attributes?.expirationDate?.description ?? "-"

        print("\n✓ Certificate created successfully!".green.bold)
        print("  • Type: ".cyan + "\(typeLabel)".bold)
        print("  • Name: ".cyan + "\(certName)")
        print("  • Portal ID: ".cyan + "\(portalId)")
        print("  • Serial: ".cyan + "\(serialNumber)")
        print("  • Expires: ".cyan + "\(expirationDate)")
        print("\n📁 Saved files:".bold)
        print("  • Certificate: ".cyan + "\(cerFile.path)")
        print("  • Private Key: ".cyan + "\(keyFile.path)")
        if let p12Dest = p12File, FileManager.default.fileExists(atPath: p12Dest.path) {
            let passSuffix = " (password: \(resolvedP12Password))".dim
            print("  • PKCS#12: ".cyan + "\(p12Dest.path)" + passSuffix)
        }
        if keychainImportSucceeded {
            print("  • Keychain: ".cyan + "appitool.keychain-db (verified)".green.bold)
        }

        print("\n⚠️  Keep the private key safe! It cannot be re-downloaded from Apple.".yellow.bold)
        print("")
    }
}
