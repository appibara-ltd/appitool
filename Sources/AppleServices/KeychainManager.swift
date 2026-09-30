import Foundation

/// Errors that can occur during macOS Keychain operations.
public enum KeychainManagerError: LocalizedError, Sendable {
    case executionFailed(command: String, status: Int32, output: String)
    case fileNotFound(String)
    case protectedKeychain(String)

    public var errorDescription: String? {
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
public struct KeychainManager: Sendable {
    public let keychainName: String
    public let keychainPassword: String
    public let keychainPath: String

    public init(keychainName: String = "appitool", keychainPassword: String = "") {
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
    public func prepareKeychainIfNeeded() async throws {
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
    }

    /// Deletes the keychain managed by this instance from macOS security database and cleans up remaining files from disk.
    /// Safety guard: Strictly restricted to this instance's keychainName and protects system keychains (login, System).
    public func deleteKeychain() async throws {
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
    }

    /// Checks whether the keychain file currently exists on disk.
    public var keychainExists: Bool {
        let fm = FileManager.default
        let legacyPath = keychainPath.replacingOccurrences(of: "-db", with: "")
        return fm.fileExists(atPath: keychainPath) || fm.fileExists(atPath: legacyPath)
    }

    /// Imports a `.p12` archive (PKCS#12) into the keychain, optionally including the matching `.cer`.
    ///
    /// - Parameters:
    ///   - p12Path: Path to the `.p12` file.
    ///   - password: Password protecting the `.p12` archive.
    ///   - cerPath: Optional path to the `.cer` file to import alongside the private key.
    public func importP12(p12Path: String, password: String = "", cerPath: String? = nil) async throws {
        guard FileManager.default.fileExists(atPath: p12Path) else {
            throw KeychainManagerError.fileNotFound(p12Path)
        }

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
    }

    /// Verifies if a certificate with the specified name or common identifier exists in the keychain.
    public func containsCertificate(named name: String) async -> Bool {
        let (exit, _) = (try? await runSecurity(["find-certificate", "-k", keychainPath, "-c", name])) ?? (-1, "")
        return exit == 0
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
