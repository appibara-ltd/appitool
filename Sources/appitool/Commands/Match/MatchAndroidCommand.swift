import ArgumentParser
import Foundation
import Rainbow

/// A command that synchronizes or adds Android keystores using Git storage (Match equivalent for Android).
struct MatchAndroidCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Syncs or adds Android keystores using Git storage."
    )

    @Option(name: .long, help: "Target application package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @Option(name: .shortAndLong, help: "Build type (release, debug). Defaults to release.")
    var configuration: String = "release"

    @Option(name: .shortAndLong, help: "Path to local keystore file to encrypt and add to the Match repository (omit to sync).")
    var keystore: String?

    @Option(name: .long, help: "Key alias (defaults to ANDROID_KEY_ALIAS in .env).")
    var alias: String?

    @Option(name: .long, help: "Keystore password (defaults to ANDROID_KEYSTORE_PASSWORD in .env).")
    var keystorePassword: String?

    @Option(name: .long, help: "Key password (defaults to ANDROID_KEY_PASSWORD in .env).")
    var keyPassword: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress verbose output (--silent / --no-silent).")
    var silent: Bool = true

    @OptionGroup
    var matchOptions: MatchStorageOptions

    func execute() async throws {
        // 1-4. Resolve Match storage options
        let storage = try matchOptions.require()

        // 5. Resolve Package Name
        guard let targetPackage = AppIdentifierResolver.androidPackageName(explicit: packageName) else {
            throw CommandError("Missing package name. Provide --package-name, set GOOGLE_PACKAGE_NAME in .env, or run inside an Android project.")
        }

        // 6. Resolve Build Type
        let resolvedBuildType = MatchAndroidConfig.BuildType(rawValue: configuration.lowercased()) ?? .release

        // 7. Resolve Action & Keystore Path
        let resolvedKeystorePath = keystore
        let resolvedAction: MatchAndroidConfig.Action = (resolvedKeystorePath != nil) ? .add : .sync

        // 8. Resolve Credentials
        let resolvedAlias = alias ?? EnvLoader.value(for: "ANDROID_KEY_ALIAS")
        let resolvedStorePassword = keystorePassword ?? EnvLoader.value(for: "ANDROID_KEYSTORE_PASSWORD")
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
