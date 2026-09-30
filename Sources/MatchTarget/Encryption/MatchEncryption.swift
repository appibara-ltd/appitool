import Foundation
import Crypto
import CommonCrypto

/// Handles encryption and decryption of certificate and provisioning profile files,
/// with 100% binary and algorithm compatibility with Fastlane Match (both V1 AES-256-CBC and V2 AES-256-GCM).
package final class MatchEncryption: Sendable {
    private static let v2Prefix = "match_encrypted_v2__" // 20 bytes
    private static let v1Prefix = "Salted__"             // 8 bytes

    package init() {}

    /// Recursively decrypts all match files in the specified directory.
    package func decryptDirectory(_ directoryPath: String, password: String) throws {
        let files = findMatchFiles(in: directoryPath)
        for file in files {
            try decryptFile(atPath: file, password: password)
        }
    }

    /// Recursively encrypts all match files in the specified directory.
    package func encryptDirectory(_ directoryPath: String, password: String) throws {
        let files = findMatchFiles(in: directoryPath)
        for file in files {
            try encryptFile(atPath: file, password: password)
        }
    }

    /// Decrypts a single file in-place if encrypted.
    package func decryptFile(atPath path: String, password: String) throws {
        guard let rawContent = try? Data(contentsOf: URL(fileURLWithPath: path)), !rawContent.isEmpty else {
            return
        }

        let fileName = URL(fileURLWithPath: path).lastPathComponent

        // Detect if rawContent is directly binary or Base64 encoded
        var payloadToDecrypt: Data? = nil
        var isV2 = false
        var isV1 = false

        if rawContent.starts(with: Self.v2Prefix.utf8) {
            payloadToDecrypt = rawContent
            isV2 = true
        } else if rawContent.starts(with: Self.v1Prefix.utf8) {
            payloadToDecrypt = rawContent
            isV1 = true
        } else if let base64String = String(data: rawContent, encoding: .utf8)?
            .components(separatedBy: .whitespacesAndNewlines).joined(),
            !base64String.isEmpty,
            let decoded = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]) {
            if decoded.starts(with: Self.v2Prefix.utf8) {
                payloadToDecrypt = decoded
                isV2 = true
            } else if decoded.starts(with: Self.v1Prefix.utf8) {
                payloadToDecrypt = decoded
                isV1 = true
            }
        }

        if let payload = payloadToDecrypt {
            let decryptedData: Data
            if isV2 {
                decryptedData = try decryptV2(encryptedPayload: payload, password: password, fileName: fileName)
            } else if isV1 {
                decryptedData = try decryptV1(encryptedPayload: payload, password: password, fileName: fileName)
            } else {
                return
            }
            try decryptedData.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            // If the file is not encrypted with V1 or V2, verify whether it's already a valid plain certificate/profile
            if !isPlainCertificateOrProfile(rawContent) {
                throw MatchError.decryptionFailed("File '\(fileName)' is encrypted or unrecognized, but does not match Fastlane Match encryption format (V1 or V2).")
            }
        }
    }

    /// Encrypts a single file in-place using Match V2 (AES-256-GCM).
    package func encryptFile(atPath path: String, password: String) throws {
        let rawData = try Data(contentsOf: URL(fileURLWithPath: path))

        // Check if already encrypted
        if rawData.starts(with: Self.v2Prefix.utf8) || rawData.starts(with: Self.v1Prefix.utf8) {
            return
        }
        if let base64String = String(data: rawData, encoding: .utf8)?
            .components(separatedBy: .whitespacesAndNewlines).joined(),
           let decoded = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]) {
            if decoded.starts(with: Self.v2Prefix.utf8) || decoded.starts(with: Self.v1Prefix.utf8) {
                return // Already encrypted
            }
        }

        let encryptedData = try encryptV2(data: rawData, password: password)
        let base64Result = encryptedData.base64EncodedData(options: .lineLength64Characters)
        try base64Result.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Match V2 (AES-256-GCM) Implementation

    private func decryptV2(encryptedPayload: Data, password: String, fileName: String) throws -> Data {
        let prefixLen = Self.v2Prefix.utf8.count // 20 bytes
        guard encryptedPayload.count >= prefixLen + 8 + 16 else {
            throw MatchError.decryptionFailed("Corrupted V2 encrypted structure in '\(fileName)'.")
        }

        let salt = encryptedPayload.subdata(in: prefixLen..<(prefixLen + 8))
        let tag = encryptedPayload.subdata(in: (prefixLen + 8)..<(prefixLen + 24))
        let ciphertext = encryptedPayload.subdata(in: (prefixLen + 24)..<encryptedPayload.count)

        // Derive key (32 bytes), iv (12 bytes), aad (24 bytes) via PBKDF2 HMAC-SHA256 (10,000 iterations)
        let derived = try pbkdf2HmacSha256(password: password, salt: salt, length: 68, iterations: 10_000)
        let key = SymmetricKey(data: derived.subdata(in: 0..<32))
        let nonce = try AES.GCM.Nonce(data: derived.subdata(in: 32..<44))
        let aad = derived.subdata(in: 44..<68)

        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw MatchError.decryptionFailed("Failed to decrypt '\(fileName)'. Invalid password or corrupted AES-256-GCM data.")
        }
    }

    private func encryptV2(data: Data, password: String) throws -> Data {
        var salt = Data(count: 8)
        let saltResult = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!)
        }
        guard saltResult == errSecSuccess else {
            throw MatchError.encryptionFailed("Failed to generate secure random salt.")
        }

        let derived = try pbkdf2HmacSha256(password: password, salt: salt, length: 68, iterations: 10_000)
        let key = SymmetricKey(data: derived.subdata(in: 0..<32))
        let nonce = try AES.GCM.Nonce(data: derived.subdata(in: 32..<44))
        let aad = derived.subdata(in: 44..<68)

        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: aad)

        var payload = Data(Self.v2Prefix.utf8)
        payload.append(salt)
        payload.append(sealed.tag)
        payload.append(sealed.ciphertext)
        return payload
    }

    private func pbkdf2HmacSha256(password: String, salt: Data, length: Int, iterations: UInt32) throws -> Data {
        var derivedKey = Data(count: length)

        let status = password.withCString { passPtr in
            salt.withUnsafeBytes { saltBytes in
                derivedKey.withUnsafeMutableBytes { outBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr,
                        strlen(passPtr),
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        length
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw MatchError.decryptionFailed("PBKDF2 key derivation failed (status \(status)).")
        }
        return derivedKey
    }

    // MARK: - Match V1 (Legacy AES-256-CBC) Implementation

    private enum V1HashAlgorithm {
        case md5
        case sha256
    }

    private func decryptV1(encryptedPayload: Data, password: String, fileName: String) throws -> Data {
        let prefixLen = Self.v1Prefix.utf8.count // 8 bytes ("Salted__")
        guard encryptedPayload.count >= prefixLen + 8 else {
            throw MatchError.decryptionFailed("Corrupted V1 encrypted structure in '\(fileName)'.")
        }

        let salt = encryptedPayload.subdata(in: prefixLen..<(prefixLen + 8))
        let ciphertext = encryptedPayload.subdata(in: (prefixLen + 8)..<encryptedPayload.count)

        // 1. Try MD5 EVP_BytesToKey (Fastlane legacy default / OpenSSL 1.0.x)
        let (keyMd5, ivMd5) = evpBytesToKey(password: password, salt: salt, keyLen: 32, ivLen: 16, hash: .md5)
        if let decrypted = try? decryptAes256Cbc(data: ciphertext, key: keyMd5, iv: ivMd5),
           isValidDecryptedPayload(decrypted) {
            return decrypted
        }

        // 2. Try SHA256 EVP_BytesToKey (Fastlane with OpenSSL 1.1+)
        let (keySha256, ivSha256) = evpBytesToKey(password: password, salt: salt, keyLen: 32, ivLen: 16, hash: .sha256)
        if let decrypted = try? decryptAes256Cbc(data: ciphertext, key: keySha256, iv: ivSha256),
           isValidDecryptedPayload(decrypted) {
            return decrypted
        }

        // 3. Try PBKDF2 HMAC-SHA256 fallback (OpenSSL 1.1+ -pbkdf2 flag)
        if let derived = try? pbkdf2HmacSha256(password: password, salt: salt, length: 48, iterations: 10_000) {
            let key = derived.subdata(in: 0..<32)
            let iv = derived.subdata(in: 32..<48)
            if let decrypted = try? decryptAes256Cbc(data: ciphertext, key: key, iv: iv),
               isValidDecryptedPayload(decrypted) {
                return decrypted
            }
        }

        throw MatchError.decryptionFailed("Failed to decrypt '\(fileName)'. Invalid password or corrupted AES-256-CBC data.")
    }

    /// OpenSSL EVP_BytesToKey key and IV derivation algorithm (PKCS#5 v1.5 compatible with count = 1).
    private func evpBytesToKey(password: String, salt: Data, keyLen: Int, ivLen: Int, hash: V1HashAlgorithm) -> (key: Data, iv: Data) {
        let passData = Data(password.utf8)
        var derived = Data()
        var prevD = Data()

        while derived.count < (keyLen + ivLen) {
            var input = Data()
            if !prevD.isEmpty {
                input.append(prevD)
            }
            input.append(passData)
            input.append(salt)

            let digest: Data
            switch hash {
            case .md5:
                digest = Data(Insecure.MD5.hash(data: input))
            case .sha256:
                digest = Data(SHA256.hash(data: input))
            }

            derived.append(digest)
            prevD = digest
        }

        let key = derived.subdata(in: 0..<keyLen)
        let iv = derived.subdata(in: keyLen..<(keyLen + ivLen))
        return (key, iv)
    }

    private func decryptAes256Cbc(data: Data, key: Data, iv: Data) throws -> Data {
        var outData = Data(count: data.count + kCCBlockSizeAES128)
        var numBytesDecrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    outData.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            outBytes.count,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw MatchError.decryptionFailed("AES-256-CBC decryption failed with status \(status).")
        }
        outData.count = numBytesDecrypted
        return outData
    }

    // MARK: - Format Detection

    private func isValidDecryptedPayload(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        // All valid Apple certificates and PKCS#12 archives start with ASN.1 SEQUENCE (0x30)
        if data[0] == 0x30 {
            return true
        }
        // Provisioning profiles start with CMS SignedData (0x30) or XML plist (<?xml)
        if let str = String(data: data.prefix(100), encoding: .utf8) {
            if str.contains("<?xml") || str.contains("<!DOCTYPE") || str.contains("-----BEGIN") {
                return true
            }
        }
        return false
    }

    private func isPlainCertificateOrProfile(_ data: Data) -> Bool {
        // DER ASN.1 SEQUENCE header (0x30 0x82 or 0x30 0x81 or 0x30 0x83)
        if data.count >= 2 && data[0] == 0x30 && (data[1] == 0x82 || data[1] == 0x81 || data[1] == 0x83) {
            return true
        }
        // PEM or XML header
        if let str = String(data: data.prefix(100), encoding: .utf8) {
            if str.contains("<?xml") || str.contains("<!DOCTYPE") || str.contains("-----BEGIN") {
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
        let supportedExtensions: Set<String> = ["cer", "p12", "mobileprovision", "provisionprofile"]

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
