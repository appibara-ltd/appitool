import ArgumentParser
import Foundation

/// Global CLI option group providing `--ci` / `--no-ci` across the command hierarchy.
///
/// Must remain long-only (`name: .long`) because `-c` is already used by subcommands
/// such as `build` / `flow` / `match android` (`--configuration`) and `self-update` (`--check`).
struct GlobalCIOptions: ParsableArguments, Sendable {
    @Flag(
        name: .long,
        inversion: .prefixedNo,
        exclusivity: .chooseLast,
        help: "Enable or disable CI mode, skipping destructive commands as a no-op (--ci / --no-ci; auto-detected from CI environment variables when omitted)."
    )
    var ci: Bool?
}

/// Resolves whether the CLI is executing in a CI environment.
enum CIEnvironment: Sendable {
    struct Resolution: Sendable, Equatable {
        let isCI: Bool
        let source: String?
    }

    static let knownCIEnvVars: [String] = [
        "GITHUB_ACTIONS",
        "GITLAB_CI",
        "BITRISE_IO",
        "CIRCLECI",
        "BUILDKITE",
        "JENKINS_URL",
        "TF_BUILD",
        "TEAMCITY_VERSION",
        "TRAVIS",
        "CODEMAGIC_BUILD_ID",
        "CI_XCODE_CLOUD",
    ]

    private static let falsyValues: Set<String> = ["0", "false", "no", "off"]

    static func isTruthy(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !falsyValues.contains(trimmed.lowercased())
    }

    static func resolve(
        flag: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolution {
        if let flag {
            return Resolution(
                isCI: flag,
                source: flag ? "--ci flag" : "--no-ci flag"
            )
        }

        if let rawCI = environment["CI"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCI.isEmpty {
            return Resolution(
                isCI: isTruthy(rawCI),
                source: "CI environment variable"
            )
        }

        for key in knownCIEnvVars {
            if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               isTruthy(raw) {
                return Resolution(
                    isCI: true,
                    source: "\(key) environment variable"
                )
            }
        }

        return Resolution(isCI: false, source: nil)
    }
}
