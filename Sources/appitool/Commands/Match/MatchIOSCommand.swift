import ArgumentParser
import Foundation
import Rainbow

/// A command that synchronizes or nukes iOS/Apple code signing certificates and provisioning profiles
/// using Git storage, providing 100% Fastlane match equivalence.
struct MatchIOSCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Syncs, nukes, or prunes Apple certificates and provisioning profiles using Git storage (Fastlane match equivalent)."
    )

    @Argument(help: "Provisioning profile distribution type (appstore, development, adhoc, enterprise, developer_id) or action (nuke, prune).")
    var actionOrType: String?

    @Argument(help: "Optional distribution type (appstore, development, adhoc, enterprise, developer_id) or 'all' when the first argument is an action.")
    var targetType: String?

    @Option(name: .shortAndLong, help: "Provisioning profile distribution type (appstore, development, adhoc, enterprise, developer_id). Defaults to MATCH_TYPE in .env or appstore.")
    var type: String?

    @Option(name: .shortAndLong, help: "Git repository URL for certificates storage (defaults to MATCH_GIT_URL in .env).")
    var gitUrl: String?

    @Option(name: [.customShort("b"), .long], help: "Git branch name (defaults to MATCH_GIT_BRANCH in .env or 'master').")
    var gitBranch: String?

    @Option(name: .long, help: "Target platform (ios, macos, tvos, catalyst). Defaults to ios.")
    var platform: String = "ios"

    @Option(name: .long, help: "Git authentication token (defaults to MATCH_GIT_TOKEN or GITHUB_TOKEN in .env).")
    var gitToken: String?

    @Option(name: .shortAndLong, help: "Passphrase for AES encryption/decryption (defaults to MATCH_PASSWORD in .env).")
    var password: String?

    @Option(name: .shortAndLong, help: "Target application bundle identifier(s) (comma-separated).")
    var appIdentifiers: String?

    @Flag(name: .shortAndLong, help: "Run in read-only mode (prevents creating new certificates/profiles on Apple Developer Portal).")
    var readonly: Bool = false

    @Flag(name: .long, help: "Prune invalid or expired certificates and provisioning profiles from Git storage.")
    var prune: Bool = false

    @Flag(name: [.customShort("A"), .long], help: "Operate across all distribution types when pruning.")
    var all: Bool = false

    @Flag(name: .long, help: "Nuke (revoke and delete) certificates and provisioning profiles on Apple Developer Portal and in Git storage.")
    var nuke: Bool = false

    @Flag(name: .shortAndLong, help: "Force renewal of provisioning profiles even if still valid.")
    var force: Bool = false

    @Flag(inversion: .prefixedNo, help: "Perform shallow clone (--shallow-clone / --no-shallow-clone). Defaults to true for readonly mode, false for write mode.")
    var shallowClone: Bool?

    @Option(name: .long, help: "Apple Developer Team ID (defaults to APPLE_TEAM_ID in .env).")
    var teamId: String?

    @Option(name: .long, help: "Apple Developer Team Name.")
    var teamName: String?

    @Option(name: .long, help: "Custom keychain name or path (defaults to MATCH_KEYCHAIN_NAME in .env).")
    var keychainName: String?

    @Option(name: .long, help: "Custom keychain password (defaults to MATCH_KEYCHAIN_PASSWORD in .env).")
    var keychainPassword: String?

    @Flag(name: .long, help: "Suppress verbose output.")
    var silent: Bool = false

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    func execute() async throws {
        // 1. Resolve Action
        var resolvedAction: MatchAction = .sync
        if nuke || actionOrType?.lowercased() == "nuke" {
            resolvedAction = .nuke
        } else if prune || actionOrType?.lowercased() == "prune" {
            resolvedAction = .prune
        }

        // 2. Resolve Profile Type
        let isActionArg = actionOrType?.lowercased() == "nuke" || actionOrType?.lowercased() == "prune"
        let rawTypeStr: String?
        if isActionArg {
            rawTypeStr = targetType ?? type ?? EnvLoader.value(for: "MATCH_TYPE")
        } else if let actionOrType {
            rawTypeStr = actionOrType
        } else {
            rawTypeStr = type ?? EnvLoader.value(for: "MATCH_TYPE")
        }

        let isAllTypes = all || rawTypeStr?.lowercased() == "all"

        let resolvedType: MatchProfileType
        if isAllTypes {
            resolvedType = .appstore
        } else if let rawTypeStr {
            switch rawTypeStr.lowercased() {
            case "appstore", "app_store":
                resolvedType = .appstore
            case "development", "dev":
                resolvedType = .development
            case "adhoc", "ad_hoc":
                resolvedType = .adhoc
            case "enterprise", "inhouse", "in_house":
                resolvedType = .enterprise
            case "developer_id", "developerid", "developer-id":
                resolvedType = .developerId
            default:
                Log("Error: ".red.bold + "Unsupported match type '\(rawTypeStr)'. Valid types: appstore, development, adhoc, enterprise, developer_id, all.")
                throw ExitCode.failure
            }
        } else {
            resolvedType = .appstore
        }

        // 3. Resolve Platform
        guard let resolvedPlatform = MatchPlatform(rawValue: platform.lowercased()) else {
            Log("Error: ".red.bold + "Unsupported platform '\(platform)'. Valid platforms: \(MatchPlatform.allCases.map(\.rawValue).joined(separator: ", ")).")
            throw ExitCode.failure
        }

        // 4. Resolve Git URL
        guard let resolvedGitUrl = gitUrl ?? EnvLoader.value(for: "MATCH_GIT_URL"), !resolvedGitUrl.isEmpty else {
            Log("Error: ".red.bold + "Missing Git repository URL. Provide -g, --git-url or configure MATCH_GIT_URL in .env.")
            throw ExitCode.failure
        }

        // 5. Resolve Git Branch
        let resolvedGitBranch = gitBranch ?? EnvLoader.value(for: "MATCH_GIT_BRANCH") ?? "master"

        // 6. Resolve Git Token
        let resolvedGitToken = gitToken ?? EnvLoader.value(for: "MATCH_GIT_TOKEN") ?? EnvLoader.value(for: "GITHUB_TOKEN")

        // 7. Resolve Password
        guard let resolvedPassword = password ?? EnvLoader.value(for: "MATCH_PASSWORD"), !resolvedPassword.isEmpty else {
            Log("Error: ".red.bold + "Missing encryption password. Provide -p, --password or configure MATCH_PASSWORD in .env.")
            throw ExitCode.failure
        }

        // 8. Resolve App Identifiers
        var resolvedIdentifiers: [String]
        if let explicit = appIdentifiers, !explicit.isEmpty {
            resolvedIdentifiers = explicit.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            resolvedIdentifiers = []
        }

        if resolvedIdentifiers.isEmpty && XCodeTasks.hasIosProject() {
            if let iosResult = try? await XCodeTasks.getIosIdentifiers() {
                var seen = Set<String>()
                var discovered: [String] = []
                for target in iosResult.targets {
                    if !target.bundleId.isEmpty && !seen.contains(target.bundleId) {
                        seen.insert(target.bundleId)
                        discovered.append(target.bundleId)
                    }
                }
                if discovered.isEmpty, let mainBundleId = iosResult.bundleId, !mainBundleId.isEmpty {
                    discovered.append(mainBundleId)
                }
                if !discovered.isEmpty {
                    resolvedIdentifiers = discovered
                    if !silent {
                        Log("🟡 Discovered project bundle identifiers: \(resolvedIdentifiers.joined(separator: ", "))".dim)
                    }
                }
            }
        }

        // 9. Resolve Readonly
        let resolvedReadonly = readonly

        // 10. Resolve Force
        let resolvedForce = force

        // 11. Resolve Apple Credentials
        let appleCreds = appleCredentials.resolve()

        // 12. Resolve Team ID & Name
        let resolvedTeamId = teamId ?? EnvLoader.value(for: "APPLE_TEAM_ID")
        let resolvedTeamName = teamName

        // 13. Resolve Keychain
        let resolvedKeychainName = keychainName ?? EnvLoader.value(for: "MATCH_KEYCHAIN_NAME") ?? "appitool"
        let resolvedKeychainPassword = keychainPassword ?? EnvLoader.value(for: "MATCH_KEYCHAIN_PASSWORD") ?? "appipass"

        let config = MatchConfig(
            gitUrl: resolvedGitUrl,
            gitBranch: resolvedGitBranch,
            gitToken: resolvedGitToken,
            type: resolvedType,
            platform: resolvedPlatform,
            appIdentifiers: resolvedIdentifiers,
            password: resolvedPassword,
            action: resolvedAction,
            readonly: resolvedReadonly,
            allTypes: isAllTypes,
            teamId: resolvedTeamId,
            teamName: resolvedTeamName,
            apiKeyId: appleCreds?.keyId,
            apiIssuerId: appleCreds?.issuerId,
            apiKey: appleCreds?.key,
            keychainName: resolvedKeychainName,
            keychainPassword: resolvedKeychainPassword,
            force: resolvedForce,
            shallowClone: shallowClone,
            silent: silent
        )

        let runner = MatchRunner()
        do {
            let result = try await runner.run(config)
            if resolvedAction == .sync && !silent {
                Log("✨ Match completed successfully.".green.bold)
                if !result.installedCertificates.isEmpty {
                    Log("\nInstalled Certificates:".bold)
                    for cert in result.installedCertificates {
                        Log("  • \(cert.name) (\(cert.id))".dim)
                    }
                }
                if !result.installedProfiles.isEmpty {
                    Log("\nInstalled Provisioning Profiles:".bold)
                    for (bundleId, profile) in result.installedProfiles {
                        Log("  • \(bundleId): \(profile.name) [\(profile.uuid)]".dim)
                    }
                }
            } else if resolvedAction == .prune && !silent {
                Log("✨ Match prune completed successfully.".green.bold)
            }
        } catch {
            Log("Error: ".red.bold + "\(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
