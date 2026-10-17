import Foundation
import Rainbow

extension MatchRunner {
    /// Executes Android keystore synchronization or addition using Match Git storage.
    public func runAndroid(_ config: MatchAndroidConfig) async throws -> MatchAndroidResult {
        guard !config.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatchError.missingPassword
        }

        if !config.silent {
            let modeStr = (config.action == .add) ? "Add".green.bold : "Sync".cyan.bold
            Log("🔐 [Match] Initializing Android keystore (\(config.buildType.rawValue))...".cyan.bold)
            Log("   Git Repo:    ".dim + "\(config.gitUrl)".bold)
            Log("   Branch:      ".dim + "\(config.gitBranch)")
            Log("   Package:     ".dim + "\(config.packageName)".bold)
            Log("   Build Type:  ".dim + "\(config.buildType.rawValue)")
            Log("   Mode:        ".dim + modeStr)
        }

        let storage = GitStorage(
            gitUrl: config.gitUrl,
            gitBranch: config.gitBranch,
            gitToken: config.gitToken,
            shallowClone: (config.action == .sync),
            silent: config.silent
        )

        defer {
            storage.cleanup()
        }

        // 1. Clone Git repository
        if !config.silent {
            Log("📥 [Match] Cloning keystores repository...".dim)
        }
        try await storage.download()

        // 2. Decrypt repository files
        if !config.silent {
            Log("🔓 [Match] Decrypting repository assets...".dim)
        }
        let encryption = MatchEncryption()
        try encryption.decryptDirectory(storage.workingDirectory, password: config.password)

        // 3. Dispatch action
        switch config.action {
        case .add:
            return try await importAndroidKeystore(config: config, storage: storage, encryption: encryption)
        case .sync:
            return try resolveAndroidKeystore(config: config, storage: storage)
        }
    }

    // MARK: - Import / Add Keystore

    private func importAndroidKeystore(
        config: MatchAndroidConfig,
        storage: GitStorage,
        encryption: MatchEncryption
    ) async throws -> MatchAndroidResult {
        guard let rawKeystorePath = config.keystorePath, !rawKeystorePath.isEmpty else {
            throw MatchError.missingKeystorePath
        }

        let sourcePath = NSString(string: rawKeystorePath).expandingTildeInPath
        let sourceUrl = URL(fileURLWithPath: sourcePath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceUrl.path) else {
            throw MatchError.missingKeystoreCredentials("Keystore file not found at path: \(sourceUrl.path)")
        }

        let androidDir = URL(fileURLWithPath: storage.workingDirectory)
            .appendingPathComponent("android")
            .appendingPathComponent(config.buildType.rawValue)
        try fm.createDirectory(at: androidDir, withIntermediateDirectories: true)

        let ext = sourceUrl.pathExtension.isEmpty ? "keystore" : sourceUrl.pathExtension
        let targetKeystoreUrl = androidDir.appendingPathComponent("\(config.packageName).\(ext)")

        if fm.fileExists(atPath: targetKeystoreUrl.path) {
            try fm.removeItem(at: targetKeystoreUrl)
        }
        try fm.copyItem(at: sourceUrl, to: targetKeystoreUrl)

        var filesToCommit: [String] = [targetKeystoreUrl.path]

        // Write metadata JSON if credentials are provided
        if let alias = config.alias, let storePassword = config.storePassword, let keyPassword = config.keyPassword {
            let metadata = AndroidKeystoreMetadata(
                packageName: config.packageName,
                buildType: config.buildType.rawValue,
                alias: alias,
                storePassword: storePassword,
                keyPassword: keyPassword
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(metadata)
            let targetJsonUrl = androidDir.appendingPathComponent("\(config.packageName).json")
            try data.write(to: targetJsonUrl, options: .atomic)
            filesToCommit.append(targetJsonUrl.path)
        }

        // Encrypt repository files before commit
        try encryption.encryptDirectory(storage.workingDirectory, password: config.password)

        try await storage.saveChanges(
            filesToCommit: filesToCommit,
            commitMessage: "[appitool] Added Android \(config.buildType.rawValue) keystore for \(config.packageName)"
        )

        if !config.silent {
            Log("   ✓ Keystore for '\(config.packageName)' successfully added and encrypted in Match repo!".green.bold)
        }

        return MatchAndroidResult(
            keystorePath: targetKeystoreUrl.path,
            alias: config.alias ?? "",
            storePassword: config.storePassword ?? "",
            keyPassword: config.keyPassword ?? ""
        )
    }

    // MARK: - Resolve / Sync Keystore

    private func resolveAndroidKeystore(
        config: MatchAndroidConfig,
        storage: GitStorage
    ) throws -> MatchAndroidResult {
        let androidDir = URL(fileURLWithPath: storage.workingDirectory)
            .appendingPathComponent("android")
            .appendingPathComponent(config.buildType.rawValue)

        let fm = FileManager.default
        let candidateExtensions = ["keystore", "jks", "p12"]
        var foundKeystoreUrl: URL? = nil

        for ext in candidateExtensions {
            let testUrl = androidDir.appendingPathComponent("\(config.packageName).\(ext)")
            if fm.fileExists(atPath: testUrl.path) {
                foundKeystoreUrl = testUrl
                break
            }
        }

        guard let matchedKeystoreUrl = foundKeystoreUrl else {
            let expectedPath = androidDir.appendingPathComponent("\(config.packageName).keystore").path
            throw MatchError.keystoreNotFound(
                packageName: config.packageName,
                buildType: config.buildType.rawValue,
                expectedPath: expectedPath
            )
        }

        // Read metadata JSON if present
        var metadata: AndroidKeystoreMetadata? = nil
        let jsonUrl = androidDir.appendingPathComponent("\(config.packageName).json")
        if fm.fileExists(atPath: jsonUrl.path), let data = try? Data(contentsOf: jsonUrl) {
            metadata = try? JSONDecoder().decode(AndroidKeystoreMetadata.self, from: data)
        }

        let resolvedAlias = config.alias ?? metadata?.alias
        let resolvedStorePassword = config.storePassword ?? metadata?.storePassword
        let resolvedKeyPassword = config.keyPassword ?? metadata?.keyPassword

        guard let finalAlias = resolvedAlias,
              let finalStorePassword = resolvedStorePassword,
              let finalKeyPassword = resolvedKeyPassword else {
            throw MatchError.missingKeystoreCredentials(
                "Alias and passwords for '\(config.packageName)' not found in metadata JSON or arguments."
            )
        }

        // Copy keystore to ~/.appitool/android/keystores/<packageName>.keystore because storage.cleanup() removes the working directory
        let keystoresDir = AppitoolPaths.androidKeystoresDirectory
        try fm.createDirectory(at: keystoresDir, withIntermediateDirectories: true)

        let destKeystoreUrl = AppitoolPaths.androidKeystoreFile(packageName: config.packageName)
        if fm.fileExists(atPath: destKeystoreUrl.path) {
            try? fm.removeItem(at: destKeystoreUrl)
        }
        try fm.copyItem(at: matchedKeystoreUrl, to: destKeystoreUrl)

        if !config.silent {
            Log("   ✓ Keystore for '\(config.packageName)' successfully resolved and decrypted.".green)
        }

        return MatchAndroidResult(
            keystorePath: destKeystoreUrl.path,
            alias: finalAlias,
            storePassword: finalStorePassword,
            keyPassword: finalKeyPassword,
            tempUrl: destKeystoreUrl
        )
    }
}
