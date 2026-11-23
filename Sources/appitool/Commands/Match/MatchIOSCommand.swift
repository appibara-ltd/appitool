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

    @Option(name: .shortAndLong, help: "Provisioning profile distribution type (appstore, development, adhoc, enterprise, developer_id). Defaults to MATCH_TYPE in .env or appstore.")
    var type: String?

    @Option(name: .shortAndLong, help: "Target platform (ios, macos, tvos, catalyst). Defaults to ios.")
    var platform: String = "ios"

    @Option(name: .long, help: "Target application bundle identifier(s) (comma-separated; auto-discovered from the local Xcode project when omitted).")
    var identifiers: String?

    @Flag(name: .long, help: "Prune invalid or expired certificates and provisioning profiles from Git storage.")
    var prune: Bool = false

    @Flag(name: .long, help: "Prune across all distribution types (requires --prune; cannot be combined with --type).")
    var all: Bool = false

    @Flag(name: .long, help: "Nuke (revoke and delete) certificates and provisioning profiles on Apple Developer Portal and in Git storage.")
    var nuke: Bool = false

    @Flag(name: .long, help: "Force renewal of provisioning profiles even if still valid.")
    var force: Bool = false

    @Flag(inversion: .prefixedNo, help: "Perform shallow clone (--shallow-clone / --no-shallow-clone). Defaults to true for readonly mode, false for write mode.")
    var shallowClone: Bool?

    @Option(name: .long, help: "Apple Developer Team Name.")
    var teamName: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress verbose output (--silent / --no-silent).")
    var silent: Bool = true

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var matchOptions: MatchOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    var resolvedMatchAction: MatchAction {
        if nuke {
            return .nuke
        } else if prune {
            return .prune
        }
        return .sync
    }

    func validate() throws {
        if nuke && prune {
            throw ValidationError("Cannot combine --nuke with --prune.")
        }
        if all && !prune {
            throw ValidationError("--all can only be used with --prune.")
        }
        if all && type != nil {
            throw ValidationError("Cannot combine --all with -t, --type.")
        }
    }

    var isDestructive: Bool {
        resolvedMatchAction == .nuke || resolvedMatchAction == .prune
    }

    var ciFlagOverride: Bool? {
        ciOptions.ci
    }

    var destructiveCommandDescription: String {
        "match ios --\(resolvedMatchAction.rawValue)"
    }

    func execute() async throws {
        // 1. Resolve Action
        let resolvedAction = resolvedMatchAction

        // 2. Resolve Profile Type
        let rawTypeStr: String? = all ? nil : (type ?? EnvLoader.value(for: "MATCH_TYPE"))
        let isAllTypes = all

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
                throw CommandError("Unsupported match type '\(rawTypeStr)'. Valid types: appstore, development, adhoc, enterprise, developer_id (use --prune --all for all types).")
            }
        } else {
            resolvedType = .appstore
        }

        // 3. Resolve Platform
        guard let resolvedPlatform = MatchPlatform(rawValue: platform.lowercased()) else {
            throw CommandError("Unsupported platform '\(platform)'. Valid platforms: \(MatchPlatform.allCases.map(\.rawValue).joined(separator: ", ")).")
        }

        // 4-7, 9, 12-13. Resolve Match storage and Apple signing options
        let storage = try matchOptions.storage.require()
        let match = matchOptions.resolve(defaultReadonly: false)

        // 8. Resolve App Identifiers
        var resolvedIdentifiers: [String]
        if let explicit = identifiers, !explicit.isEmpty {
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

        // 10. Resolve Force
        let resolvedForce = force

        // 11. Resolve Apple Credentials
        let appleCreds = appleCredentials.resolve()
        let resolvedTeamName = teamName

        let config = MatchConfig(
            gitUrl: storage.gitUrl,
            gitBranch: storage.gitBranch,
            gitToken: storage.gitToken,
            type: resolvedType,
            platform: resolvedPlatform,
            appIdentifiers: resolvedIdentifiers,
            password: storage.password,
            action: resolvedAction,
            readonly: match.readonly,
            allTypes: isAllTypes,
            teamId: match.teamId,
            teamName: resolvedTeamName,
            apiKeyId: appleCreds?.keyId,
            apiIssuerId: appleCreds?.issuerId,
            apiKey: appleCreds?.key,
            keychainName: match.keychainName,
            keychainPassword: match.keychainPassword,
            force: resolvedForce,
            shallowClone: shallowClone,
            silent: silent
        )

        let runner = MatchRunner()
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
    }
}
