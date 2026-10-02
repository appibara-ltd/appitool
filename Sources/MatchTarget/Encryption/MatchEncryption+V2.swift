import Foundation
import Crypto
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Match V2 (AES-256-GCM) Implementation

extension MatchEncryption {

    package func decryptV2(encryptedPayload: Data, password: String, fileName: String) throws -> Data {
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

    package func encryptV2(data: Data, password: String) throws -> Data {
        var salt = Data(count: 8)
        #if canImport(Security)
        let saltResult = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!)
        }
        guard saltResult == errSecSuccess else {
            throw MatchError.encryptionFailed("Failed to generate secure random salt.")
        }
        #else
        salt = SymmetricKey(size: .init(bitCount: 64)).withUnsafeBytes { Data($0) }
        #endif

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

    package func pbkdf2HmacSha256(password: String, salt: Data, length: Int, iterations: UInt32) throws -> Data {
        #if canImport(CommonCrypto)
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
        #else
        let key = SymmetricKey(data: Data(password.utf8))
        var derivedKey = Data()
        var blockIndex: UInt32 = 1

        while derivedKey.count < length {
            var blockIndexBigEndian = blockIndex.bigEndian
            var u = Data(salt)
            u.append(Data(bytes: &blockIndexBigEndian, count: MemoryLayout<UInt32>.size))
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))

            var f = u
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for i in 0..<f.count {
                    f[i] ^= u[i]
                }
            }

            derivedKey.append(f)
            blockIndex += 1
        }

        return derivedKey.prefix(length)
        #endif
    }
}
