import Foundation
import Security
import Crypto

/// Manages macOS Keychain operations for Match, including certificate/private key import
/// and security partition list configuration for headless CI builds.
public final class KeychainManager: Sendable {
    public let keychainPath: String?
    private let keychainPassword: String?

    public init(keychainName: String? = nil, keychainPassword: String? = nil) {
        let name = (keychainName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? keychainName!
            : "appitool"

        self.keychainPassword = keychainPassword ?? ""

        if name.hasPrefix("/") {
            self.keychainPath = name
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let sanitizedName = name.hasSuffix(".keychain-db")
                ? String(name.dropLast(".keychain-db".count))
                : (name.hasSuffix(".keychain") ? String(name.dropLast(".keychain".count)) : name)
            self.keychainPath = URL(fileURLWithPath: home)
                .appendingPathComponent("Library")
                .appendingPathComponent("Keychains")
                .appendingPathComponent("\(sanitizedName).keychain-db").path
        }
    }

    /// Prepares custom keychain if specified (creates and unlocks it).
    public func prepareKeychainIfNeeded() async throws {
        guard let path = keychainPath else { return }

        let fm = FileManager.default
        let pwd = keychainPassword ?? ""

        if !fm.fileExists(atPath: path) && !fm.fileExists(atPath: path.replacingOccurrences(of: "-db", with: "")) {
            // Create keychain
            let (createExit, createOut) = try await runSecurity(["create-keychain", "-p", pwd, path])
            guard createExit == 0 else {
                throw MatchError.keychainError("Failed to create keychain at '\(path)': \(createOut)")
            }

            // Set timeout settings (2 hours)
            _ = try await runSecurity(["set-keychain-settings", "-lut", "7200", path])
        }

        // Unlock keychain
        let (unlockExit, unlockOut) = try await runSecurity(["unlock-keychain", "-p", pwd, path])
        if unlockExit != 0 && !unlockOut.isEmpty {
            // Non-fatal if already unlocked, but log if error
        }

        // Add to user keychain search list
        let (_, listOut) = try await runSecurity(["list-keychains", "-d", "user"])
        let existingKeychains = listOut
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        if !existingKeychains.contains(path) {
            var updated = existingKeychains
            updated.insert(path, at: 0)
            _ = try await runSecurity(["list-keychains", "-d", "user", "-s"] + updated)
        }
    }

    /// Imports certificate (`.cer`) and private key (`.p12`) into the keychain.
    public func importCertificate(cerPath: String, p12Path: String, p12Password: String = "") async throws -> MatchCertificateInfo {
        let targetKeychainArgs: [String]
        if let path = keychainPath {
            targetKeychainArgs = ["-k", path]
        } else {
            targetKeychainArgs = []
        }

        // 1. Import .cer using add-certificates (standard macOS command for X.509 certs)
        let cerArgs: [String]
        if let path = keychainPath {
            cerArgs = ["add-certificates", "-k", path, cerPath]
        } else {
            cerArgs = ["add-certificates", cerPath]
        }
        let (cerExit, cerOut) = try await runSecurity(cerArgs)
        if cerExit != 0 && !cerOut.localizedCaseInsensitiveContains("already exists") {
            // Fallback to security import with explicit format and type flags
            let fallbackArgs = ["import", cerPath] + targetKeychainArgs + ["-f", "x509", "-t", "cert"]
            let (fbExit, fbOut) = try await runSecurity(fallbackArgs)
            if fbExit != 0 && !fbOut.localizedCaseInsensitiveContains("already exists") {
                throw MatchError.keychainError("Failed to import certificate '\(cerPath)': \(cerOut)\n\(fbOut)")
            }
        }

        // 2. Import .p12 (PKCS#12 bundle containing private key)
        let p12Args = ["import", p12Path] + targetKeychainArgs + ["-P", p12Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild", "-T", "/usr/bin/productsign"]
        let (p12Exit, p12Out) = try await runSecurity(p12Args)
        var finalP12Exit = p12Exit
        var finalP12Out = p12Out

        if finalP12Exit != 0 && finalP12Out.localizedCaseInsensitiveContains("MAC verification failed") {
            // macOS `security import` command has a known bug/incompatibility with blank-password PKCS#12 files.
            // Repackage the .p12 with a temporary non-empty password, import it into Keychain, and clean up.
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            if (try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil {
                defer { try? FileManager.default.removeItem(at: tempDir) }
                let tempPem = tempDir.appendingPathComponent("temp.pem").path
                let tempP12 = tempDir.appendingPathComponent("repackaged.p12").path
                let tempPassword = UUID().uuidString

                // 1. Extract .p12 to PEM (OpenSSL verifies the existing password, even if blank)
                let extractProcess = Process()
                extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                extractProcess.arguments = [
                    "pkcs12", "-in", p12Path, "-nodes", "-out", tempPem, "-passin", "pass:\(p12Password)"
                ]
                extractProcess.standardInput = FileHandle.nullDevice
                extractProcess.standardOutput = FileHandle.nullDevice
                extractProcess.standardError = FileHandle.nullDevice
                try? extractProcess.run()
                extractProcess.waitUntilExit()

                if extractProcess.terminationStatus == 0 {
                    // 2. Export with temporary non-empty password
                    let repackageProcess = Process()
                    repackageProcess.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                    repackageProcess.arguments = [
                        "pkcs12", "-export", "-in", tempPem, "-out", tempP12, "-passout", "pass:\(tempPassword)"
                    ]
                    repackageProcess.standardInput = FileHandle.nullDevice
                    repackageProcess.standardOutput = FileHandle.nullDevice
                    repackageProcess.standardError = FileHandle.nullDevice
                    try? repackageProcess.run()
                    repackageProcess.waitUntilExit()

                    if repackageProcess.terminationStatus == 0 {
                        // 3. Import temporary .p12 with the temporary password
                        let retryArgs = ["import", tempP12] + targetKeychainArgs + ["-P", tempPassword, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild", "-T", "/usr/bin/productsign"]
                        let (retryExit, retryOut) = try await runSecurity(retryArgs)
                        finalP12Exit = retryExit
                        finalP12Out = retryOut
                    }
                }
            }
        }

        if finalP12Exit != 0 && !finalP12Out.localizedCaseInsensitiveContains("already exists") {
            throw MatchError.keychainError("Failed to import private key '\(p12Path)': \(finalP12Out)")
        }

        // 3. Set partition list to prevent UI prompts during codesigning
        let effectiveKeychain: String?
        if let keychainPath {
            effectiveKeychain = keychainPath
        } else {
            effectiveKeychain = await resolveDefaultKeychain()
        }
        if let pwd = keychainPassword, let path = effectiveKeychain {
            _ = try await runSecurity([
                "set-key-partition-list",
                "-S", "apple-tool:,apple:,codesign:",
                "-s",
                "-k", pwd,
                path
            ])
        }

        // 4. Extract certificate information natively
        let certInfo = try parseCertificateInfo(cerPath: cerPath, p12Path: p12Path)
        return certInfo
    }

    // MARK: - Private Helpers

    private func parseCertificateInfo(cerPath: String, p12Path: String) throws -> MatchCertificateInfo {
        let certId = URL(fileURLWithPath: cerPath).deletingPathExtension().lastPathComponent
        guard let certData = try? Data(contentsOf: URL(fileURLWithPath: cerPath)) else {
            return MatchCertificateInfo(
                id: certId,
                name: "Apple Certificate (\(certId))",
                sha1: nil,
                cerPath: cerPath,
                p12Path: p12Path
            )
        }

        var subjectName = "Apple Certificate (\(certId))"
        if let secCert = SecCertificateCreateWithData(nil, certData as CFData),
           let summary = SecCertificateCopySubjectSummary(secCert) as String? {
            subjectName = summary
        }

        let sha1Bytes = Insecure.SHA1.hash(data: certData)
        let sha1Fingerprint = sha1Bytes.map { String(format: "%02X", $0) }.joined()

        return MatchCertificateInfo(
            id: certId,
            name: subjectName,
            sha1: sha1Fingerprint,
            cerPath: cerPath,
            p12Path: p12Path
        )
    }

    private func resolveDefaultKeychain() async -> String? {
        let (exit, out) = (try? await runSecurity(["default-keychain"])) ?? (-1, "")
        if exit == 0 {
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    private func runSecurity(_ args: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
