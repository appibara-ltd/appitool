import Foundation
import Rainbow
import AppleServices

/// Coordinates the complete Match execution lifecycle: Git cloning, decryption,
/// Apple Developer Portal integration, Keychain certificate import, local provisioning
/// profile installation, and environment mapping.
public final class MatchRunner: Sendable {
    public init() {}

    /// Runs Match synchronization or nuke for the given configuration.
    public func run(_ config: MatchConfig) async throws -> MatchResult {
        guard !config.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatchError.missingPassword
        }

        if !config.silent {
            let modeStr = (config.action == .nuke)
                ? "Nuke".red.bold
                : (config.readonly ? "Read-Only (Sync)".yellow : "Read-Write".green)
            Log("🔐 [Match] Initializing \(config.type.rawValue)...".cyan.bold)
            Log("   Git Repo:  ".dim + "\(config.gitUrl)".bold)
            Log("   Branch:    ".dim + "\(config.gitBranch)")
            Log("   Platform:  ".dim + "\(config.platform.rawValue)")
            Log("   Mode:      ".dim + modeStr)
        }

        let storage = GitStorage(
            gitUrl: config.gitUrl,
            gitBranch: config.gitBranch,
            gitToken: config.gitToken,
            shallowClone: config.shallowClone,
            silent: config.silent
        )

        defer {
            storage.cleanup()
        }

        // 1. Clone Git repository
        if !config.silent {
            Log("📥 [Match] Cloning certificates repository...".dim)
        }
        try await storage.download()

        // 2. Decrypt repository files
        if !config.silent {
            Log("🔓 [Match] Decrypting repository assets...".dim)
        }
        let encryption = MatchEncryption()
        try encryption.decryptDirectory(storage.workingDirectory, password: config.password)

        // 3. Handle Nuke Action
        if config.action == .nuke {
            guard let keyId = config.apiKeyId, let issuerId = config.apiIssuerId, let key = config.apiKey else {
                throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required for nuke operation.")
            }
            if !config.silent {
                Log("💥 [Match] Nuking certificates and provisioning profiles for \(config.type.rawValue)...".red.bold)
            }
            let appStoreService = try AppStoreService(keyId: keyId, issuerId: issuerId, key: key)
            let (revokedCerts, deletedProfiles) = try await appStoreService.nuke(type: config.type.rawValue, platform: config.platform.rawValue)
            if !config.silent {
                Log("   Revoked \(revokedCerts.count) certificates on Apple Developer Portal".dim)
                Log("   Deleted \(deletedProfiles.count) profiles on Apple Developer Portal".dim)
            }

            // Remove files from Git repo
            let certsDir = URL(fileURLWithPath: storage.workingDirectory)
                .appendingPathComponent("certs")
                .appendingPathComponent(config.type.certDirectoryName).path
            let profilesDir = URL(fileURLWithPath: storage.workingDirectory)
                .appendingPathComponent("profiles")
                .appendingPathComponent(config.type.profileDirectoryName).path

            let fm = FileManager.default
            var filesToDelete: [String] = []
            if fm.fileExists(atPath: certsDir) {
                try? fm.removeItem(atPath: certsDir)
                filesToDelete.append(certsDir)
            }
            if fm.fileExists(atPath: profilesDir) {
                try? fm.removeItem(atPath: profilesDir)
                filesToDelete.append(profilesDir)
            }

            if !filesToDelete.isEmpty {
                // Re-encrypt remaining files before committing
                try encryption.encryptDirectory(storage.workingDirectory, password: config.password)
                try await storage.saveChanges(
                    filesToDelete: filesToDelete,
                    commitMessage: "[appitool] Nuked \(config.type.rawValue) certificates and profiles"
                )
            }

            if !config.silent {
                Log("💥 [Match] Successfully nuked \(config.type.rawValue) certificates and profiles!".red.bold)
            }
            return MatchResult()
        }

        // 4. Handle Prune Action
        if config.action == .prune {
            guard let keyId = config.apiKeyId, let issuerId = config.apiIssuerId, let key = config.apiKey else {
                throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required for prune operation.")
            }

            let typesToPrune: [MatchProfileType] = config.allTypes ? MatchProfileType.allCases : [config.type]
            let scopeDesc = config.allTypes ? "all types" : config.type.rawValue
            if !config.silent {
                Log("🧹 [Match] Pruning invalid certificates and provisioning profiles for \(scopeDesc)...".cyan.bold)
            }

            let appStoreService = try AppStoreService(keyId: keyId, issuerId: issuerId, key: key)
            let activeCertIds = try await appStoreService.fetchActiveCertificateIds(limit: 200)

            let fm = FileManager.default
            var filesToDelete: [String] = []

            for targetType in typesToPrune {
                let activeProfileUUIDs = try await appStoreService.fetchActiveProfileUUIDs(
                    platform: config.platform.rawValue,
                    type: targetType.rawValue
                )

                // 1. Prune invalid certificates in certsDir
                let certsDir = URL(fileURLWithPath: storage.workingDirectory)
                    .appendingPathComponent("certs")
                    .appendingPathComponent(targetType.certDirectoryName).path

                if let certFiles = try? fm.contentsOfDirectory(atPath: certsDir) {
                    let cerFiles = Set(certFiles.filter { ($0 as NSString).pathExtension.lowercased() == "cer" }.map { ($0 as NSString).deletingPathExtension })
                    let p12Files = Set(certFiles.filter { ($0 as NSString).pathExtension.lowercased() == "p12" }.map { ($0 as NSString).deletingPathExtension })
                    let allCandidateIds = cerFiles.union(p12Files)
                    let invalidIds = allCandidateIds.subtracting(activeCertIds)

                    for id in invalidIds {
                        let cerPath = URL(fileURLWithPath: certsDir).appendingPathComponent("\(id).cer").path
                        let p12Path = URL(fileURLWithPath: certsDir).appendingPathComponent("\(id).p12").path
                        if fm.fileExists(atPath: cerPath) {
                            try? fm.removeItem(atPath: cerPath)
                            filesToDelete.append(cerPath)
                        }
                        if fm.fileExists(atPath: p12Path) {
                            try? fm.removeItem(atPath: p12Path)
                            filesToDelete.append(p12Path)
                        }
                        if !config.silent {
                            Log("   Pruned certificate \(id) (.cer / .p12)".yellow)
                        }
                    }
                }

                // 2. Prune invalid profiles in profilesDir
                let profilesDir = URL(fileURLWithPath: storage.workingDirectory)
                    .appendingPathComponent("profiles")
                    .appendingPathComponent(targetType.profileDirectoryName).path

                if let profileFiles = try? fm.contentsOfDirectory(atPath: profilesDir) {
                    let validExtensions: Set<String> = ["mobileprovision", "provisionprofile"]
                    let prefix = "\(targetType.profilePrefix)_"
                    let installer = ProfileInstaller()

                    for file in profileFiles {
                        let ext = (file as NSString).pathExtension.lowercased()
                        guard file.hasPrefix(prefix) && validExtensions.contains(ext) else { continue }
                        let filePath = URL(fileURLWithPath: profilesDir).appendingPathComponent(file).path

                        let uuid = installer.profileUUID(atPath: filePath)
                        let isExpired = installer.isProfileExpired(atPath: filePath)
                        let isRevokedOnPortal = (uuid == nil) || !activeProfileUUIDs.contains(uuid!)

                        if isRevokedOnPortal || isExpired {
                            let profileName = installer.profileName(atPath: filePath)
                            let reason = isRevokedOnPortal ? "revoked on portal" : "expired"
                            if !config.silent {
                                Log("   Pruned profile '\(profileName)' (\(reason))".yellow)
                            }
                            try? fm.removeItem(atPath: filePath)
                            filesToDelete.append(filePath)
                        }
                    }
                }
            }

            if filesToDelete.isEmpty {
                if !config.silent {
                    Log("🟢 [Match] No invalid certificates or profiles found. Git repository is already clean!".green.bold)
                }
                return MatchResult()
            }

            // Re-encrypt remaining files before committing
            try encryption.encryptDirectory(storage.workingDirectory, password: config.password)
            try await storage.saveChanges(
                filesToDelete: filesToDelete,
                commitMessage: "[appitool] Pruned invalid code signing certificates and profiles for \(scopeDesc)"
            )

            if !config.silent {
                Log("🧹 [Match] Successfully pruned \(filesToDelete.count) invalid file(s) from Git storage!".green.bold)
            }
            return MatchResult()
        }

        // 5. Handle Sync Action
        let appStoreService: AppStoreService?
        if let keyId = config.apiKeyId, let issuerId = config.apiIssuerId, let key = config.apiKey {
            appStoreService = try AppStoreService(keyId: keyId, issuerId: issuerId, key: key)
        } else {
            appStoreService = nil
        }

        var activeCertIds: Set<String>? = nil
        var activeProfileUUIDs: Set<String>? = nil
        if let appStoreService {
            activeCertIds = try await appStoreService.fetchActiveCertificateIds(limit: 200)
            activeProfileUUIDs = try await appStoreService.fetchActiveProfileUUIDs(platform: config.platform.rawValue, type: config.type.rawValue)
        }

        var filesToCommit: [String] = []
        var filesToDelete: [String] = []

        // Discover or create certificate
        let certsDirURL = URL(fileURLWithPath: storage.workingDirectory)
            .appendingPathComponent("certs")
            .appendingPathComponent(config.type.certDirectoryName)
        let certsDir = certsDirURL.path

        let selectedCertId: String
        let selectedCerPath: String
        let selectedP12Path: String

        if let matched = findCertificatePair(
            in: certsDir,
            activeCertIds: activeCertIds,
            readonly: config.readonly,
            filesToDelete: &filesToDelete
        ) {
            selectedCertId = matched.id
            selectedCerPath = matched.cer
            selectedP12Path = matched.p12
        } else {
            if config.readonly {
                throw MatchError.certificateNotFound(type: config.type, expectedDir: certsDir)
            }
            guard let appStoreService else {
                throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required to create a new certificate.")
            }
            if !config.silent {
                Log("✨ [Match] Generating new \(config.type.rawValue) certificate on Apple Developer Portal...".yellow)
            }
            let certData: SigningCertificateData
            do {
                certData = try await appStoreService.createSigningCertificateData(
                    type: config.type.rawValue,
                    name: config.teamName,
                    p12Password: ""
                )
            } catch {
                throw MatchError.keychainError(error.localizedDescription)
            }
            try FileManager.default.createDirectory(at: certsDirURL, withIntermediateDirectories: true)
            let newCerPath = certsDirURL.appendingPathComponent("\(certData.id).cer").path
            let newP12Path = certsDirURL.appendingPathComponent("\(certData.id).p12").path
            try certData.cerData.write(to: URL(fileURLWithPath: newCerPath))
            try certData.p12Data.write(to: URL(fileURLWithPath: newP12Path))

            selectedCertId = certData.id
            selectedCerPath = newCerPath
            selectedP12Path = newP12Path
            filesToCommit.append(newCerPath)
            filesToCommit.append(newP12Path)
            if !config.silent {
                Log("🟢 [Match] Created Certificate: ".green.bold + "\(certData.id)")
            }
        }

        // Prepare Keychain and import certificate
        let keychain = AppleServices.KeychainManager(
            keychainName: (config.keychainName?.isEmpty == false) ? config.keychainName! : "appitool",
            keychainPassword: (config.keychainPassword?.isEmpty == false) ? config.keychainPassword! : "appipass"
        )
        do {
            try await keychain.prepareKeychainIfNeeded()
        } catch {
            throw MatchError.keychainError(error.localizedDescription)
        }

        if !config.silent {
            Log("🔑 [Match] Installing certificate into Keychain...".dim)
        }
        let imported: ImportedCertificateInfo
        do {
            imported = try await keychain.importP12(
                p12Path: selectedP12Path,
                password: "",
                cerPath: selectedCerPath
            )
        } catch {
            throw MatchError.keychainError(error.localizedDescription)
        }

        let certInfo = MatchCertificateInfo(
            id: imported.id,
            name: imported.name,
            sha1: imported.sha1,
            cerPath: selectedCerPath,
            p12Path: selectedP12Path
        )
        if !config.silent {
            Log("🟢 [Match] Installed Certificate: ".green.bold + "\(certInfo.name)".bold + " [Cert: \(selectedCertId)]".dim)
        }

        // Discover and install provisioning profiles
        let profilesDirURL = URL(fileURLWithPath: storage.workingDirectory)
            .appendingPathComponent("profiles")
            .appendingPathComponent(config.type.profileDirectoryName)
        let profilesDir = profilesDirURL.path

        let installer = ProfileInstaller()
        var installedProfiles: [String: MatchProfileInfo] = [:]
        var envVariables: [String: String] = [:]

        let targetIdentifiers: [String]
        if config.appIdentifiers.isEmpty {
            targetIdentifiers = discoverAllProfileBundleIds(in: profilesDir, type: config.type)
        } else {
            targetIdentifiers = config.appIdentifiers
        }

        // Discover and prune invalid provisioning profiles if portal API is available
        if let activeProfileUUIDs {
            pruneInvalidProfiles(
                in: profilesDir,
                type: config.type,
                platform: config.platform,
                activeProfileUUIDs: activeProfileUUIDs,
                selectedCerPath: selectedCerPath,
                targetIdentifiers: targetIdentifiers,
                readonly: config.readonly,
                silent: config.silent,
                filesToDelete: &filesToDelete
            )
        }

        for bundleId in targetIdentifiers {
            var profilePath = findProfileFile(in: profilesDir, type: config.type, platform: config.platform, bundleId: bundleId)
            let needsCreation: Bool

            if let existing = profilePath {
                let isExpired = installer.isProfileExpired(atPath: existing)
                let certData = try? Data(contentsOf: URL(fileURLWithPath: selectedCerPath))
                let hasCert = (certData != nil) && installer.profileContainsCertificate(atPath: existing, certificateData: certData!)
                let profileName = installer.profileName(atPath: existing)
                let profileUUID = installer.profileUUID(atPath: existing)

                let isRevokedOnPortal: Bool
                if let activeProfileUUIDs, let profileUUID {
                    isRevokedOnPortal = !activeProfileUUIDs.contains(profileUUID)
                } else {
                    isRevokedOnPortal = false
                }

                if isRevokedOnPortal && !config.silent {
                    Log("🚧 [Match] Profile '\(profileName)' is revoked or invalid on Apple Developer Portal.".yellow)
                }

                if (!hasCert || isRevokedOnPortal) && config.readonly {
                    if !hasCert {
                        throw MatchError.profileCertificateMismatch(
                            bundleId: bundleId,
                            profileName: profileName,
                            certificateId: selectedCertId
                        )
                    } else {
                        throw MatchError.profileRevokedOnPortal(
                            bundleId: bundleId,
                            profileName: profileName
                        )
                    }
                }

                if hasCert && !isRevokedOnPortal && !config.silent {
                    Log("🔍 [Match] Verified profile '\(profileName)' matches certificate (\(selectedCertId))".dim)
                }

                needsCreation = (config.force || isExpired || !hasCert || isRevokedOnPortal) && !config.readonly
            } else {
                needsCreation = !config.readonly
            }

            if needsCreation {
                guard let appStoreService else {
                    throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required to create provisioning profiles.")
                }
                if !config.silent {
                    Log("✨ [Match] Generating new profile for \(bundleId) on Apple Developer Portal...".yellow)
                }
                let result: CreateProfileResult
                do {
                    result = try await appStoreService.createProvisioningProfile(
                        bundleId: bundleId,
                        type: config.type.rawValue,
                        platform: config.platform.rawValue,
                        certificateId: selectedCertId
                    )
                } catch {
                    throw MatchError.profileParsingFailed(error.localizedDescription)
                }
                try FileManager.default.createDirectory(at: profilesDirURL, withIntermediateDirectories: true)
                let newFileName = config.type.profileFileName(bundleId: bundleId, platform: config.platform)
                let newPath = profilesDirURL.appendingPathComponent(newFileName).path
                try result.profile.profileData.write(to: URL(fileURLWithPath: newPath))
                if let existing = profilePath, existing != newPath {
                    if FileManager.default.fileExists(atPath: existing) {
                        try? FileManager.default.removeItem(atPath: existing)
                        filesToDelete.append(existing)
                    }
                }
                profilePath = newPath
                filesToCommit.append(newPath)
            }

            guard let finalPath = profilePath else {
                throw MatchError.profileNotFound(bundleId: bundleId, type: config.type, expectedPath: profilesDir)
            }

            let profileInfo = try installer.installProfile(from: finalPath, expectedBundleId: bundleId)
            installedProfiles[bundleId] = profileInfo

            if !config.silent {
                Log("🟢 [Match] Installed Profile: ".green.bold + "\(profileInfo.name)".bold + " (\(bundleId))".dim)
            }

            let normalizedType = config.type.rawValue
            envVariables["sigh_\(bundleId)_\(normalizedType)"] = profileInfo.uuid
            envVariables["sigh_\(bundleId)_\(normalizedType)_uuid"] = profileInfo.uuid
            envVariables["sigh_\(bundleId)_\(normalizedType)_profile-path"] = profileInfo.path
            envVariables["sigh_\(bundleId)_\(normalizedType)_profile-name"] = profileInfo.name
            if let team = profileInfo.teamId ?? config.teamId {
                envVariables["sigh_\(bundleId)_\(normalizedType)_team-id"] = team
            }
        }

        // Encrypt and commit changes if assets were modified or cleaned up
        let hasChanges = (!filesToCommit.isEmpty || !filesToDelete.isEmpty) && !config.readonly
        if hasChanges {
            if !config.silent {
                if !filesToDelete.isEmpty {
                    Log("🧹 [Match] Cleaning up \(filesToDelete.count) invalid file(s)...".yellow)
                }
                if !filesToCommit.isEmpty {
                    Log("🔒 [Match] Encrypting updated assets...".dim)
                }
            }
            try encryption.encryptDirectory(storage.workingDirectory, password: config.password)
            if !config.silent {
                Log("📤 [Match] Pushing updated certificates and profiles to Git remote...".dim)
            }
            try await storage.saveChanges(
                filesToCommit: filesToCommit,
                filesToDelete: filesToDelete,
                commitMessage: "[appitool] Updated code signing certificates and profiles for \(config.type.rawValue)"
            )
        }

        if !config.silent {
            Log("🎉 [Match] Successfully synchronized all certificates and profiles!".green.bold)
        }

        return MatchResult(
            installedCertificates: [certInfo],
            installedProfiles: installedProfiles,
            envVariables: envVariables
        )
    }

    // MARK: - Private Helpers

    private func findCertificatePair(
        in directory: String,
        activeCertIds: Set<String>? = nil,
        readonly: Bool = false,
        filesToDelete: inout [String]
    ) -> (id: String, cer: String, p12: String)? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        let cerFiles = Set(files.filter { ($0 as NSString).pathExtension.lowercased() == "cer" }.map { ($0 as NSString).deletingPathExtension })
        let p12Files = Set(files.filter { ($0 as NSString).pathExtension.lowercased() == "p12" }.map { ($0 as NSString).deletingPathExtension })

        var commonIds = cerFiles.intersection(p12Files)
        if let activeCertIds {
            let allCandidateIds = cerFiles.union(p12Files)
            let invalidIds = allCandidateIds.subtracting(activeCertIds)

            if !readonly && !invalidIds.isEmpty {
                for id in invalidIds {
                    let cerPath = URL(fileURLWithPath: directory).appendingPathComponent("\(id).cer").path
                    let p12Path = URL(fileURLWithPath: directory).appendingPathComponent("\(id).p12").path
                    if fm.fileExists(atPath: cerPath) {
                        try? fm.removeItem(atPath: cerPath)
                        filesToDelete.append(cerPath)
                    }
                    if fm.fileExists(atPath: p12Path) {
                        try? fm.removeItem(atPath: p12Path)
                        filesToDelete.append(p12Path)
                    }
                }
            }
            commonIds = commonIds.intersection(activeCertIds)
        }
        guard !commonIds.isEmpty else { return nil }

        // Sort by file modification date descending so the newest/active certificate is always selected
        let sortedIds = commonIds.sorted { id1, id2 in
            let path1 = URL(fileURLWithPath: directory).appendingPathComponent("\(id1).cer")
            let path2 = URL(fileURLWithPath: directory).appendingPathComponent("\(id2).cer")
            let date1 = (try? path1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let date2 = (try? path2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return date1 > date2
        }

        guard let selectedId = sortedIds.first else { return nil }
        let cerPath = URL(fileURLWithPath: directory).appendingPathComponent("\(selectedId).cer").path
        let p12Path = URL(fileURLWithPath: directory).appendingPathComponent("\(selectedId).p12").path
        return (selectedId, cerPath, p12Path)
    }

    private func discoverAllProfileBundleIds(in directory: String, type: MatchProfileType) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        let prefix = "\(type.profilePrefix)_"
        var bundleIds: [String] = []

        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            if file.hasPrefix(prefix) && (ext == "mobileprovision" || ext == "provisionprofile") {
                let strippedPrefix = String(file.dropFirst(prefix.count))
                let bundleId = (strippedPrefix as NSString).deletingPathExtension
                if !bundleId.isEmpty {
                    bundleIds.append(bundleId)
                }
            }
        }
        return bundleIds
    }

    private func pruneInvalidProfiles(
        in directory: String,
        type: MatchProfileType,
        platform: MatchPlatform,
        activeProfileUUIDs: Set<String>,
        selectedCerPath: String,
        targetIdentifiers: [String],
        readonly: Bool,
        silent: Bool,
        filesToDelete: inout [String]
    ) {
        guard !readonly else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return }

        let validExtensions: Set<String> = ["mobileprovision", "provisionprofile"]
        let prefix = "\(type.profilePrefix)_"
        let installer = ProfileInstaller()
        let certData = try? Data(contentsOf: URL(fileURLWithPath: selectedCerPath))
        let targetSet = Set(targetIdentifiers)

        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard file.hasPrefix(prefix) && validExtensions.contains(ext) else { continue }
            let filePath = URL(fileURLWithPath: directory).appendingPathComponent(file).path

            let uuid = installer.profileUUID(atPath: filePath)
            let isExpired = installer.isProfileExpired(atPath: filePath)
            let isRevokedOnPortal = (uuid == nil) || !activeProfileUUIDs.contains(uuid!)
            let hasCert = (certData != nil) && installer.profileContainsCertificate(atPath: filePath, certificateData: certData!)

            let isInvalid = isRevokedOnPortal || isExpired || !hasCert
            guard isInvalid else { continue }

            // Extract bundle ID
            var pattern = String((file as NSString).deletingPathExtension.dropFirst(prefix.count))
            if !platform.profileFilenameSuffix.isEmpty && pattern.hasSuffix(platform.profileFilenameSuffix) {
                pattern = String(pattern.dropLast(platform.profileFilenameSuffix.count))
            }
            let fileBundleId = pattern

            let willBeRenewed = targetSet.contains(fileBundleId)
            let standardFileName = type.profileFileName(bundleId: fileBundleId, platform: platform)
            let standardPath = URL(fileURLWithPath: directory).appendingPathComponent(standardFileName).path

            // If it won't be renewed in the current run, or its filename doesn't match standardPath (so it won't be overwritten), delete it.
            if !willBeRenewed || filePath != standardPath {
                let profileName = installer.profileName(atPath: filePath)
                if !silent {
                    let reason = isRevokedOnPortal ? "revoked on portal" : (isExpired ? "expired" : "certificate mismatch")
                    Log("🧹 [Match] Pruning invalid profile '\(profileName)' (\(reason))...".yellow)
                }
                try? fm.removeItem(atPath: filePath)
                filesToDelete.append(filePath)
            }
        }
    }

    private func findProfileFile(in directory: String, type: MatchProfileType, platform: MatchPlatform, bundleId: String) -> String? {
        let fm = FileManager.default
        let exactName = type.profileFileName(bundleId: bundleId, platform: platform)
        let exactPath = URL(fileURLWithPath: directory).appendingPathComponent(exactName).path
        if fm.fileExists(atPath: exactPath) {
            return exactPath
        }

        let prefix = "\(type.profilePrefix)_"
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        let validExtensions: Set<String> = ["mobileprovision", "provisionprofile"]

        // Search for matching wildcard or legacy pattern
        var candidateWildcards: [(path: String, specificity: Int)] = []

        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard file.hasPrefix(prefix) && validExtensions.contains(ext) else { continue }

            var pattern = String((file as NSString).deletingPathExtension.dropFirst(prefix.count))
            if !platform.profileFilenameSuffix.isEmpty && pattern.hasSuffix(platform.profileFilenameSuffix) {
                pattern = String(pattern.dropLast(platform.profileFilenameSuffix.count))
            }

            let fullPath = URL(fileURLWithPath: directory).appendingPathComponent(file).path

            if pattern == bundleId {
                return fullPath
            } else if pattern == "*" {
                candidateWildcards.append((fullPath, 0))
            } else if pattern.hasSuffix(".*") {
                let prefixPattern = String(pattern.dropLast(1)) // e.g. "com.example."
                if bundleId.hasPrefix(prefixPattern) {
                    candidateWildcards.append((fullPath, prefixPattern.count))
                }
            }
        }

        // Pick most specific wildcard match if available
        if let best = candidateWildcards.sorted(by: { $0.specificity > $1.specificity }).first {
            return best.path
        }

        return nil
    }
}
