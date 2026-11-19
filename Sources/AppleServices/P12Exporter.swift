import Foundation
import Subprocess
import X509

/// Errors that can occur during PKCS#12 (.p12) archiving.
package enum P12ExporterError: LocalizedError, Sendable {
    case conversionFailed(String)
    case exportFailed(String)
    case fileReadError(String)

    package var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg):
            return "Failed to convert DER certificate to PEM: \(msg)"
        case .exportFailed(let msg):
            return "Failed to export PKCS#12 archive: \(msg)"
        case .fileReadError(let msg):
            return "Failed to read exported PKCS#12 file: \(msg)"
        }
    }
}

/// Utility for packaging X.509 DER certificates and private keys into PKCS#12 (.p12) archives.
package struct P12Exporter: Sendable {

    /// Exports a `.cer` (DER format) and private key (PEM format) into PKCS#12 (`.p12`) archive bytes.
    ///
    /// - Parameters:
    ///   - cerData: The DER-encoded X.509 certificate data.
    ///   - privateKeyPEM: The PEM-encoded private key string (PKCS#8 or PKCS#1).
    ///   - password: The password to encrypt the `.p12` archive (defaults to empty string for passwordless).
    /// - Returns: The generated `.p12` data.
    package static func export(
        cerData: Data,
        privateKeyPEM: String,
        password: String = ""
    ) async throws -> Data {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pemCertPath = tempDir.appendingPathComponent("cert.pem").path
        let keyPath = tempDir.appendingPathComponent("private_key.pem").path
        let p12Path = tempDir.appendingPathComponent("cert.p12").path

        // 1. Write private key PEM
        try Data(privateKeyPEM.utf8).write(to: URL(fileURLWithPath: keyPath))

        // 2. Obtain PEM-encoded certificate (attempt swift-certificates first, fallback to openssl)
        var pemString: String? = nil
        if let cert = try? Certificate(derEncoded: [UInt8](cerData)),
           let pem = try? cert.serializeAsPEM().pemString {
            pemString = pem
        }

        if let pemString {
            try Data(pemString.utf8).write(to: URL(fileURLWithPath: pemCertPath))
        } else {
            let cerPath = tempDir.appendingPathComponent("cert.cer").path
            try cerData.write(to: URL(fileURLWithPath: cerPath))

            let x509Result = try await Subprocess.run(
                .path("/usr/bin/openssl"),
                arguments: ["x509", "-inform", "DER", "-in", cerPath, "-out", pemCertPath],
                input: .none,
                output: .discarded,
                error: .string(limit: 10 * 1024 * 1024)
            )
            guard x509Result.terminationStatus.isSuccess else {
                let err = x509Result.standardError
                throw P12ExporterError.conversionFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // 3. Export .p12 using OpenSSL
        let p12Result = try await Subprocess.run(
            .path("/usr/bin/openssl"),
            arguments: [
                "pkcs12", "-export",
                "-inkey", keyPath,
                "-in", pemCertPath,
                "-out", p12Path,
                "-passout", "pass:\(password)"
            ],
            input: .none,
            output: .discarded,
            error: .string(limit: 10 * 1024 * 1024)
        )
        guard p12Result.terminationStatus.isSuccess else {
            let err = p12Result.standardError
            throw P12ExporterError.exportFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
            throw P12ExporterError.fileReadError("Could not read exported .p12 file at \(p12Path)")
        }

        return p12Data
    }

    /// Exports a `.cer` and private key directly to a target `.p12` file destination.
    ///
    /// - Parameters:
    ///   - cerData: The DER-encoded X.509 certificate data.
    ///   - privateKeyPEM: The PEM-encoded private key string.
    ///   - destinationURL: Destination file URL for the `.p12` file.
    ///   - password: The password to encrypt the `.p12` archive (defaults to empty string for passwordless).
    package static func export(
        cerData: Data,
        privateKeyPEM: String,
        to destinationURL: URL,
        password: String = ""
    ) async throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let p12Data = try await export(cerData: cerData, privateKeyPEM: privateKeyPEM, password: password)
        try p12Data.write(to: destinationURL)
    }

    /// Exports an existing `.cer` file and private key file directly to a target `.p12` file destination.
    ///
    /// - Parameters:
    ///   - cerPath: Path to the `.cer` file.
    ///   - keyPath: Path to the private key `.pem` file.
    ///   - destinationURL: Destination file URL for the `.p12` file.
    ///   - password: The password to encrypt the `.p12` archive (defaults to empty string for passwordless).
    package static func export(
        cerPath: String,
        keyPath: String,
        to destinationURL: URL,
        password: String = ""
    ) async throws {
        guard let cerData = try? Data(contentsOf: URL(fileURLWithPath: cerPath)) else {
            throw P12ExporterError.fileReadError("Failed to read certificate at \(cerPath)")
        }
        guard let keyPEM = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            throw P12ExporterError.fileReadError("Failed to read private key at \(keyPath)")
        }
        try await export(cerData: cerData, privateKeyPEM: keyPEM, to: destinationURL, password: password)
    }
}
