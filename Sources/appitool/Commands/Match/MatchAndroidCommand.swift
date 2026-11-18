import ArgumentParser
import Foundation
import Rainbow

/// A command that synchronizes or adds Android keystores using Git storage (Match equivalent for Android).
struct MatchAndroidCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Syncs or adds Android keystores using Git storage."
    )

    @Option(name: .shortAndLong, help: "Target application package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @Option(name: .shortAndLong, help: "Build type (release, debug). Defaults to release.")
    var configuration: String = "release"

    @Option(name: .customLong("add"), help: "Path to local keystore file to add to the Match repository.")
    var add: String?

    @Option(name: .shortAndLong, help: "Path to local keystore file to add (alias for --add).")
    var keystore: String?

    @Option(name: .shortAndLong, help: "Key alias (defaults to ANDROID_KEY_ALIAS in .env).")
    var alias: String?

    @Option(name: .long, help: "Keystore password (defaults to ANDROID_KEYSTORE_PASSWORD in .env).")
    var storePassword: String?

    @Option(name: .long, help: "Key password (defaults to ANDROID_KEY_PASSWORD in .env).")
    var keyPassword: String?

    @Option(name: .shortAndLong, help: "Git repository URL for keystores storage (defaults to MATCH_GIT_URL in .env).")
    var gitUrl: String?

    @Option(name: [.customShort("b"), .long], help: "Git branch name (defaults to MATCH_GIT_BRANCH in .env or 'master').")
    var gitBranch: String?

    @Option(name: .long, help: "Git authentication token (defaults to MATCH_GIT_TOKEN or GITHUB_TOKEN in .env).")
    var gitToken: String?

    @Option(name: [.customShort("P"), .long], help: "Passphrase for AES encryption/decryption (defaults to MATCH_PASSWORD in .env).")
    var password: String?

    @Flag(name: .long, help: "Suppress verbose output.")
    var silent: Bool = false

    func execute() async throws {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        // 1. Resolve Git URL
        guard let resolvedGitUrl = gitUrl ?? env["MATCH_GIT_URL"], !resolvedGitUrl.isEmpty else {
            Log("Error: ".red.bold + "Missing Git repository URL. Provide -g, --git-url or configure MATCH_GIT_URL in .env.")
            throw ExitCode.failure
        }

        // 2. Resolve Git Branch
        let resolvedGitBranch = gitBranch ?? env["MATCH_GIT_BRANCH"] ?? "master"

        // 3. Resolve Git Token
        let resolvedGitToken = gitToken ?? env["MATCH_GIT_TOKEN"] ?? env["GITHUB_TOKEN"]

        // 4. Resolve Password
        guard let resolvedPassword = password ?? env["MATCH_PASSWORD"], !resolvedPassword.isEmpty else {
            Log("Error: ".red.bold + "Missing encryption password. Provide -P, --password or configure MATCH_PASSWORD in .env.")
            throw ExitCode.failure
        }

        // 5. Resolve Package Name
        let currentDir = fm.currentDirectoryPath
        let resolvedPackageName = packageName
            ?? env["GOOGLE_PACKAGE_NAME"]
            ?? GradleTask.resolvePackageName(projectDirectory: currentDir)

        guard let targetPackage = resolvedPackageName, !targetPackage.isEmpty else {
            Log("Error: ".red.bold + "Missing package name. Provide -p, --package-name or configure GOOGLE_PACKAGE_NAME in .env.")
            throw ExitCode.failure
        }

        // 6. Resolve Build Type
        let resolvedBuildType = MatchAndroidConfig.BuildType(rawValue: configuration.lowercased()) ?? .release

        // 7. Resolve Action & Keystore Path
        let resolvedKeystorePath = add ?? keystore
        let resolvedAction: MatchAndroidConfig.Action = (resolvedKeystorePath != nil) ? .add : .sync

        // 8. Resolve Credentials
        let resolvedAlias = alias ?? env["ANDROID_KEY_ALIAS"]
        let resolvedStorePassword = storePassword ?? env["ANDROID_KEYSTORE_PASSWORD"]
        let resolvedKeyPassword = keyPassword ?? env["ANDROID_KEY_PASSWORD"]

        let config = MatchAndroidConfig(
            gitUrl: resolvedGitUrl,
            gitBranch: resolvedGitBranch,
            gitToken: resolvedGitToken,
            password: resolvedPassword,
            action: resolvedAction,
            packageName: targetPackage,
            buildType: resolvedBuildType,
            keystorePath: resolvedKeystorePath,
            alias: resolvedAlias,
            storePassword: resolvedStorePassword,
            keyPassword: resolvedKeyPassword,
            silent: silent
        )

        let runner = MatchRunner()
        do {
            let result = try await runner.runAndroid(config)
            if !silent {
                if resolvedAction == .add {
                    Log("\n🎉 Keystore successfully added to Match storage!".green.bold)
                    Log("   Package:      ".dim + "\(targetPackage)".bold)
                    Log("   Build Type:   ".dim + "\(resolvedBuildType.rawValue)")
                } else {
                    Log("\n✨ Match Android sync completed successfully!".green.bold)
                    Log("   Package:      ".dim + "\(targetPackage)".bold)
                    Log("   Build Type:   ".dim + "\(resolvedBuildType.rawValue)")
                    Log("   Keystore:     ".dim + "\(result.keystorePath)".green)
                    Log("   Key Alias:    ".dim + "\(result.alias)")
                }
            }
        } catch {
            Log("Error: ".red.bold + "\(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
