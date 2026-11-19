import Foundation

/// Handles encryption and decryption of certificate and provisioning profile files,
/// with 100% binary and algorithm compatibility with Fastlane Match (both V1 AES-256-CBC and V2 AES-256-GCM).
package struct MatchEncryption: Sendable {
    package static let v2Prefix = "match_encrypted_v2__" // 20 bytes
    package static let v1Prefix = "Salted__"             // 8 bytes

    package init() {}

    /// Recursively decrypts all match files in the specified directory.
    package func decryptDirectory(_ directoryPath: String, password: String) async throws {
        let files = findMatchFiles(in: directoryPath)
        for file in files {
            try await decryptFile(atPath: file, password: password)
        }
    }

    /// Recursively encrypts all match files in the specified directory.
    package func encryptDirectory(_ directoryPath: String, password: String) throws {
        let files = findMatchFiles(in: directoryPath)
        for file in files {
            try encryptFile(atPath: file, password: password)
        }
    }

    package enum EncryptionFormat: String, Sendable, Equatable {
        case v2 = "v2"
        case v1 = "v1"
        case unencrypted = "unencrypted"
        case unknown = "unknown"

        package var isV2: Bool { self == .v2 }
        package var isV1: Bool { self == .v1 }
        package var isEncrypted: Bool { self == .v2 || self == .v1 }
    }

    /// Detects the encryption format of raw payload data.
    /// Returns the detected format and extracted binary payload (decoded if Base64).
    package func detectFormat(data: Data) -> (format: EncryptionFormat, payload: Data?) {
        if data.starts(with: Self.v2Prefix.utf8) {
            return (.v2, data)
        }
        if data.starts(with: Self.v1Prefix.utf8) {
            return (.v1, data)
        }
        if let base64String = String(data: data, encoding: .utf8)?
            .components(separatedBy: .whitespacesAndNewlines).joined(),
            !base64String.isEmpty,
            let decoded = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]) {
            if decoded.starts(with: Self.v2Prefix.utf8) {
                return (.v2, decoded)
            }
            if decoded.starts(with: Self.v1Prefix.utf8) {
                return (.v1, decoded)
            }
        }
        if isPlainCertificateOrProfile(data) {
            return (.unencrypted, nil)
        }
        return (.unknown, nil)
    }

    /// Detects the encryption format of a file at the given path.
    package func detectFormat(atPath path: String) -> EncryptionFormat {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            return .unknown
        }
        return detectFormat(data: data).format
    }

    /// Decrypts a single file in-place if encrypted.
    package func decryptFile(atPath path: String, password: String) async throws {
        guard let rawContent = try? Data(contentsOf: URL(fileURLWithPath: path)), !rawContent.isEmpty else {
            return
        }

        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let (format, payloadToDecrypt) = detectFormat(data: rawContent)

        switch format {
        case .v2:
            guard let payload = payloadToDecrypt else { return }
            let decryptedData = try decryptV2(encryptedPayload: payload, password: password, fileName: fileName)
            try decryptedData.write(to: URL(fileURLWithPath: path), options: .atomic)
        case .v1:
            guard let payload = payloadToDecrypt else { return }
            let decryptedData = try await decryptV1(encryptedPayload: payload, password: password, fileName: fileName)
            try decryptedData.write(to: URL(fileURLWithPath: path), options: .atomic)
        case .unencrypted:
            return
        case .unknown:
            throw MatchError.decryptionFailed("File '\(fileName)' is encrypted or unrecognized, but does not match Fastlane Match encryption format (V1 or V2).")
        }
    }

    /// Encrypts a single file in-place using Match V2 (AES-256-GCM).
    package func encryptFile(atPath path: String, password: String) throws {
        let rawData = try Data(contentsOf: URL(fileURLWithPath: path))

        let (format, _) = detectFormat(data: rawData)
        if format.isEncrypted {
            return // Already encrypted
        }

        let encryptedData = try encryptV2(data: rawData, password: password)
        let base64Result = encryptedData.base64EncodedData(options: .lineLength64Characters)
        try base64Result.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Format Detection

    private func isPlainCertificateOrProfile(_ data: Data) -> Bool {
        // DER ASN.1 SEQUENCE header (0x30 0x82 or 0x30 0x81 or 0x30 0x83) - covers DER certificates, PKCS#12 (.p12, .keystore)
        if data.count >= 2 && data[0] == 0x30 && (data[1] == 0x82 || data[1] == 0x81 || data[1] == 0x83) {
            return true
        }
        // JKS (Java KeyStore) magic bytes: 0xFE 0xED 0xFE 0xED
        if data.count >= 4 && data[0] == 0xFE && data[1] == 0xED && data[2] == 0xFE && data[3] == 0xED {
            return true
        }
        // PEM, XML, or JSON header
        if let str = String(data: data.prefix(100), encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("<?xml") || trimmed.contains("<!DOCTYPE") || trimmed.contains("-----BEGIN") || trimmed.hasPrefix("{") {
                return true
            }
        }
        return false
    }

    // MARK: - Directory Scanning

    private func findMatchFiles(in directoryPath: String) -> [String] {
        let fm = FileManager.default
        let dirUrl = URL(fileURLWithPath: directoryPath)
        guard let enumerator = fm.enumerator(
            at: dirUrl,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [String] = []
        let supportedExtensions: Set<String> = [
            "cer", "p12", "mobileprovision", "provisionprofile",
            "keystore", "jks", "json", "pem"
        ]

        for case let fileUrl as URL in enumerator {
            // Guard against .git directory or hidden file inside the cloned repository
            if fileUrl.pathComponents.contains(".git") || fileUrl.lastPathComponent.hasPrefix(".") {
                continue
            }

            guard let isRegular = try? fileUrl.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular == true else {
                continue
            }

            let ext = fileUrl.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                results.append(fileUrl.path)
            }
        }
        return results
    }
}
