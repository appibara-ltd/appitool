import Foundation
import Crypto
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - Match V1 (Legacy AES-256-CBC) Implementation

extension MatchEncryption {

    package enum V1HashAlgorithm {
        case md5
        case sha256
    }

    package func decryptV1(encryptedPayload: Data, password: String, fileName: String) async throws -> Data {
        let prefixLen = Self.v1Prefix.utf8.count // 8 bytes ("Salted__")
        guard encryptedPayload.count >= prefixLen + 8 else {
            throw MatchError.decryptionFailed("Corrupted V1 encrypted structure in '\(fileName)'.")
        }

        let salt = encryptedPayload.subdata(in: prefixLen..<(prefixLen + 8))
        let ciphertext = encryptedPayload.subdata(in: (prefixLen + 8)..<encryptedPayload.count)

        // 1. Try MD5 EVP_BytesToKey (Fastlane legacy default / OpenSSL 1.0.x)
        let (keyMd5, ivMd5) = evpBytesToKey(password: password, salt: salt, keyLen: 32, ivLen: 16, hash: .md5)
        if let decrypted = try? await decryptAes256Cbc(data: ciphertext, key: keyMd5, iv: ivMd5),
           isValidDecryptedPayload(decrypted) {
            return decrypted
        }

        // 2. Try SHA256 EVP_BytesToKey (Fastlane with OpenSSL 1.1+)
        let (keySha256, ivSha256) = evpBytesToKey(password: password, salt: salt, keyLen: 32, ivLen: 16, hash: .sha256)
        if let decrypted = try? await decryptAes256Cbc(data: ciphertext, key: keySha256, iv: ivSha256),
           isValidDecryptedPayload(decrypted) {
            return decrypted
        }

        // 3. Try PBKDF2 HMAC-SHA256 fallback (OpenSSL 1.1+ -pbkdf2 flag)
        if let derived = try? pbkdf2HmacSha256(password: password, salt: salt, length: 48, iterations: 10_000) {
            let key = derived.subdata(in: 0..<32)
            let iv = derived.subdata(in: 32..<48)
            if let decrypted = try? await decryptAes256Cbc(data: ciphertext, key: key, iv: iv),
               isValidDecryptedPayload(decrypted) {
                return decrypted
            }
        }

        throw MatchError.decryptionFailed("Failed to decrypt '\(fileName)'. Invalid password or corrupted AES-256-CBC data.")
    }

    /// OpenSSL EVP_BytesToKey key and IV derivation algorithm (PKCS#5 v1.5 compatible with count = 1).
    package func evpBytesToKey(password: String, salt: Data, keyLen: Int, ivLen: Int, hash: V1HashAlgorithm) -> (key: Data, iv: Data) {
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

    package func decryptAes256Cbc(data: Data, key: Data, iv: Data) async throws -> Data {
        #if canImport(CommonCrypto)
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
        #else
        let keyHex = key.map { String(format: "%02x", $0) }.joined()
        let ivHex = iv.map { String(format: "%02x", $0) }.joined()
        let result = try await ProcessRunner.runBytes(
            "/usr/bin/openssl",
            arguments: ["enc", "-d", "-aes-256-cbc", "-K", keyHex, "-iv", ivHex],
            input: Array(data)
        )
        let decryptedData = Data(result.stdout)
        guard result.exitCode == 0, !decryptedData.isEmpty else {
            throw MatchError.decryptionFailed("AES-256-CBC decryption via openssl failed.")
        }
        return decryptedData
        #endif
    }

    package func isValidDecryptedPayload(_ data: Data) -> Bool {
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
}
