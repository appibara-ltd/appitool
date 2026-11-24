import ArgumentParser
import Foundation

/// Options shared by every `match ios` action subcommand (`sync`, `nuke`, `prune`).
struct MatchIOSOptions: ParsableArguments, Sendable {
    @Option(name: .shortAndLong, help: "Target platform (ios, macos, tvos, catalyst). Defaults to ios.")
    var platform: String = "ios"

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress verbose output (--silent / --no-silent).")
    var silent: Bool = true

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    /// Resolves `-p, --platform` into a `MatchPlatform`.
    func resolvePlatform() throws -> MatchPlatform {
        guard let resolved = MatchPlatform(rawValue: platform.lowercased()) else {
            throw CommandError("Unsupported platform '\(platform)'. Valid platforms: \(MatchPlatform.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return resolved
    }

    /// Resolves `-t, --type` with `MATCH_TYPE` fallback, defaulting to `appstore`.
    static func resolveProfileType(_ explicit: String?) throws -> MatchProfileType {
        guard let raw = explicit ?? EnvLoader.value(for: "MATCH_TYPE"), !raw.isEmpty else {
            return .appstore
        }
        switch raw.lowercased() {
        case "appstore", "app_store":
            return .appstore
        case "development", "dev":
            return .development
        case "adhoc", "ad_hoc":
            return .adhoc
        case "enterprise", "inhouse", "in_house":
            return .enterprise
        case "developer_id", "developerid", "developer-id":
            return .developerId
        default:
            throw CommandError("Unsupported match type '\(raw)'. Valid types: appstore, development, adhoc, enterprise, developer_id.")
        }
    }
}
