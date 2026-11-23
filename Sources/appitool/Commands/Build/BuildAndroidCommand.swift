import ArgumentParser
import Foundation
import Rainbow

struct BuildAndroidCommand: BaseCommand {
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

    @Option(name: .long, help: "Target Android package name (defaults to GOOGLE_PACKAGE_NAME in .env).")
    var packageName: String?

    @Option(name: .long, help: "Gradle product flavor (e.g. production, staging). Defaults to ANDROID_FLAVOR in .env.")
    var flavor: String?

    @Option(name: .shortAndLong, help: "Build configuration/type (Release or Debug). Defaults to Release or ANDROID_CONFIGURATION in .env.")
    var configuration: String?

    @Option(name: .long, help: "Packaging format (aab or apk). Defaults to apk for adhoc/development, aab for appstore.")
    var format: Format?

    @Flag(name: .long, help: "Clean project before building.")
    var clean: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Suppress Gradle output during build.")
    var silent: Bool = true

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

    @Flag(name: .long, help: "Fetch signing keystore from Match Git repository.")
    var match: Bool = false

    @OptionGroup var matchOptions: MatchStorageOptions

    func execute() async throws {
        // 1. Resolve Android project directory
        let fm = FileManager.default
        let currentDir = fm.currentDirectoryPath
        let resolvedProjectDir: String
        if let explicit = projectDir ?? EnvLoader.value(for: "ANDROID_PROJECT_DIR") {
            resolvedProjectDir = NSString(string: explicit).expandingTildeInPath
        } else if fm.fileExists(atPath: "\(currentDir)/android") {
            resolvedProjectDir = "\(currentDir)/android"
        } else {
            resolvedProjectDir = currentDir
        }

        // 2. Resolve package name (applicationId) & target app name
        let projectURL = URL(fileURLWithPath: resolvedProjectDir)
        let androidIdentifiers = try? AndroidTasks.getAndroidIdentifiers(workspaceRoot: projectURL)
        let detectedPackageName: String? = {
            let candidate = androidIdentifiers?.applicationId ?? androidIdentifiers?.packageName
            return (candidate?.isEmpty == false) ? candidate : nil
        }()
        let resolvedPackageName = packageName
            ?? EnvLoader.value(for: "GOOGLE_PACKAGE_NAME")
            ?? detectedPackageName

        let appName = AndroidTasks.resolveAppName(in: projectURL)
        let mainTarget: String
        if let appName, !appName.isEmpty {
            mainTarget = appName
        } else {
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

        let resolvedBuildType = configuration ?? EnvLoader.value(for: "ANDROID_CONFIGURATION") ?? "Release"
        let resolvedFlavor = flavor ?? EnvLoader.value(for: "ANDROID_FLAVOR")

        // 4. Resolve signing configuration
        var tempKeystoreUrl: URL? = nil
        defer {
            if let tempUrl = tempKeystoreUrl {
                try? fm.removeItem(at: tempUrl)
                let parentDir = tempUrl.deletingLastPathComponent()
                if let contents = try? fm.contentsOfDirectory(atPath: parentDir.path), contents.isEmpty {
                    try? fm.removeItem(at: parentDir)
                }
            }

            let keystoresDir = AppitoolPaths.androidKeystoresDirectory
            if let contents = try? fm.contentsOfDirectory(atPath: keystoresDir.path), contents.isEmpty {
                try? fm.removeItem(at: keystoresDir)
            }
        }

        let signingConfig: GradleTask.SigningConfig? = try await resolveSigningConfig(
            packageName: resolvedPackageName,
            buildType: resolvedBuildType,
            tempKeystoreUrl: &tempKeystoreUrl
        )

        // 5. Resolve opinionated output directory and artifact name
        let resolvedAndroidVersion = await AndroidTasks.resolveProjectVersion(
            in: projectURL,
            flavor: resolvedFlavor,
            identifiers: androidIdentifiers
        )
        let buildTagName = AppitoolPaths.buildTagName(
            version: resolvedAndroidVersion.versionName,
            buildNumber: resolvedAndroidVersion.versionCode,
            distribution: distribution
        )
        let resolvedOutputDir = AppitoolPaths.buildDirectory(
            platform: "android",
            target: mainTarget,
            name: buildTagName
        ).path

        let flavorSuffix = (resolvedFlavor?.isEmpty == false) ? "\(resolvedFlavor!)_" : ""
        let artifactBaseName = "\(mainTarget)_\(flavorSuffix)\(resolvedBuildType.lowercased())"

        // 6. Execute GradleTask
        let task = GradleTask()
        Log("\n" + "🏗️  Starting Android build for ".bold + "\(mainTarget)".cyan.bold + " (\(distribution.rawValue.capitalized))...".dim)
        if let pkg = resolvedPackageName {
            Log("   Package:     ".dim + "\(pkg)".yellow)
        }
        Log("   Output:      ".dim + "\(resolvedOutputDir)".bold)

        var gradleEnvironment: [String: String]? = nil
        if let gradleOpts, !gradleOpts.isEmpty {
            let finalGradleOpts = gradleOpts.contains("-Dorg.gradle.daemon=false") ? gradleOpts : "\(gradleOpts) -Dorg.gradle.daemon=false"
            gradleEnvironment = ["GRADLE_OPTS": finalGradleOpts]
        }

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
    }

    // MARK: - Signing Config Resolution

    private func resolveSigningConfig(
        packageName: String?,
        buildType: String,
        tempKeystoreUrl: inout URL?
    ) async throws -> GradleTask.SigningConfig? {
        let fm = FileManager.default

        var storeFilePath: String? = nil

        // If base64-encoded keystore is provided, write it to ~/.appitool/android/keystores/<packageName>.keystore or tmp
        if let base64 = keystoreBase64 ?? EnvLoader.value(for: "ANDROID_KEYSTORE"), !base64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) {
                let targetFile: URL
                if let pkg = packageName, !pkg.isEmpty {
                    let keystoresDir = AppitoolPaths.androidKeystoresDirectory
                    try? fm.createDirectory(at: keystoresDir, withIntermediateDirectories: true)
                    targetFile = AppitoolPaths.androidKeystoreFile(packageName: pkg)
                } else {
                    let tempDir = AppitoolPaths.platformDirectory("android").appendingPathComponent("tmp")
                    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    targetFile = tempDir.appendingPathComponent("keystore_\(UUID().uuidString).keystore")
                }
                try data.write(to: targetFile, options: .atomic)
                tempKeystoreUrl = targetFile
                storeFilePath = targetFile.path
            }
        }

        if storeFilePath == nil {
            if let explicitPath = keystorePath ?? EnvLoader.value(for: "ANDROID_KEYSTORE_PATH"), !explicitPath.isEmpty {
                storeFilePath = NSString(string: explicitPath).expandingTildeInPath
            }
        }

        let storePassword = keystorePassword ?? EnvLoader.value(for: "ANDROID_KEYSTORE_PASSWORD")
        let alias = keyAlias ?? EnvLoader.value(for: "ANDROID_KEY_ALIAS")
        let keyPass = keyPassword ?? EnvLoader.value(for: "ANDROID_KEY_PASSWORD")

        if let storeFilePath, let storePassword, let alias, let keyPass {
            return GradleTask.SigningConfig(
                storeFile: storeFilePath,
                storePassword: storePassword,
                keyAlias: alias,
                keyPassword: keyPass
            )
        }

        // Fallback: Resolve via Match if enabled or configured
        if storeFilePath == nil {
            let match = matchOptions.resolve()
            if (self.match || (match.gitUrl != nil && match.password != nil)),
               let gitUrl = match.gitUrl,
               let matchPassword = match.password,
               let targetPackage = packageName {
                let matchConfig = MatchAndroidConfig(
                    gitUrl: gitUrl,
                    gitBranch: match.gitBranch,
                    gitToken: match.gitToken,
                    password: matchPassword,
                    action: .sync,
                    packageName: targetPackage,
                    buildType: (buildType.lowercased() == "debug") ? .debug : .release,
                    alias: alias,
                    storePassword: storePassword,
                    keyPassword: keyPass,
                    silent: silent
                )
                if let result = try? await MatchRunner().runAndroid(matchConfig) {
                    tempKeystoreUrl = result.tempUrl
                    return result.signingConfig
                }
            }
        }

        return nil
    }
}
