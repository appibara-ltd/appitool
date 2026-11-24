import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import GoogleServices
@testable import appitool

@Suite("APK Signing Certificates Tests")
struct APKSigningCertificatesTests {
    // MARK: - Builders

    /// A fake "certificate": DER SEQUENCE containing an algorithm OID and some filler.
    private func fakeCertificate(oid: [UInt8], filler: UInt8) -> Data {
        let content: [UInt8] = [0x06, UInt8(oid.count)] + oid + [UInt8](repeating: filler, count: 20)
        return Data([0x30, UInt8(content.count)] + content)
    }

    private func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private func u64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private func prefixed(_ bytes: [UInt8]) -> [UInt8] { u32(bytes.count) + bytes }

    /// v2/v3-style scheme value: signers[ signer[ signedData[ digests[], certificates[cert…] ] ] ].
    private func schemeValue(certs: [Data]) -> [UInt8] {
        let certificates = prefixed(certs.flatMap { prefixed([UInt8]($0)) })
        let signedData = prefixed(prefixed([]) + certificates)
        let signer = prefixed(signedData + prefixed([]) + prefixed([0x01]))
        return prefixed(signer)
    }

    /// Minimal APK: [APK Signing Block][EOCD] with an empty central directory right after the block.
    private func fakeAPK(pairs: [(id: UInt32, value: [UInt8])]) -> Data {
        var pairBytes: [UInt8] = []
        for pair in pairs {
            pairBytes += u64(pair.value.count + 4) + u32(Int(pair.id)) + pair.value
        }
        let blockSize = pairBytes.count + 8 + 16  // pairs + trailing size + magic
        let block = u64(blockSize) + pairBytes + u64(blockSize) + [UInt8]("APK Sig Block 42".utf8)
        let centralDirectoryOffset = block.count
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0] + u32(0) + u32(centralDirectoryOffset) + [0, 0]
        return Data(block + eocd)
    }

    private let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    private let mlDsa65OID: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x12]

    // MARK: - Tests

    @Test("Certificates are read from v2 blocks and from unknown (e.g. hybrid post-quantum) blocks")
    func parsesSigningBlock() throws {
        let classical = fakeCertificate(oid: rsaOID, filler: 0xAA)
        let pqc = fakeCertificate(oid: mlDsa65OID, filler: 0xBB)
        let apk = fakeAPK(pairs: [
            (0x7109_871A, schemeValue(certs: [classical])),
            (0xF053_68C0, schemeValue(certs: [classical])),
            (0x1234_5678, schemeValue(certs: [pqc])),
            (0x70E1_C89F, schemeValue(certs: [pqc])),
            (0x4242_4242, [0x00, 0x01, 0x02]),  // padding-like block without certificates
        ])

        let certs = try APKSigningCertificates.certificates(in: apk)
        #expect(certs.count == 2)
        #expect(certs[1].schemes.contains("hybrid"))
        #expect(certs[0].der == classical)
        #expect(certs[0].schemes == ["v2", "v3"])
        #expect(certs[0].algorithm == "RSA / SHA-256")
        #expect(certs[1].der == pqc)
        #expect(certs[1].schemes == ["block 0x12345678", "hybrid"])
        #expect(certs[1].algorithm == "ML-DSA-65 (post-quantum)")

        let expectedSha1 = Insecure.SHA1.hash(data: classical).map { String(format: "%02X", $0) }.joined(separator: ":")
        #expect(certs[0].sha1 == expectedSha1)
        #expect(certs[0].sha256.split(separator: ":").count == 32)
    }

    @Test("Generated APK downloads are ordered smallest-first (config splits before the universal APK)")
    func generatedApksOrdering() throws {
        let json = """
        {"generatedApks":[{"certificateSha256Hash":"5e8f",
          "generatedUniversalApk":{"downloadId":"universal"},
          "generatedStandaloneApks":[{"downloadId":"standalone","variantId":1}],
          "generatedSplitApks":[
            {"downloadId":"base","moduleName":"base","variantId":2},
            {"downloadId":"config-en","moduleName":"base","splitId":"config.en","variantId":2}
          ]}]}
        """
        let groups = try GooglePlayService.parseGeneratedApks(Data(json.utf8))
        #expect(groups.count == 1)
        #expect(groups[0].certificateSha256Hash == "5e8f")
        #expect(groups[0].downloadIds == ["config-en", "base", "standalone", "universal"])
    }

    @Test("Invalid APKs report clear errors")
    func invalidAPKs() {
        #expect(throws: APKSigningCertificateError.notAZip) {
            _ = try APKSigningCertificates.certificates(in: Data([0x01, 0x02]))
        }
        let noBlock = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        #expect(throws: APKSigningCertificateError.noSigningBlock) {
            _ = try APKSigningCertificates.certificates(in: noBlock)
        }
    }

    @Test("Certificate files are read as DER or PEM, and folders expand to certificate files")
    func certificateFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appitool-certs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let der = fakeCertificate(oid: mlDsa65OID, filler: 0x11)
        try der.write(to: dir.appendingPathComponent("hybrid_pqc_cert.der"))
        let pem = "-----BEGIN CERTIFICATE-----\n\(fakeCertificate(oid: rsaOID, filler: 0x22).base64EncodedString())\n-----END CERTIFICATE-----\n"
        try pem.write(to: dir.appendingPathComponent("deployment_cert.pem"), atomically: true, encoding: .utf8)
        try "not a cert".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let urls = try GoogleSigningCertsCommand.certificateFiles([dir.path])
        #expect(urls.map(\.lastPathComponent) == ["deployment_cert.pem", "hybrid_pqc_cert.der"])
        #expect(try APKSigningCertificates.certificate(fromFile: urls[0]).algorithm == "RSA / SHA-256")
        #expect(try APKSigningCertificates.certificate(fromFile: urls[1]).der == der)

        #expect(throws: (any Error).self) {
            _ = try APKSigningCertificates.certificate(fromFile: dir.appendingPathComponent("notes.txt"))
        }
        #expect(GoogleSigningCertsCommand.colonHex("ABCDEF") == "AB:CD:EF")
        #expect(APKSigningCertificates.normalizeHex("ab:cd:ef") == "ABCDEF")
    }
}
