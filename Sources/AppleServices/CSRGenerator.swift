import Foundation
import Crypto
import CryptoExtras
import X509

package struct CSRGenerator {

    package struct CSRResult {
        /// PEM-encoded RSA private key (PKCS#8)
        package let privateKeyPEM: String
        /// PEM-encoded PKCS#10 Certificate Signing Request
        package let csrPEM: String
    }

    package static func generate(commonName: String) throws -> CSRResult {
        // 1. RSA 2048-bit private key
        let rsaKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let privateKeyPEM = rsaKey.pemRepresentation

        // 2. Subject
        let subject = try DistinguishedName {
            CommonName(commonName)
        }

        // 3. CSR
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: subject,
            privateKey: Certificate.PrivateKey(rsaKey),
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha256WithRSAEncryption
        )

        let csrPEM = try csr.serializeAsPEM().pemString

        return CSRResult(privateKeyPEM: privateKeyPEM, csrPEM: csrPEM)
    }
}
