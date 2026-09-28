import Foundation
import Rainbow

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
            print("🔐 [Match] Initializing \(config.type.rawValue)...".cyan.bold)
            print("   Git Repo:  ".dim + "\(config.gitUrl)".bold)
            print("   Branch:    ".dim + "\(config.gitBranch)")
            print("   Platform:  ".dim + "\(config.platform.rawValue)")
            print("   Mode:      ".dim + modeStr)
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
            print("📥 [Match] Cloning certificates repository...".dim)
        }
        try await storage.download()

        // 2. Decrypt repository files
        if !config.silent {
            print("🔓 [Match] Decrypting repository assets...".dim)
        }
        let encryption = MatchEncryption()
        try encryption.decryptDirectory(storage.workingDirectory, password: config.password)

        // 3. Handle Nuke Action
        if config.action == .nuke {
            guard let keyId = config.apiKeyId, let issuerId = config.apiIssuerId, let key = config.apiKey else {
                throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required for nuke operation.")
            }
            if !config.silent {
                print("💥 [Match] Nuking certificates and provisioning profiles for \(config.type.rawValue)...".red.bold)
            }
            let portal = try ApplePortalService(keyId: keyId, issuerId: issuerId, key: key)
            let (revokedCerts, deletedProfiles) = try await portal.nuke(type: config.type, platform: config.platform)
            if !config.silent {
                print("   Revoked \(revokedCerts.count) certificates on Apple Developer Portal".dim)
                print("   Deleted \(deletedProfiles.count) profiles on Apple Developer Portal".dim)
            }

            // Remove files from Git repo
            let certsDir = URL(fileURLWithPath: storage.workingDirectory)
                .appendingPathComponent("certs")
                .appendingPathComponent(config.type.certDirectoryName).path
            let profilesDir = URL(fileURLWithPath: storage.workingDirectory)
                .appendingPathComponent("profiles")
                .appendingPathComponent(config.type.profileDirectoryName).path

            let fm = FileManager.default
            var deletedAny = false
            if fm.fileExists(atPath: certsDir) {
                try? fm.removeItem(atPath: certsDir)
                deletedAny = true
            }
            if fm.fileExists(atPath: profilesDir) {
                try? fm.removeItem(atPath: profilesDir)
                deletedAny = true
            }

            if deletedAny {
                // Re-encrypt remaining files before committing
                try encryption.encryptDirectory(storage.workingDirectory, password: config.password)
                try await storage.saveChanges(commitMessage: "[appitool] Nuked \(config.type.rawValue) certificates and profiles")
            }

            if !config.silent {
                print("💥 [Match] Successfully nuked \(config.type.rawValue) certificates and profiles!".red.bold)
            }
            return MatchResult()
        }

        // 4. Handle Sync Action
        let portal: ApplePortalService?
        if let keyId = config.apiKeyId, let issuerId = config.apiIssuerId, let key = config.apiKey {
            portal = try ApplePortalService(keyId: keyId, issuerId: issuerId, key: key)
        } else {
            portal = nil
        }

        var activeCertIds: Set<String>? = nil
        var activeProfileUUIDs: Set<String>? = nil
        if let portal {
            activeCertIds = try await portal.fetchActiveCertificateIds(for: config.type)
            activeProfileUUIDs = try await portal.fetchActiveProfileUUIDs(for: config.type, platform: config.platform)
        }

        var hasNewAssets = false

        // Discover or create certificate
        let certsDirURL = URL(fileURLWithPath: storage.workingDirectory)
            .appendingPathComponent("certs")
            .appendingPathComponent(config.type.certDirectoryName)
        let certsDir = certsDirURL.path

        let selectedCertId: String
        let selectedCerPath: String
        let selectedP12Path: String

        if let matched = findCertificatePair(in: certsDir, activeCertIds: activeCertIds) {
            selectedCertId = matched.id
            selectedCerPath = matched.cer
            selectedP12Path = matched.p12
        } else {
            if config.readonly {
                throw MatchError.certificateNotFound(type: config.type, expectedDir: certsDir)
            }
            guard let portal else {
                throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required to create a new certificate.")
            }
            if !config.silent {
                print("✨ [Match] Generating new \(config.type.rawValue) certificate on Apple Developer Portal...".yellow)
            }
            let (newCertId, cerData, p12Data) = try await portal.createCertificate(type: config.type, teamName: config.teamName)
            try FileManager.default.createDirectory(at: certsDirURL, withIntermediateDirectories: true)
            let newCerPath = certsDirURL.appendingPathComponent("\(newCertId).cer").path
            let newP12Path = certsDirURL.appendingPathComponent("\(newCertId).p12").path
            try cerData.write(to: URL(fileURLWithPath: newCerPath))
            try p12Data.write(to: URL(fileURLWithPath: newP12Path))

            selectedCertId = newCertId
            selectedCerPath = newCerPath
            selectedP12Path = newP12Path
            hasNewAssets = true
            if !config.silent {
                print("✓ [Match] Created Certificate: ".green.bold + "\(newCertId)")
            }
        }

        // Prepare Keychain and import certificate
        let keychain = KeychainManager(
            keychainName: config.keychainName,
            keychainPassword: config.keychainPassword
        )
        try await keychain.prepareKeychainIfNeeded()

        if !config.silent {
            print("🔑 [Match] Installing certificate into Keychain...".dim)
        }
        let certInfo = try await keychain.importCertificate(cerPath: selectedCerPath, p12Path: selectedP12Path)
        if !config.silent {
            print("✓ [Match] Installed Certificate: ".green.bold + "\(certInfo.name)".bold + " [Cert: \(selectedCertId)]".dim)
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
                    print("⚠️ [Match] Profile '\(profileName)' is revoked or invalid on Apple Developer Portal.".yellow)
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
                    print("🔍 [Match] Verified profile '\(profileName)' matches certificate (\(selectedCertId))".dim)
                }

                needsCreation = (config.force || isExpired || !hasCert || isRevokedOnPortal) && !config.readonly
            } else {
                needsCreation = !config.readonly
            }

            if needsCreation {
                guard let portal else {
                    throw MatchError.portalAuthenticationRequired("App Store Connect API credentials are required to create provisioning profiles.")
                }
                if !config.silent {
                    print("✨ [Match] Generating new profile for \(bundleId) on Apple Developer Portal...".yellow)
                }
                let (_, _, profileData) = try await portal.createProfile(
                    type: config.type,
                    platform: config.platform,
                    bundleId: bundleId,
                    certificateId: selectedCertId
                )
                try FileManager.default.createDirectory(at: profilesDirURL, withIntermediateDirectories: true)
                let newFileName = config.type.profileFileName(bundleId: bundleId, platform: config.platform)
                let newPath = profilesDirURL.appendingPathComponent(newFileName).path
                try profileData.write(to: URL(fileURLWithPath: newPath))
                profilePath = newPath
                hasNewAssets = true
            }

            guard let finalPath = profilePath else {
                throw MatchError.profileNotFound(bundleId: bundleId, type: config.type, expectedPath: profilesDir)
            }

            let profileInfo = try installer.installProfile(from: finalPath, expectedBundleId: bundleId)
            installedProfiles[bundleId] = profileInfo

            if !config.silent {
                print("✓ [Match] Installed Profile: ".green.bold + "\(profileInfo.name)".bold + " (\(bundleId))".dim)
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

        // Encrypt and commit changes if new assets were generated
        if hasNewAssets && !config.readonly {
            if !config.silent {
                print("🔒 [Match] Encrypting updated assets...".dim)
            }
            try encryption.encryptDirectory(storage.workingDirectory, password: config.password)
            if !config.silent {
                print("📤 [Match] Pushing updated certificates and profiles to Git remote...".dim)
            }
            try await storage.saveChanges(commitMessage: "[appitool] Updated code signing certificates and profiles for \(config.type.rawValue)")
        }

        if !config.silent {
            print("🎉 [Match] Successfully synchronized all certificates and profiles!".green.bold)
        }

        return MatchResult(
            installedCertificates: [certInfo],
            installedProfiles: installedProfiles,
            envVariables: envVariables
        )
    }

    // MARK: - Private Helpers

    private func findCertificatePair(in directory: String, activeCertIds: Set<String>? = nil) -> (id: String, cer: String, p12: String)? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        let cerFiles = Set(files.filter { ($0 as NSString).pathExtension.lowercased() == "cer" }.map { ($0 as NSString).deletingPathExtension })
        let p12Files = Set(files.filter { ($0 as NSString).pathExtension.lowercased() == "p12" }.map { ($0 as NSString).deletingPathExtension })

        var commonIds = cerFiles.intersection(p12Files)
        if let activeCertIds, !activeCertIds.isEmpty {
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
