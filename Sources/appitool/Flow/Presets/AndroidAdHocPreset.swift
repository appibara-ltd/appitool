import Foundation
import GoogleServices
import Rainbow

/// Preconfigured preset for building and distributing Android Ad-Hoc (APK or AAB) releases via Firebase App Distribution.
struct AndroidAdHocPreset: FlowPreset {
    let name: String = "Android AdHoc"
    let description: String =
        "Automated Android release flow configured for direct APK/AAB distribution via Firebase App Distribution."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements(
            [
                ("FIREBASE_ANDROID_APP_ID", context.firebaseAppId, "Firebase Android App ID"),
                ("GOOGLE_KEY", context.googleKey, "Google Service Account key for Firebase"),
            ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("🔍 Validating Firebase App Distribution and Android project setup...".dim)

        try await AndroidPresetHelpers.setupAndroidProject(context: &context)

        // 3. Resolve signing keystore via Match if available
        if context.androidSigningConfig == nil,
           let gitUrl = context.matchGitUrl,
           let password = context.matchPassword,
           let packageName = context.bundleId {
            Log("🔐 Resolving Android release keystore from Match storage...".dim)
            let matchConfig = MatchAndroidConfig(
                gitUrl: gitUrl,
                gitBranch: context.matchGitBranch ?? "master",
                gitToken: context.matchGitToken,
                password: password,
                action: .sync,
                packageName: packageName,
                buildType: .release,
                silent: context.silent
            )
            if let result = try? await MatchRunner().runAndroid(matchConfig) {
                context.androidSigningConfig = result.signingConfig
                context.androidSigningTempUrl = result.tempUrl
                Log("   ✓ Resolved signing keystore for '\(packageName)' from Match".green)
            }
        }

        guard let firebaseAppId = context.firebaseAppId, !firebaseAppId.isEmpty else { return }
        guard let googleKey = context.googleKey, !googleKey.isEmpty else { return }

        if let service = try? FirebaseService(key: googleKey) {
            if let buildInfo = try? await GetLatestBuildNumberTask().run(
                .init(
                    target: .android(
                        packageName: context.bundleId,
                        firebaseAppId: firebaseAppId,
                        firebaseService: service
                    ),
                    distribution: .adhoc
                )
            ) {
                context.metadata["firebase_version"] = buildInfo.version
                context.metadata["firebase_build_number"] = buildInfo.buildNumber
                Log("🟢 Retrieved Firebase build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)".green)
            }
        }
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("🔧 Resolving latest Firebase versionCode and bumping build...".dim)
        let baseCodeStr = context.metadata["firebase_build_number"] ?? context.buildNumber
        if let baseCodeStr, let baseCode = Int(baseCodeStr) {
            let nextCode = String(baseCode + 1)
            Log("🔢 Incrementing versionCode: \(baseCodeStr.bold) -> \(nextCode.bold.green)".dim)
            context.buildNumber = nextCode
        }
    }

    func build(context: inout FlowContext) async throws {
        let format = context.androidFormat ?? .apk
        let taskName = format == .aab ? "bundleRelease" : "assembleRelease"
        Log("🔨 Running Gradle \(taskName) to produce \(format.rawValue.uppercased())...".dim)

        if context.isDryRun {
            Log("🟡 Dry-run enabled: skipping Gradle build.".yellow)
            return
        }

        let projectDir = AndroidTasks.findAndroidRoot(in: context.projectDirectory)?.path ?? context.projectDirectory.path

        var properties: [String: String] = [:]
        if let versionCode = context.buildNumber {
            properties["versionCode"] = versionCode
        }
        if let versionName = context.version {
            properties["versionName"] = versionName
        }

        let targetName = context.targetName ?? context.bundleId ?? "AndroidApp"
        let outputDir = AppitoolPaths.buildDirectory(platform: "android", target: targetName).path
        let artifactName = "\(targetName)_release"

        let output = try await GradleTask().run(
            .init(
                projectDirectory: projectDir,
                buildType: "release",
                format: format,
                outputDirectory: outputDir,
                artifactName: artifactName,
                signing: context.androidSigningConfig,
                properties: properties,
                silent: context.silent
            )
        )

        let artifactPath = (format == .aab) ? output.aabPath : output.apkPath
        if let artifactPath {
            let artifactUrl = URL(fileURLWithPath: artifactPath)
            context.artifactPaths.append(artifactUrl)
            context.metadata["\(format.rawValue)_path"] = artifactPath
            Log("📦 Produced Android \(format.rawValue.uppercased()): \(artifactUrl.lastPathComponent)".green.bold)
        }
    }

    func postbuild(context: inout FlowContext) async throws {
        let format = context.androidFormat ?? .apk
        Log("📦 Verifying generated .\(format.rawValue) package integrity...".dim)
        guard let artifactUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == format.rawValue })
            ?? context.metadata["\(format.rawValue)_path"].map({ URL(fileURLWithPath: $0) }) else {
            return
        }
        if FileManager.default.fileExists(atPath: artifactUrl.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: artifactUrl.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            Log("   ✓ Verified \(format.rawValue.uppercased()) artifact: \(artifactUrl.lastPathComponent) (\(formattedSize))".dim)
        }
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("📝 Preparing tester release notes and distribution groups...".dim)
    }

    func release(context: inout FlowContext) async throws {
        let format = context.androidFormat ?? .apk
        Log("🚀 Distributing \(format.rawValue.uppercased()) to testers via Firebase App Distribution...".dim)

        context.metadata["firebase_test_groups"] = "internal"
        context.changelog = "APPITOOL TEST"

        guard let artifactUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == format.rawValue })
            ?? context.metadata["\(format.rawValue)_path"].map({ URL(fileURLWithPath: $0) }) else {
            Log("🚧 No .\(format.rawValue) package found in context artifacts to upload.".yellow)
            return
        }

        guard let firebaseAppId = context.firebaseAppId, !firebaseAppId.isEmpty else {
            throw FlowRequirementError(presetName: name, missing: ["FIREBASE_ANDROID_APP_ID"])
        }
        guard let googleKey = context.googleKey, !googleKey.isEmpty else {
            throw FlowRequirementError(presetName: name, missing: ["GOOGLE_KEY"])
        }

        if context.isDryRun {
            Log("🟡 Dry-run enabled: would upload \(artifactUrl.lastPathComponent) to Firebase App Distribution (\(firebaseAppId)).".yellow)
            return
        }

        let firebaseService = try FirebaseService(key: googleKey)

        let releaseNotes = context.changelog ?? context.metadata["release_notes"]
        let testGroups: [String]? = {
            if let groupsStr = context.metadata["firebase_test_groups"]
                ?? context.metadata["test_groups"] {
                return groupsStr.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            return nil
        }()

        let testerEmails: [String]? = {
            if let emailsStr = context.metadata["firebase_tester_emails"]
                ?? context.metadata["tester_emails"] {
                return emailsStr.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            return nil
        }()

        // Ensure configured test groups exist before upload and resolve their actual aliases
        var resolvedTestGroups: [String] = []
        if let testGroups, !testGroups.isEmpty {
            for group in testGroups {
                let g = try await firebaseService.createOrGetGroup(
                    project: firebaseAppId,
                    groupAlias: group
                )
                let alias = g.name?.components(separatedBy: "/").last ?? group
                resolvedTestGroups.append(alias)
            }
        }

        let result = try await UploadToFirebaseTask().run(
            .init(
                binaryPath: artifactUrl.path,
                firebaseAppId: firebaseAppId,
                service: firebaseService,
                releaseNotes: releaseNotes,
                testGroups: resolvedTestGroups.isEmpty ? testGroups : resolvedTestGroups,
                testerEmails: testerEmails
            )
        )

        context.metadata["firebase_release_name"] = result.releaseName
        if let consoleUri = result.firebaseConsoleUri {
            context.metadata["firebase_console_uri"] = consoleUri
            Log("🔗 Firebase Console: \(consoleUri)".cyan)
        }
        if let downloadUri = result.binaryDownloadUri {
            context.metadata["firebase_download_uri"] = downloadUri
        }
        if let testingUri = result.testingUri {
            context.metadata["firebase_testing_uri"] = testingUri
        }

        Log("🟢 Successfully distributed \(format.rawValue.uppercased()) to Firebase App Distribution!".green.bold)
    }
}
