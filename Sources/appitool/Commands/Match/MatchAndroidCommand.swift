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

    @Flag(name: .long, help: "Suppress verbose output.")
    var silent: Bool = false

    @OptionGroup
    var matchOptions: MatchStorageOptions

    func execute() async throws {
        // 1-4. Resolve Match storage options
        let storage = try matchOptions.require()

        // 5. Resolve Package Name
        let resolvedPackageName = packageName
            ?? EnvLoader.value(for: "GOOGLE_PACKAGE_NAME")
            ?? AndroidTasks.resolvePackageName()

        guard let targetPackage = resolvedPackageName, !targetPackage.isEmpty else {
            throw CommandError("Missing package name. Provide -p, --package-name or configure GOOGLE_PACKAGE_NAME in .env.")
        }

        // 6. Resolve Build Type
        let resolvedBuildType = MatchAndroidConfig.BuildType(rawValue: configuration.lowercased()) ?? .release

        // 7. Resolve Action & Keystore Path
        let resolvedKeystorePath = add ?? keystore
        let resolvedAction: MatchAndroidConfig.Action = (resolvedKeystorePath != nil) ? .add : .sync

        // 8. Resolve Credentials
        let resolvedAlias = alias ?? EnvLoader.value(for: "ANDROID_KEY_ALIAS")
        let resolvedStorePassword = storePassword ?? EnvLoader.value(for: "ANDROID_KEYSTORE_PASSWORD")
        let resolvedKeyPassword = keyPassword ?? EnvLoader.value(for: "ANDROID_KEY_PASSWORD")

        let config = MatchAndroidConfig(
            gitUrl: storage.gitUrl,
            gitBranch: storage.gitBranch,
            gitToken: storage.gitToken,
            password: storage.password,
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
    }
}
