import ArgumentParser
import Foundation
import Rainbow

/// Synchronizes Apple certificates and provisioning profiles from Git storage (default `match ios` action).
struct MatchIOSSyncCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Syncs Apple certificates and provisioning profiles from Git storage, creating missing ones when writable."
    )

    @Option(name: .shortAndLong, help: "Provisioning profile distribution type (appstore, development, adhoc, enterprise, developer_id). Defaults to MATCH_TYPE in .env or appstore.")
    var type: String?

    @Option(name: .long, help: "Target application bundle identifier(s) (comma-separated; auto-discovered from the local Xcode project when omitted).")
    var identifiers: String?

    @Flag(name: .long, help: "Force renewal of provisioning profiles even if still valid.")
    var force: Bool = false

    @Flag(inversion: .prefixedNo, help: "Perform shallow clone (--shallow-clone / --no-shallow-clone). Defaults to true for readonly mode, false for write mode.")
    var shallowClone: Bool?

    @Option(name: .long, help: "Apple Developer Team Name.")
    var teamName: String?

    @OptionGroup
    var options: MatchIOSOptions

    @OptionGroup
    var matchOptions: MatchOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    var ciFlagOverride: Bool? {
        ciOptions.ci
    }

    func execute() async throws {
        let resolvedType = try MatchIOSOptions.resolveProfileType(type)
        let resolvedPlatform = try options.resolvePlatform()
        let storage = try matchOptions.storage.require()
        let match = matchOptions.resolve(defaultReadonly: false)
        let silent = options.silent

        var resolvedIdentifiers = CLIValues.commaSeparated(identifiers)
        if resolvedIdentifiers.isEmpty && XCodeTasks.hasIosProject() {
            if let iosResult = try? await XCodeTasks.getIosIdentifiers() {
                var seen = Set<String>()
                var discovered: [String] = []
                for target in iosResult.targets where !target.bundleId.isEmpty && !seen.contains(target.bundleId) {
                    seen.insert(target.bundleId)
                    discovered.append(target.bundleId)
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

        let appleCreds = options.appleCredentials.resolve()

        let config = MatchConfig(
            gitUrl: storage.gitUrl,
            gitBranch: storage.gitBranch,
            gitToken: storage.gitToken,
            type: resolvedType,
            platform: resolvedPlatform,
            appIdentifiers: resolvedIdentifiers,
            password: storage.password,
            action: .sync,
            readonly: match.readonly,
            teamId: match.teamId,
            teamName: teamName,
            apiKeyId: appleCreds?.keyId,
            apiIssuerId: appleCreds?.issuerId,
            apiKey: appleCreds?.key,
            keychainName: match.keychainName,
            keychainPassword: match.keychainPassword,
            force: force,
            shallowClone: shallowClone,
            silent: silent
        )

        let result = try await MatchRunner().run(config)
        guard !silent else { return }

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
    }
}
