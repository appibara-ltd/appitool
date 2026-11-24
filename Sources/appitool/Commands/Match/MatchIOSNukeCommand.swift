import ArgumentParser
import Foundation
import Rainbow

/// Revokes certificates and deletes provisioning profiles of one distribution type on the Apple Developer Portal
/// and in Git storage. Destructive: skipped as a no-op in CI mode unless `--no-ci` is passed.
struct MatchIOSNukeCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "nuke",
        abstract: "Revokes certificates and deletes provisioning profiles on Apple Developer Portal and in Git storage."
    )

    @Option(name: .shortAndLong, help: "Distribution type to nuke (appstore, development, adhoc, enterprise, developer_id). Defaults to MATCH_TYPE in .env or appstore.")
    var type: String?

    @OptionGroup
    var options: MatchIOSOptions

    @OptionGroup
    var matchStorage: MatchStorageOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    var destructiveCommandDescription: String {
        "match ios nuke"
    }

    func execute() async throws {
        let resolvedType = try MatchIOSOptions.resolveProfileType(type)
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
            action: .nuke,
            readonly: false,
            apiKeyId: appleCreds?.keyId,
            apiIssuerId: appleCreds?.issuerId,
            apiKey: appleCreds?.key,
            silent: options.silent
        )

        _ = try await MatchRunner().run(config)
    }
}
