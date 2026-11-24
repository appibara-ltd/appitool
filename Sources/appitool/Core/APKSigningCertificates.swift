import Crypto
import Foundation

/// A signing certificate found in an APK, with its fingerprints.
struct APKSigningCertificate: Sendable, Equatable {
    /// DER-encoded X.509 certificate.
    let der: Data
    /// Signature schemes the certificate appeared in (e.g. `v2`, `v3`).
    var schemes: [String]

    var sha1: String { APKSigningCertificates.fingerprint(Data(Insecure.SHA1.hash(data: der))) }
    var sha256: String { APKSigningCertificates.fingerprint(Data(SHA256.hash(data: der))) }
    /// Signature algorithm of the certificate (e.g. `RSA / SHA-256`, `ML-DSA-65`).
    var algorithm: String { APKSigningCertificates.signatureAlgorithm(of: der) }
}

enum APKSigningCertificateError: LocalizedError, Equatable {
    case notAZip
    case noSigningBlock

    var errorDescription: String? {
        switch self {
        case .notAZip: return "The downloaded file is not a valid APK (ZIP end of central directory not found)."
        case .noSigningBlock: return "The APK has no APK Signature Scheme v2/v3 block (v1-only APKs are not supported)."
        }
    }
}

/// Reads signing certificates from the APK Signing Block (APK Signature Scheme v2, v3, and v3.1).
enum APKSigningCertificates {
    /// Known APK Signing Block IDs. `0x70E1C89F` holds Play App Signing's hybrid (classical + post-quantum ML-DSA)
    /// certificates; it is not in Android's public documentation and was identified from Play-generated APKs.
    static let schemeIds: [UInt32: String] = [
        0x7109_871A: "v2",
        0xF053_68C0: "v3",
        0x1B93_AD61: "v3.1",
        0x70E1_C89F: "hybrid",
    ]
    private static let magic = Data("APK Sig Block 42".utf8)

    /// Unique certificates in the APK, in the order first seen.
    static func certificates(in apk: Data) throws -> [APKSigningCertificate] {
        let bytes = [UInt8](apk)
        guard let eocd = findEndOfCentralDirectory(bytes) else { throw APKSigningCertificateError.notAZip }
        let centralDirectoryOffset = Int(readUInt32(bytes, eocd + 16))

        // Signing block: [size (u64)] [pairs…] [size (u64)] [magic (16)] immediately before the central directory.
        guard centralDirectoryOffset >= 32, centralDirectoryOffset <= bytes.count,
              Data(bytes[(centralDirectoryOffset - 16)..<centralDirectoryOffset]) == magic else {
            throw APKSigningCertificateError.noSigningBlock
        }
        let blockSize = Int(readUInt64(bytes, centralDirectoryOffset - 24))
        let blockStart = centralDirectoryOffset - blockSize - 8
        guard blockSize > 24, blockStart >= 0 else { throw APKSigningCertificateError.noSigningBlock }

        var result: [APKSigningCertificate] = []
        var offset = blockStart + 8
        let pairsEnd = centralDirectoryOffset - 24
        while offset + 12 <= pairsEnd {
            let pairLength = Int(readUInt64(bytes, offset))
            let id = readUInt32(bytes, offset + 8)
            let valueStart = offset + 12
            let valueEnd = offset + 8 + pairLength
            guard pairLength >= 4, valueEnd <= pairsEnd else { break }
            // Known schemes, plus unknown blocks with the same signer layout (e.g. newer or hybrid post-quantum schemes);
            // for unknown blocks only values that look like DER certificates are kept.
            let scheme = schemeIds[id] ?? String(format: "block 0x%08X", id)
            let found = signerCertificates(bytes, start: valueStart, end: valueEnd)
                .filter { schemeIds[id] != nil || looksLikeCertificate($0) }
            for der in found {
                if let index = result.firstIndex(where: { $0.der == der }) {
                    if !result[index].schemes.contains(scheme) { result[index].schemes.append(scheme) }
                } else {
                    result.append(APKSigningCertificate(der: der, schemes: [scheme]))
                }
            }
            offset = valueEnd
        }
        guard !result.isEmpty else { throw APKSigningCertificateError.noSigningBlock }
        return result
    }

    /// Reads a certificate file: DER, or PEM (`-----BEGIN CERTIFICATE-----`).
    static func certificate(fromFile url: URL) throws -> APKSigningCertificate {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            let base64 = text
                .components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().first?
                .components(separatedBy: "-----END CERTIFICATE-----").first?
                .filter { !$0.isWhitespace } ?? ""
            guard let der = Data(base64Encoded: base64) else {
                throw CommandError("Invalid PEM certificate: \(url.path)")
            }
            return APKSigningCertificate(der: der, schemes: [])
        }
        guard looksLikeCertificate(data) else {
            throw CommandError("Not a DER or PEM certificate: \(url.path)")
        }
        return APKSigningCertificate(der: data, schemes: [])
    }

    /// Signature algorithm name from the first known algorithm OID in the certificate.
    static func signatureAlgorithm(of der: Data) -> String {
        let known: [(oid: [UInt8], name: String)] = [
            ([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x11], "ML-DSA-44 (post-quantum)"),
            ([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x12], "ML-DSA-65 (post-quantum)"),
            ([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x13], "ML-DSA-87 (post-quantum)"),
            ([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B], "RSA / SHA-256"),
            ([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C], "RSA / SHA-384"),
            ([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D], "RSA / SHA-512"),
            ([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05], "RSA / SHA-1"),
            ([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02], "ECDSA / SHA-256"),
            ([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03], "ECDSA / SHA-384"),
        ]
        let bytes = [UInt8](der)
        var best: (index: Int, name: String)?
        for (oid, name) in known {
            guard bytes.count >= oid.count + 2 else { continue }
            for index in 0...(bytes.count - oid.count - 2) where bytes[index] == 0x06 && Int(bytes[index + 1]) == oid.count {
                if Array(bytes[(index + 2)..<(index + 2 + oid.count)]) == oid {
                    if best == nil || index < best!.index { best = (index, name) }
                    break
                }
            }
        }
        return best?.name ?? "unknown"
    }

    /// DER SEQUENCE whose length covers the whole value (an X.509 certificate starts this way).
    static func looksLikeCertificate(_ der: Data) -> Bool {
        let bytes = [UInt8](der)
        guard bytes.count > 4, bytes[0] == 0x30 else { return false }
        if bytes[1] < 0x80 { return Int(bytes[1]) + 2 == bytes.count }
        let lengthBytes = Int(bytes[1] & 0x7F)
        guard (1...4).contains(lengthBytes), bytes.count > 2 + lengthBytes else { return false }
        let length = bytes[2..<(2 + lengthBytes)].reduce(0) { $0 << 8 | Int($1) }
        return length + 2 + lengthBytes == bytes.count
    }

    /// `AA:BB:…` uppercase hex.
    static func fingerprint(_ digest: Data) -> String {
        digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Normalizes a hex fingerprint (any case, with or without colons) for comparison.
    static func normalizeHex(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit }
    }

    // MARK: - Parsing

    /// Certificates of every signer in a v2/v3 signature scheme block:
    /// signers (len-prefixed) → signer (len-prefixed) → signed data (len-prefixed) → digests, certificates.
    private static func signerCertificates(_ bytes: [UInt8], start: Int, end: Int) -> [Data] {
        var certificates: [Data] = []
        for signer in lengthPrefixedItems(bytes, sequence: start, end: end) {
            guard let signedData = lengthPrefixedItem(bytes, at: signer.start, end: signer.end) else { continue }
            guard let digests = lengthPrefixedItem(bytes, at: signedData.start, end: signedData.end),
                  let certs = lengthPrefixedItem(bytes, at: digests.end, end: signedData.end) else { continue }
            for cert in lengthPrefixedItems(bytes, sequence: certs.start - 4, end: certs.end) {
                certificates.append(Data(bytes[cert.start..<cert.end]))
            }
        }
        return certificates
    }

    /// The items of a length-prefixed sequence starting at `sequence` (whose own u32 length prefixes the items).
    private static func lengthPrefixedItems(_ bytes: [UInt8], sequence: Int, end: Int) -> [(start: Int, end: Int)] {
        guard let container = lengthPrefixedItem(bytes, at: sequence, end: end) else { return [] }
        var items: [(Int, Int)] = []
        var offset = container.start
        while let item = lengthPrefixedItem(bytes, at: offset, end: container.end) {
            items.append((item.start, item.end))
            offset = item.end
        }
        return items
    }

    /// A u32-length-prefixed item at `offset`, bounded by `end`.
    private static func lengthPrefixedItem(_ bytes: [UInt8], at offset: Int, end: Int) -> (start: Int, end: Int)? {
        guard offset >= 0, offset + 4 <= end else { return nil }
        let length = Int(readUInt32(bytes, offset))
        let start = offset + 4
        guard start + length <= end else { return nil }
        return (start, start + length)
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var index = bytes.count - 22
        while index >= lowest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }
}
