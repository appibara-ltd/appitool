import ArgumentParser
import Foundation
import Rainbow

struct BuildAndroidCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Builds the project for Android using Gradle."
    )

    enum Format: String, ExpressibleByArgument, CaseIterable, Sendable {
        case aab
        case apk
    }

    @Option(name: .shortAndLong, help: "Distribution method (adhoc, development, appstore). Defaults to appstore.")
    var distribution: BuildCommand.Distribution = .appstore

    @Option(name: .shortAndLong, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @Option(name: .shortAndLong, help: "Product flavor (e.g. production, staging). Defaults to ANDROID_FLAVOR in .env.")
    var flavor: String?

    @Option(name: .shortAndLong, help: "Build configuration/type (Release or Debug). Defaults to Release or ANDROID_CONFIGURATION in .env.")
    var configuration: String?

    @Option(name: .long, help: "Packaging format (aab or apk). Defaults to aab for appstore, apk for adhoc/development.")
    var format: Format?

    @Flag(name: .long, help: "Clean project before building.")
    var clean: Bool = false

    @Flag(name: .long, help: "Suppress Gradle output during build.")
    var silent: Bool = false

    @Option(name: .long, help: "Android project root directory (defaults to ./android if present, else current directory).")
    var projectDir: String?

    @Option(name: .long, help: "Path to keystore file for signing (defaults to ANDROID_KEYSTORE_PATH in .env).")
    var keystorePath: String?

    @Option(name: .long, help: "Base64-encoded keystore for signing (defaults to ANDROID_KEYSTORE in .env).")
    var keystoreBase64: String?

    @Option(name: .long, help: "Keystore password for signing (defaults to ANDROID_KEYSTORE_PASSWORD in .env).")
    var keystorePassword: String?

    @Option(name: .long, help: "Key alias for signing (defaults to ANDROID_KEY_ALIAS in .env).")
    var keyAlias: String?

    @Option(name: .long, help: "Key password for signing (defaults to ANDROID_KEY_PASSWORD in .env).")
    var keyPassword: String?

    @Option(name: .long, help: "Custom JVM options passed via GRADLE_OPTS to Gradle launcher.")
    var gradleOpts: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        let env = ProcessInfo.processInfo.environment

        // 1. Resolve Android project directory
        let fm = FileManager.default
        let currentDir = fm.currentDirectoryPath
        let resolvedProjectDir: String
        if let explicit = projectDir ?? env["ANDROID_PROJECT_DIR"] {
            resolvedProjectDir = NSString(string: explicit).expandingTildeInPath
        } else if fm.fileExists(atPath: "\(currentDir)/android") {
            resolvedProjectDir = "\(currentDir)/android"
        } else {
            resolvedProjectDir = currentDir
        }

        // 2. Resolve package name (applicationId) & target app name
        let resolvedPackageName = packageName
            ?? env["GOOGLE_PACKAGE_NAME"]
            ?? GradleTask.resolvePackageName(projectDirectory: resolvedProjectDir)

        let appName = GradleTask.resolveAppName(projectDirectory: resolvedProjectDir)
        let mainTarget: String
        if let appName, !appName.isEmpty {
            mainTarget = appName
        } else {
            let projectURL = URL(fileURLWithPath: resolvedProjectDir)
            let folderName = projectURL.lastPathComponent == "android"
                ? projectURL.deletingLastPathComponent().lastPathComponent
                : projectURL.lastPathComponent
            mainTarget = !folderName.isEmpty && folderName != "/" ? folderName : "AndroidApp"
        }

        // 3. Resolve packaging format & build type
        let resolvedFormat: GradleTask.BuildFormat
        if let format {
            resolvedFormat = format == .aab ? .aab : .apk
        } else {
            switch distribution {
            case .appstore:
                resolvedFormat = .aab
            case .adhoc, .development:
                resolvedFormat = .apk
            }
        }

        let resolvedBuildType = configuration ?? env["ANDROID_CONFIGURATION"] ?? "Release"
        let resolvedFlavor = flavor ?? env["ANDROID_FLAVOR"]

        // 4. Resolve signing configuration
        var tempKeystoreUrl: URL? = nil
        defer {
            if let tempUrl = tempKeystoreUrl {
                try? fm.removeItem(at: tempUrl)
            }
        }

        let signingConfig: GradleTask.SigningConfig? = try resolveSigningConfig(
            env: env,
            tempKeystoreUrl: &tempKeystoreUrl
        )

        // 5. Resolve opinionated output directory and artifact name
        let homeDir = fm.homeDirectoryForCurrentUser.path
        let targetRoot = URL(fileURLWithPath: homeDir)
            .appendingPathComponent(".appitool")
            .appendingPathComponent("android")
            .appendingPathComponent(mainTarget)

        let resolvedOutputDir = targetRoot.appendingPathComponent("build").path

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy_MM_dd_HH_mm"
        let timestamp = dateFormatter.string(from: Date())

        let flavorSuffix = (resolvedFlavor?.isEmpty == false) ? "\(resolvedFlavor!)_" : ""
        let artifactBaseName = "\(mainTarget)_\(flavorSuffix)\(timestamp)"

        // 6. Execute GradleTask
        let task = GradleTask()
        Log("\n" + "🏗️  Starting Android build for ".bold + "\(mainTarget)".cyan.bold + " (\(distribution.rawValue.capitalized))...".dim)
        if let pkg = resolvedPackageName {
            Log("   Package:     ".dim + "\(pkg)".yellow)
        }

        var gradleEnvironment = env
        if let gradleOpts, !gradleOpts.isEmpty {
            let finalGradleOpts = gradleOpts.contains("-Dorg.gradle.daemon=false") ? gradleOpts : "\(gradleOpts) -Dorg.gradle.daemon=false"
            gradleEnvironment["GRADLE_OPTS"] = finalGradleOpts
        }

        do {
            let output = try await task.run(.init(
                projectDirectory: resolvedProjectDir,
                buildType: resolvedBuildType,
                flavor: resolvedFlavor,
                format: resolvedFormat,
                outputDirectory: resolvedOutputDir,
                artifactName: artifactBaseName,
                signing: signingConfig,
                clean: clean,
                silent: silent,
                environment: gradleEnvironment
            ))

            Log("\n" + "🎉 Android Build Completed Successfully!".green.bold)
            if let aab = output.aabPath {
                Log("   Bundle (AAB): ".dim + "\(aab)".green.bold)
            }
            if let apk = output.apkPath {
                Log("   Package (APK): ".dim + "\(apk)".green.bold)
            }
        } catch {
            Log("\n" + "🔴 Build Failed: ".red.bold + "\(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Signing Config Resolution

    private func resolveSigningConfig(
        env: [String: String],
        tempKeystoreUrl: inout URL?
    ) throws -> GradleTask.SigningConfig? {
        let fm = FileManager.default

        var storeFilePath: String? = nil

        // If base64-encoded keystore is provided, write it to a temporary file
        if let base64 = keystoreBase64 ?? env["ANDROID_KEYSTORE"], !base64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) {
                let tempDir = URL(fileURLWithPath: fm.homeDirectoryForCurrentUser.path)
                    .appendingPathComponent(".appitool")
                    .appendingPathComponent("android")
                    .appendingPathComponent("tmp")
                try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let tempFile = tempDir.appendingPathComponent("keystore_\(UUID().uuidString).keystore")
                try data.write(to: tempFile)
                tempKeystoreUrl = tempFile
                storeFilePath = tempFile.path
            }
        }

        if storeFilePath == nil {
            if let explicitPath = keystorePath ?? env["ANDROID_KEYSTORE_PATH"], !explicitPath.isEmpty {
                storeFilePath = NSString(string: explicitPath).expandingTildeInPath
            }
        }

        let storePassword = keystorePassword ?? env["ANDROID_KEYSTORE_PASSWORD"]
        let alias = keyAlias ?? env["ANDROID_KEY_ALIAS"]
        let keyPass = keyPassword ?? env["ANDROID_KEY_PASSWORD"]

        if let storeFilePath, let storePassword, let alias, let keyPass {
            return GradleTask.SigningConfig(
                storeFile: storeFilePath,
                storePassword: storePassword,
                keyAlias: alias,
                keyPassword: keyPass
            )
        }

        return nil
    }
}
