import ArgumentParser
import Foundation
import Rainbow

/// Removes certificates and provisioning profiles that are revoked on the Apple Developer Portal or expired from
/// Git storage. Destructive: skipped as a no-op in CI mode unless `--no-ci` is passed.
struct MatchIOSPruneCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Prunes revoked or expired certificates and provisioning profiles from Git storage."
    )

    @Option(name: .shortAndLong, help: "Distribution type to prune (appstore, development, adhoc, enterprise, developer_id). Defaults to MATCH_TYPE in .env or appstore.")
    var type: String?

    @Flag(name: .long, help: "Prune across all distribution types (cannot be combined with -t, --type).")
    var all: Bool = false

    @OptionGroup
    var options: MatchIOSOptions

    @OptionGroup
    var matchStorage: MatchStorageOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    var destructiveCommandDescription: String {
        "match ios prune"
    }

    func validate() throws {
        if all && type != nil {
            throw ValidationError("Cannot combine --all with -t, --type.")
        }
    }

    func execute() async throws {
        let resolvedType: MatchProfileType = all ? .appstore : try MatchIOSOptions.resolveProfileType(type)
        let resolvedPlatform = try options.resolvePlatform()
        let storage = try matchStorage.require()
        let appleCreds = options.appleCredentials.resolve()

        let config = MatchConfig(
            gitUrl: storage.gitUrl,
            gitBranch: storage.gitBranch,
            gitToken: storage.gitToken,
            type: resolvedType,
            platform: resolvedPlatform,
            appIdentifiers: [],
            password: storage.password,
            action: .prune,
            readonly: false,
            allTypes: all,
            apiKeyId: appleCreds?.keyId,
            apiIssuerId: appleCreds?.issuerId,
            apiKey: appleCreds?.key,
            silent: options.silent
        )

        _ = try await MatchRunner().run(config)
        if !options.silent {
            Log("✨ Match prune completed successfully.".green.bold)
        }
    }
}
