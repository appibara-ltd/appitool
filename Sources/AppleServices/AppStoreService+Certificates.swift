import Foundation
import AppStoreConnectAPI

/// Result of creating a signing certificate.
package struct CreateCertificateResult: Sendable {
    package let certificate: Components.Schemas.Certificate
    package let typeLabel: String
    package let commonName: String
    package let cerFile: URL
    package let keyFile: URL
    package let p12File: URL?
    package let p12Password: String
    package let keychainImported: Bool
    package let keychainName: String?

    package init(
        certificate: Components.Schemas.Certificate,
        typeLabel: String,
        commonName: String,
        cerFile: URL,
        keyFile: URL,
        p12File: URL?,
        p12Password: String,
        keychainImported: Bool,
        keychainName: String?
    ) {
        self.certificate = certificate
        self.typeLabel = typeLabel
        self.commonName = commonName
        self.cerFile = cerFile
        self.keyFile = keyFile
        self.p12File = p12File
        self.p12Password = p12Password
        self.keychainImported = keychainImported
        self.keychainName = keychainName
    }
}

/// Result of deleting a signing certificate.
package struct DeleteCertificateResult: Sendable {
    package let deleted: Bool
    package let matchedCertificate: Components.Schemas.Certificate?
    package let targetDescription: String

    package init(deleted: Bool, matchedCertificate: Components.Schemas.Certificate?, targetDescription: String) {
        self.deleted = deleted
        self.matchedCertificate = matchedCertificate
        self.targetDescription = targetDescription
    }
}

/// Result of pruning expired certificates.
package struct PruneCertificatesResult: Sendable {
    package let candidates: [Components.Schemas.Certificate]
    package let isDryRun: Bool
    package let deletedCount: Int
    package let failedCertificates: [(name: String, error: String)]

    package init(
        candidates: [Components.Schemas.Certificate],
        isDryRun: Bool,
        deletedCount: Int,
        failedCertificates: [(name: String, error: String)]
    ) {
        self.candidates = candidates
        self.isDryRun = isDryRun
        self.deletedCount = deletedCount
        self.failedCertificates = failedCertificates
    }
}

/// In-memory result of generating a signing certificate.
package struct SigningCertificateData: Sendable {
    package let certificate: Components.Schemas.Certificate
    package let typeLabel: String
    package let commonName: String
    package let cerData: Data
    package let privateKeyPEM: String
    package let p12Data: Data

    package var id: String { certificate.id }

    package init(
        certificate: Components.Schemas.Certificate,
        typeLabel: String,
        commonName: String,
        cerData: Data,
        privateKeyPEM: String,
        p12Data: Data
    ) {
        self.certificate = certificate
        self.typeLabel = typeLabel
        self.commonName = commonName
        self.cerData = cerData
        self.privateKeyPEM = privateKeyPEM
        self.p12Data = p12Data
    }
}

extension AppStoreService {

    /// Generates a local RSA key and CSR, submits to Apple Developer Portal, and returns certificate, key, and .p12 Data in-memory.
    package func createSigningCertificateData(
        type: String = "distribution",
        name: String? = nil,
        p12Password: String = ""
    ) async throws -> SigningCertificateData {
        let (certType, typeLabel) = try AppleTypeMapper.parseCertificateType(type)
        return try await createSigningCertificateData(
            certificateType: certType,
            typeLabel: typeLabel,
            name: name,
            p12Password: p12Password
        )
    }

    /// Generates a local RSA key and CSR, submits to Apple Developer Portal with the specified `CertificateType`, and returns certificate, key, and .p12 Data in-memory.
    package func createSigningCertificateData(
        certificateType: Components.Schemas.CertificateType,
        typeLabel: String? = nil,
        name: String? = nil,
        p12Password: String = ""
    ) async throws -> SigningCertificateData {
        let label = typeLabel ?? "\(certificateType.rawValue)"
        let cn = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Appitool \(label)"

        // 1. Generate RSA 2048-bit Private Key and CSR
        let csrResult = try CSRGenerator.generate(commonName: cn)

        // 2. Submit CSR to Apple Developer Portal
        let certificate = try await createCertificate(csrContent: csrResult.csrPEM, certificateType: certificateType)

        do {
            guard let base64Cert = certificate.attributes?.certificateContent,
                  let cerData = Data(base64Encoded: base64Cert, options: [.ignoreUnknownCharacters]) else {
                throw AppStoreServiceError.invalidResponse("Apple Developer Portal returned invalid certificate content.")
            }

            // 3. Package .cer and private key into .p12 data
            let p12Data = try P12Exporter.export(
                cerData: cerData,
                privateKeyPEM: csrResult.privateKeyPEM,
                password: p12Password
            )

            return SigningCertificateData(
                certificate: certificate,
                typeLabel: label,
                commonName: certificate.attributes?.name ?? cn,
                cerData: cerData,
                privateKeyPEM: csrResult.privateKeyPEM,
                p12Data: p12Data
            )
        } catch {
            // Rollback: Revoke the newly created certificate from Apple Developer Portal so it does not become orphaned
            _ = try? await deleteCertificate(id: certificate.id)
            throw error
        }
    }

    /// Generates a local RSA key and CSR, submits to Apple Developer Portal, and saves certificate and key files.
    /// When `saveToKeychain` is true, imports directly from memory into Keychain without writing files to disk (unless files were explicitly requested).
    package func createSigningCertificate(
        type: String = "distribution",
        name: String? = nil,
        outputDirectory: String? = nil,
        exportP12: Bool = false,
        p12Password: String? = nil,
        saveToKeychain: Bool = false,
        keychainName: String = "appitool"
    ) async throws -> CreateCertificateResult {
        let shouldExportP12 = exportP12 || p12Password != nil
        let resolvedP12Password = p12Password ?? "appipass"

        // 1. Generate in-memory signing certificate data
        let certData = try await createSigningCertificateData(
            type: type,
            name: name,
            p12Password: resolvedP12Password
        )

        do {
            let sanitizedName = certData.commonName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")

            let resolvedOutput: String
            if let userOutput = outputDirectory {
                resolvedOutput = userOutput
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                resolvedOutput = "\(home)/.appitool/certs/\(type.lowercased())/"
            }
            let outputDir = URL(fileURLWithPath: resolvedOutput)
            let cerFile = outputDir.appendingPathComponent("\(sanitizedName).cer")
            let keyFile = outputDir.appendingPathComponent("\(sanitizedName).private_key.pem")
            var p12File: URL? = nil

            // 2. Optionally import into Keychain directly from memory
            var keychainImportSucceeded = false
            if saveToKeychain {
                let keychainManager = KeychainManager(keychainName: keychainName, keychainPassword: "")
                try await keychainManager.prepareKeychainIfNeeded()
                let importedInfo = try await keychainManager.importP12Data(
                    p12Data: certData.p12Data,
                    password: resolvedP12Password,
                    cerData: certData.cerData,
                    certId: certData.certificate.id
                )
                keychainImportSucceeded = importedInfo.isKeychainImported
            }

            // 3. Write files to disk ONLY if Keychain import was not performed / failed (e.g. non-macOS),
            // OR if the user explicitly requested output files via outputDirectory or exportP12.
            let shouldWriteDiskFiles = !keychainImportSucceeded || exportP12 || outputDirectory != nil
            if shouldWriteDiskFiles {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                try certData.cerData.write(to: cerFile)
                try Data(certData.privateKeyPEM.utf8).write(to: keyFile)

                if shouldExportP12 {
                    let dest = outputDir.appendingPathComponent("\(sanitizedName).p12")
                    try certData.p12Data.write(to: dest)
                    p12File = dest
                }
            }

            return CreateCertificateResult(
                certificate: certData.certificate,
                typeLabel: certData.typeLabel,
                commonName: certData.commonName,
                cerFile: cerFile,
                keyFile: keyFile,
                p12File: p12File,
                p12Password: resolvedP12Password,
                keychainImported: keychainImportSucceeded,
                keychainName: keychainImportSucceeded ? keychainName : nil
            )
        } catch {
            // Rollback: Revoke the newly created certificate from Apple Developer Portal if local Keychain/disk operations fail
            _ = try? await deleteCertificate(id: certData.certificate.id)
            throw error
        }
    }

    /// Deletes (revokes) a signing certificate matching portal ID, serial number, or name.
    package func deleteSigningCertificate(
        portalId: String? = nil,
        name: String? = nil,
        serialNumber: String? = nil
    ) async throws -> DeleteCertificateResult {
        let trimmedId = portalId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSerial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedId != nil && !trimmedId!.isEmpty) ||
              (trimmedName != nil && !trimmedName!.isEmpty) ||
              (trimmedSerial != nil && !trimmedSerial!.isEmpty) else {
            throw AppStoreServiceError.invalidResponse("Missing target certificate (provide portalId, name, or serialNumber).")
        }

        let targetDescription = trimmedName ?? trimmedSerial ?? trimmedId ?? "unknown"

        // Direct delete if only portal ID is provided
        if let directId = trimmedId, trimmedName == nil, trimmedSerial == nil {
            let deleted = try await deleteCertificate(id: directId)
            return DeleteCertificateResult(deleted: deleted, matchedCertificate: nil, targetDescription: targetDescription)
        }

        let certs = try await fetchCertificates()
        let matched = certs.first { cert in
            if let targetId = trimmedId, cert.id == targetId { return true }
            if let targetSerial = trimmedSerial, cert.attributes?.serialNumber == targetSerial { return true }
            if let targetName = trimmedName, cert.attributes?.name == targetName { return true }
            return false
        }

        guard let targetCert = matched else {
            return DeleteCertificateResult(deleted: false, matchedCertificate: nil, targetDescription: targetDescription)
        }

        let deleted = try await deleteCertificate(id: targetCert.id)
        return DeleteCertificateResult(deleted: deleted, matchedCertificate: targetCert, targetDescription: targetDescription)
    }

    /// Inspects and discovers all candidate expired certificates for pruning.
    package func inspectCertificatesForPruning(
        typeFilter: String? = nil
    ) async throws -> [Components.Schemas.Certificate] {
        let certTypes = typeFilter.flatMap { AppleTypeMapper.parseCertificateQueryFilter($0) }
        let certs = try await fetchCertificates(types: certTypes)
        let now = Date()

        return certs.filter { cert in
            guard let expirationDate = cert.attributes?.expirationDate else { return false }
            return expirationDate < now
        }
    }

    /// Prunes expired certificates from Apple Developer Portal.
    package func pruneCertificates(
        typeFilter: String? = nil,
        dryRun: Bool = false
    ) async throws -> PruneCertificatesResult {
        let candidates = try await inspectCertificatesForPruning(typeFilter: typeFilter)

        if dryRun || candidates.isEmpty {
            return PruneCertificatesResult(
                candidates: candidates,
                isDryRun: dryRun,
                deletedCount: 0,
                failedCertificates: []
            )
        }

        var deletedCount = 0
        var failed: [(name: String, error: String)] = []

        for cert in candidates {
            let nameStr = cert.attributes?.name ?? "unnamed"
            do {
                let success = try await deleteCertificate(id: cert.id)
                if success {
                    deletedCount += 1
                } else {
                    failed.append((nameStr, "Certificate was already absent."))
                }
            } catch {
                failed.append((nameStr, error.localizedDescription))
            }
        }

        return PruneCertificatesResult(
            candidates: candidates,
            isDryRun: false,
            deletedCount: deletedCount,
            failedCertificates: failed
        )
    }
}
