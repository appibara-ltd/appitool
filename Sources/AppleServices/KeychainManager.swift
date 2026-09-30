import Foundation
import Crypto
import X509

/// Information about an imported certificate and private key in the Keychain.
package struct ImportedCertificateInfo: Sendable, Equatable {
    package let id: String
    package let name: String
    package let sha1: String?
    package let cerPath: String?
    package let p12Path: String?
    package let isKeychainImported: Bool

    package init(
        id: String,
        name: String,
        sha1: String? = nil,
        cerPath: String? = nil,
        p12Path: String? = nil,
        isKeychainImported: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sha1 = sha1
        self.cerPath = cerPath
        self.p12Path = p12Path
        self.isKeychainImported = isKeychainImported
    }
}

/// Errors that can occur during macOS Keychain operations.
package enum KeychainManagerError: LocalizedError, Sendable {
    case executionFailed(command: String, status: Int32, output: String)
    case fileNotFound(String)
    case protectedKeychain(String)

    package var errorDescription: String? {
        switch self {
        case .executionFailed(let cmd, let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Keychain command '\(cmd)' failed with exit code \(status): \(trimmed)"
        case .fileNotFound(let path):
            return "File not found at path: \(path)"
        case .protectedKeychain(let msg):
            return "Protected keychain: \(msg)"
        }
    }
}

/// Manages macOS Keychain operations for Apple services, including creating the `appitool` keychain
/// and importing PKCS#12 (.p12) archives and certificates.
package struct KeychainManager: Sendable {
    package let keychainName: String
    package let keychainPassword: String
    package let keychainPath: String

    package init(keychainName: String = "appitool", keychainPassword: String = "appipass") {
        self.keychainName = keychainName
        self.keychainPassword = keychainPassword

        if keychainName.hasPrefix("/") {
            self.keychainPath = keychainName
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let sanitized = keychainName.hasSuffix(".keychain-db")
                ? String(keychainName.dropLast(".keychain-db".count))
                : (keychainName.hasSuffix(".keychain") ? String(keychainName.dropLast(".keychain".count)) : keychainName)
            self.keychainPath = URL(fileURLWithPath: home)
                .appendingPathComponent("Library")
                .appendingPathComponent("Keychains")
                .appendingPathComponent("\(sanitized).keychain-db").path
        }
    }

    /// Prepares the keychain: creates it if it doesn't exist, sets timeout, unlocks it, and adds to user keychain search list.
    package func prepareKeychainIfNeeded() async throws {
        #if !os(macOS)
        // Keychain is only supported on macOS; no-op on other platforms
        return
        #else
        let fm = FileManager.default
        let legacyPath = keychainPath.replacingOccurrences(of: "-db", with: "")

        if !fm.fileExists(atPath: keychainPath) && !fm.fileExists(atPath: legacyPath) {
            let (createExit, createOut) = try await runSecurity(["create-keychain", "-p", keychainPassword, keychainPath])
            guard createExit == 0 else {
                throw KeychainManagerError.executionFailed(command: "create-keychain", status: createExit, output: createOut)
            }

            // Set timeout settings (2 hours = 7200s)
            _ = try await runSecurity(["set-keychain-settings", "-lut", "7200", keychainPath])
        }

        // Unlock keychain
        _ = try await runSecurity(["unlock-keychain", "-p", keychainPassword, keychainPath])

        // Add to user keychain search list if not already present
        let (_, listOut) = try await runSecurity(["list-keychains", "-d", "user"])
        let existingKeychains = listOut
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        if !existingKeychains.contains(keychainPath) {
            var updated = existingKeychains
            updated.insert(keychainPath, at: 0)
            _ = try await runSecurity(["list-keychains", "-d", "user", "-s"] + updated)
        }
        #endif
    }

    /// Deletes the keychain managed by this instance from macOS security database and cleans up remaining files from disk.
    /// Safety guard: Strictly restricted to this instance's keychainName and protects system keychains (login, System).
    package func deleteKeychain() async throws {
        #if !os(macOS)
        // Keychain is only supported on macOS; no-op on other platforms
        return
        #else
        // Safety guard: prevent accidental deletion of system or login keychains
        let protectedKeychains: Set<String> = ["login", "system", "login.keychain", "login.keychain-db", "system.keychain", "system.keychain-db"]
        let normalizedName = keychainName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty,
              !protectedKeychains.contains(normalizedName),
              !keychainPath.hasSuffix("/login.keychain-db"),
              !keychainPath.hasSuffix("/login.keychain"),
              !keychainPath.hasSuffix("/System.keychain-db"),
              !keychainPath.hasSuffix("/System.keychain") else {
            throw KeychainManagerError.protectedKeychain("Refusing to delete protected system keychain '\(keychainName)'.")
        }

        // 1. Run security delete-keychain
        let (exit, out) = try await runSecurity(["delete-keychain", keychainPath])
        if exit != 0 && !out.localizedCaseInsensitiveContains("could not be found") && !out.localizedCaseInsensitiveContains("no such file") {
            let fm = FileManager.default
            let legacyPath = keychainPath.replacingOccurrences(of: "-db", with: "")
            if fm.fileExists(atPath: keychainPath) || fm.fileExists(atPath: legacyPath) {
                throw KeychainManagerError.executionFailed(command: "delete-keychain", status: exit, output: out)
            }
        }

        // 2. Remove database files from disk if any remain
        let fm = FileManager.default
        let legacyPath = keychainPath.replacingOccurrences(of: "-db", with: "")
        try? fm.removeItem(atPath: keychainPath)
        try? fm.removeItem(atPath: legacyPath)

        // 3. Remove from user keychain search list if still present
        if let (_, listOut) = try? await runSecurity(["list-keychains", "-d", "user"]) {
            let existingKeychains = listOut
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }

            if existingKeychains.contains(keychainPath) || existingKeychains.contains(legacyPath) {
                let updated = existingKeychains.filter { $0 != keychainPath && $0 != legacyPath }
                _ = try? await runSecurity(["list-keychains", "-d", "user", "-s"] + updated)
            }
        }
        #endif
    }

    /// Checks whether the keychain file currently exists on disk.
    package var keychainExists: Bool {
        #if !os(macOS)
        return false
        #else
        let fm = FileManager.default
        let legacyPath = keychainPath.replacingOccurrences(of: "-db", with: "")
        return fm.fileExists(atPath: keychainPath) || fm.fileExists(atPath: legacyPath)
        #endif
    }

    /// Imports a `.p12` archive (PKCS#12) into the keychain, optionally including the matching `.cer`.
    ///
    /// - Parameters:
    ///   - p12Path: Path to the `.p12` file.
    ///   - password: Password protecting the `.p12` archive.
    ///   - cerPath: Optional path to the `.cer` file to import alongside the private key.
    /// - Returns: An `ImportedCertificateInfo` containing certificate ID, subject summary name, SHA-1 fingerprint, and paths.
    @discardableResult
    package func importP12(p12Path: String, password: String = "", cerPath: String? = nil) async throws -> ImportedCertificateInfo {
        guard FileManager.default.fileExists(atPath: p12Path) else {
            throw KeychainManagerError.fileNotFound(p12Path)
        }

        #if !os(macOS)
        // Keychain is only supported on macOS. On Linux/other platforms, gracefully parse certificate
        // info as a no-op without running macOS /usr/bin/security commands, indicating not imported into Keychain.
        return parseCertificateInfo(p12Path: p12Path, password: password, cerPath: cerPath, isKeychainImported: false)
        #else
        // 1. Optionally import .cer
        if let cerPath, FileManager.default.fileExists(atPath: cerPath) {
            let (cerExit, cerOut) = try await runSecurity(["add-certificates", "-k", keychainPath, cerPath])
            if cerExit != 0 && !cerOut.localizedCaseInsensitiveContains("already exists") {
                _ = try await runSecurity(["import", cerPath, "-k", keychainPath, "-f", "x509", "-t", "cert"])
            }
        }

        // 2. Import .p12 with codesign / security tools allowed
        let p12Args = [
            "import", p12Path,
            "-k", keychainPath,
            "-P", password,
            "-T", "/usr/bin/codesign",
            "-T", "/usr/bin/security",
            "-T", "/usr/bin/productbuild",
            "-T", "/usr/bin/productsign"
        ]
        var (p12Exit, p12Out) = try await runSecurity(p12Args)

        // macOS security import blank-password bug (MAC verification failed)
        if p12Exit != 0 && p12Out.localizedCaseInsensitiveContains("MAC verification failed") {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            if (try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil {
                defer { try? FileManager.default.removeItem(at: tempDir) }
                let tempPem = tempDir.appendingPathComponent("temp.pem").path
                let tempP12 = tempDir.appendingPathComponent("repackaged.p12").path
                let tempPassword = UUID().uuidString

                let extractProcess = Process()
                extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                extractProcess.arguments = [
                    "pkcs12", "-in", p12Path, "-nodes", "-out", tempPem, "-passin", "pass:\(password)"
                ]
                extractProcess.standardInput = FileHandle.nullDevice
                extractProcess.standardOutput = FileHandle.nullDevice
                extractProcess.standardError = FileHandle.nullDevice
                try? extractProcess.run()
                extractProcess.waitUntilExit()

                if extractProcess.terminationStatus == 0 {
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
                        let retryArgs = [
                            "import", tempP12,
                            "-k", keychainPath,
                            "-P", tempPassword,
                            "-T", "/usr/bin/codesign",
                            "-T", "/usr/bin/security",
                            "-T", "/usr/bin/productbuild",
                            "-T", "/usr/bin/productsign"
                        ]
                        let (retryExit, retryOut) = try await runSecurity(retryArgs)
                        p12Exit = retryExit
                        p12Out = retryOut
                    }
                }
            }
        }

        if p12Exit != 0 && !p12Out.localizedCaseInsensitiveContains("already exists") {
            throw KeychainManagerError.executionFailed(command: "import", status: p12Exit, output: p12Out)
        }

        // 3. Set partition list to prevent UI prompt during codesigning
        _ = try await runSecurity([
            "set-key-partition-list",
            "-S", "apple-tool:,apple:,codesign:",
            "-s",
            "-k", keychainPassword,
            keychainPath
        ])

        // 4. Extract and return certificate info
        return parseCertificateInfo(p12Path: p12Path, password: password, cerPath: cerPath, isKeychainImported: true)
        #endif
    }

    /// Imports a `.p12` archive and optional `.cer` data directly from memory into the keychain via an ephemeral temporary file.
    /// The temporary file is immediately removed upon completion so nothing is written to user or workspace directories.
    /// On non-macOS platforms, this is a graceful no-op that parses certificate info without importing into Keychain.
    @discardableResult
    package func importP12Data(
        p12Data: Data,
        password: String = "",
        cerData: Data? = nil,
        certId: String? = nil
    ) async throws -> ImportedCertificateInfo {
        #if !os(macOS)
        // Keychain is only supported on macOS; no-op on other platforms
        return parseCertificateInfo(
            certData: cerData,
            p12Data: p12Data,
            password: password,
            fallbackId: certId,
            isKeychainImported: false
        )
        #else
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let tempP12Path = tempDir.appendingPathComponent("import.p12").path
        try p12Data.write(to: URL(fileURLWithPath: tempP12Path))

        var tempCerPath: String? = nil
        if let cerData {
            let path = tempDir.appendingPathComponent("import.cer").path
            try cerData.write(to: URL(fileURLWithPath: path))
            tempCerPath = path
        }

        let importedInfo = try await importP12(
            p12Path: tempP12Path,
            password: password,
            cerPath: tempCerPath
        )

        return parseCertificateInfo(
            certData: cerData,
            p12Data: p12Data,
            password: password,
            fallbackId: certId,
            isKeychainImported: importedInfo.isKeychainImported
        )
        #endif
    }

    private func parseCertificateInfo(
        p12Path: String? = nil,
        certData inputCertData: Data? = nil,
        p12Data: Data? = nil,
        password: String = "",
        cerPath: String? = nil,
        fallbackId: String? = nil,
        isKeychainImported: Bool = false
    ) -> ImportedCertificateInfo {
        let certId: String
        if let fallbackId, !fallbackId.isEmpty {
            certId = fallbackId
        } else if let cerPath {
            certId = URL(fileURLWithPath: cerPath).deletingPathExtension().lastPathComponent
        } else if let p12Path {
            certId = URL(fileURLWithPath: p12Path).deletingPathExtension().lastPathComponent
        } else {
            certId = "certificate"
        }

        var certData: Data? = inputCertData
        if certData == nil, let cerPath, let data = try? Data(contentsOf: URL(fileURLWithPath: cerPath)) {
            certData = data
        }

        var subjectName: String? = nil

        // 1. Primary parser: swift-certificates (cross-platform pure Swift)
        if let certData, let cert = try? Certificate(derEncoded: [UInt8](certData)) {
            for rdn in cert.subject {
                for attr in rdn {
                    if attr.type == .RDNAttributeType.commonName {
                        subjectName = String(attr.value)
                        break
                    }
                }
                if subjectName != nil { break }
            }
            if subjectName == nil {
                subjectName = cert.subject.description
            }
        }

        // 2. Fallback when cerPath is missing: extract certificate from .p12 via OpenSSL and decode with swift-certificates
        if certData == nil {
            let derProcess = Process()
            derProcess.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            if let p12Path {
                derProcess.arguments = [
                    "pkcs12", "-in", p12Path, "-clcerts", "-nokeys", "-passin", "pass:\(password)"
                ]
                derProcess.standardInput = FileHandle.nullDevice
            } else if let p12Data {
                derProcess.arguments = [
                    "pkcs12", "-clcerts", "-nokeys", "-passin", "pass:\(password)"
                ]
                let inPipe = Pipe()
                derProcess.standardInput = inPipe
                try? inPipe.fileHandleForWriting.write(contentsOf: p12Data)
                try? inPipe.fileHandleForWriting.close()
            }
            let derPipe = Pipe()
            derProcess.standardOutput = derPipe
            derProcess.standardError = FileHandle.nullDevice
            if (try? derProcess.run()) != nil {
                let outData = derPipe.fileHandleForReading.readDataToEndOfFile()
                derProcess.waitUntilExit()
                if derProcess.terminationStatus == 0, let pemString = String(data: outData, encoding: .utf8) {
                    let lines = pemString.components(separatedBy: .newlines)
                    let base64 = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
                    if let decoded = Data(base64Encoded: base64) {
                        certData = decoded
                        if let cert = try? Certificate(derEncoded: [UInt8](decoded)) {
                            for rdn in cert.subject {
                                for attr in rdn {
                                    if attr.type == .RDNAttributeType.commonName {
                                        subjectName = String(attr.value)
                                        break
                                    }
                                }
                                if subjectName != nil { break }
                            }
                            if subjectName == nil {
                                subjectName = cert.subject.description
                            }
                        }
                    }
                }
            }
        }

        let sha1Fingerprint: String?
        if let certData {
            let sha1Bytes = Insecure.SHA1.hash(data: certData)
            sha1Fingerprint = sha1Bytes.map { String(format: "%02X", $0) }.joined()
        } else {
            sha1Fingerprint = nil
        }

        return ImportedCertificateInfo(
            id: certId,
            name: subjectName ?? "Apple Certificate (\(certId))",
            sha1: sha1Fingerprint,
            cerPath: cerPath,
            p12Path: p12Path,
            isKeychainImported: isKeychainImported
        )
    }

    /// Verifies if a certificate with the specified name or common identifier exists in the keychain.
    package func containsCertificate(named name: String) async -> Bool {
        #if !os(macOS)
        return false
        #else
        let (exit, _) = (try? await runSecurity(["find-certificate", "-k", keychainPath, "-c", name])) ?? (-1, "")
        return exit == 0
        #endif
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
