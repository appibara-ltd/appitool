import ArgumentParser
import Foundation
import MatchTarget
import Rainbow

/// A command that synchronizes or nukes code signing certificates and provisioning profiles
/// using Git storage, providing 100% Fastlane match equivalence.
struct MatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "match",
        abstract: "Syncs or nukes certificates and provisioning profiles using Git storage (Fastlane match equivalent)."
    )

    @Argument(help: "Provisioning profile distribution type (appstore, development, adhoc, enterprise, developer_id) or action (nuke).")
    var actionOrType: String?

    @Option(name: .shortAndLong, help: "Provisioning profile distribution type (appstore, development, adhoc, enterprise, developer_id). Defaults to MATCH_TYPE in .env or appstore.")
    var type: String?

    @Option(name: .shortAndLong, help: "Git repository URL for certificates storage (defaults to MATCH_GIT_URL in .env).")
    var gitUrl: String?

    @Option(name: .shortAndLong, help: "Git branch name (defaults to MATCH_GIT_BRANCH in .env or 'master').")
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

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        let env = ProcessInfo.processInfo.environment

        // 1. Resolve Action
        var resolvedAction: MatchAction = .sync
        if nuke || actionOrType?.lowercased() == "nuke" {
            resolvedAction = .nuke
        }

        // 2. Resolve Profile Type
        let rawTypeStr: String?
        if let actionOrType, actionOrType.lowercased() != "nuke" {
            rawTypeStr = actionOrType
        } else {
            rawTypeStr = type
        }

        let resolvedType: MatchProfileType
        if let rawTypeStr {
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
                print("Error: ".red.bold + "Unsupported match type '\(rawTypeStr)'. Valid types: appstore, development, adhoc, enterprise, developer_id.")
                throw ExitCode.failure
            }
        } else {
            resolvedType = .appstore
        }

        // 3. Resolve Platform
        guard let resolvedPlatform = MatchPlatform(rawValue: platform.lowercased()) else {
            print("Error: ".red.bold + "Unsupported platform '\(platform)'. Valid platforms: \(MatchPlatform.allCases.map(\.rawValue).joined(separator: ", ")).")
            throw ExitCode.failure
        }

        // 4. Resolve Git URL
        guard let resolvedGitUrl = gitUrl ?? env["MATCH_GIT_URL"], !resolvedGitUrl.isEmpty else {
            print("Error: ".red.bold + "Missing Git repository URL. Provide -g, --git-url or configure MATCH_GIT_URL in .env.")
            throw ExitCode.failure
        }

        // 5. Resolve Git Branch
        let resolvedGitBranch = gitBranch ?? env["MATCH_GIT_BRANCH"] ?? "master"

        // 6. Resolve Git Token
        let resolvedGitToken = gitToken ?? env["MATCH_GIT_TOKEN"] ?? env["GITHUB_TOKEN"]

        // 7. Resolve Password
        guard let resolvedPassword = password ?? env["MATCH_PASSWORD"], !resolvedPassword.isEmpty else {
            print("Error: ".red.bold + "Missing encryption password. Provide -p, --password or configure MATCH_PASSWORD in .env.")
            throw ExitCode.failure
        }

        // 8. Resolve App Identifiers
        let resolvedIdentifiers: [String]
        if let explicit = appIdentifiers, !explicit.isEmpty {
            resolvedIdentifiers = explicit.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            resolvedIdentifiers = []
        }

        // 9. Resolve Readonly
        let resolvedReadonly = readonly

        // 10. Resolve Force
        let resolvedForce = force

        // 11. Resolve Apple Credentials
        let appleCreds = appleCredentials.resolve()

        // 12. Resolve Team ID & Name
        let resolvedTeamId = teamId ?? env["APPLE_TEAM_ID"]
        let resolvedTeamName = teamName

        // 13. Resolve Keychain
        let resolvedKeychainName = keychainName ?? env["MATCH_KEYCHAIN_NAME"]
        let resolvedKeychainPassword = keychainPassword ?? env["MATCH_KEYCHAIN_PASSWORD"]

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
                print("✨ Match completed successfully.".green.bold)
                if !result.installedCertificates.isEmpty {
                    print("\nInstalled Certificates:".bold)
                    for cert in result.installedCertificates {
                        print("  • \(cert.name) (\(cert.id))".dim)
                    }
                }
                if !result.installedProfiles.isEmpty {
                    print("\nInstalled Provisioning Profiles:".bold)
                    for (bundleId, profile) in result.installedProfiles {
                        print("  • \(bundleId): \(profile.name) [\(profile.uuid)]".dim)
                    }
                }
            }
        } catch {
            print("Error: ".red.bold + "\(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
