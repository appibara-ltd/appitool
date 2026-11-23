import Foundation
import GoogleServices
import Rainbow

/// Shared Firebase App Distribution logic for ad-hoc and development presets (iOS `.ipa`, Android `.apk`/`.aab`).
enum FirebasePresetHelpers {
    // MARK: - Setup: Latest build lookup

    /// Fetches the latest Firebase App Distribution release for the context's platform and stores it in
    /// `context.metadata["firebase_version"]` / `["firebase_build_number"]` (used by the build-number bump).
    ///
    /// An app with no releases yet resolves to build `0`. Throws `FlowRequirementError` when the Firebase App ID or
    /// Google key is missing, and rethrows lookup failures (e.g. invalid credentials) instead of silently continuing.
    ///
    /// - Parameters:
    ///   - presetName: Preset name used in `FlowRequirementError` messages.
    ///   - appIdKey: `.env` key reported when the Firebase App ID is missing (e.g. `FIREBASE_IOS_APP_ID`).
    static func fetchLatestBuild(context: inout FlowContext, presetName: String, appIdKey: String) async throws {
        Log("🔥 Fetching latest build info from Firebase App Distribution...".dim)

        guard let firebaseAppId = CLIValues.trimmedNonEmpty(context.firebaseAppId) else {
            throw FlowRequirementError(presetName: presetName, missing: [appIdKey])
        }
        guard let googleKey = CLIValues.trimmedNonEmpty(context.googleKey) else {
            throw FlowRequirementError(presetName: presetName, missing: ["GOOGLE_KEY"])
        }
        let firebaseService = try FirebaseService(key: googleKey)

        let target: GetLatestBuildNumberTask.Input.Target
        switch context.platform {
        case .ios:
            target = .ios(bundleId: context.bundleId, firebaseAppId: firebaseAppId, firebaseService: firebaseService)
        case .android:
            target = .android(packageName: context.bundleId, firebaseAppId: firebaseAppId, firebaseService: firebaseService)
        }

        // `GetLatestBuildNumberTask` resolves Firebase builds through the `.adhoc` distribution path
        // (also for development presets, which use the same Firebase app).
        let buildInfo = try await GetLatestBuildNumberTask().run(.init(target: target, distribution: .adhoc))

        context.metadata["firebase_version"] = buildInfo.version
        context.metadata["firebase_build_number"] = buildInfo.buildNumber
        Log("🟢 Retrieved Firebase build info: Version: \(buildInfo.version.bold), Build Number: \(buildInfo.buildNumber.bold)".green)
    }

    // MARK: - Release: Upload & distribution

    /// Uploads the built artifact to Firebase App Distribution and distributes it to testers.
    ///
    /// - Reads tester groups from `firebase_test_groups` / `test_groups` and emails from
    ///   `firebase_tester_emails` / `tester_emails` in `context.metadata` (comma-separated).
    /// - Creates missing tester groups before upload and distributes to their actual aliases.
    /// - Honors `--dry-run` and writes release details back into `context.metadata`.
    ///
    /// - Parameters:
    ///   - presetName: Preset name used in `FlowRequirementError` messages.
    ///   - artifactExtension: Artifact file extension to upload (`ipa`, `apk`, or `aab`); also used for the
    ///     `<ext>_path` metadata fallback.
    ///   - artifactLabel: Human-readable artifact label for logs (e.g. `IPA`, `APK`).
    ///   - appIdKey: `.env` key reported when the Firebase App ID is missing (e.g. `FIREBASE_IOS_APP_ID`).
    ///   - defaultTestGroups: Comma-separated tester groups assigned to `firebase_test_groups` before upload.
    static func distribute(
        context: inout FlowContext,
        presetName: String,
        artifactExtension: String,
        artifactLabel: String,
        appIdKey: String,
        defaultTestGroups: String = "internal"
    ) async throws {
        Log("🚀 Distributing \(artifactLabel) to testers via Firebase App Distribution...".dim)

        context.metadata["firebase_test_groups"] = defaultTestGroups

        let ext = artifactExtension.lowercased()
        guard let artifactUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == ext })
            ?? context.metadata["\(ext)_path"].map({ URL(fileURLWithPath: $0) }) else {
            Log("🚧 No .\(ext) package found in context artifacts to upload.".yellow)
            return
        }

        guard let firebaseAppId = CLIValues.trimmedNonEmpty(context.firebaseAppId) else {
            throw FlowRequirementError(presetName: presetName, missing: [appIdKey])
        }
        guard let googleKey = CLIValues.trimmedNonEmpty(context.googleKey) else {
            throw FlowRequirementError(presetName: presetName, missing: ["GOOGLE_KEY"])
        }

        if context.isDryRun {
            Log("🟡 Dry-run enabled: would upload \(artifactUrl.lastPathComponent) to Firebase App Distribution (\(firebaseAppId)).".yellow)
            return
        }

        let firebaseService = try FirebaseService(key: googleKey)
        let releaseNotes = context.changelog ?? context.metadata["release_notes"]
        let testGroups = CLIValues.commaSeparatedOrNil(
            context.metadata["firebase_test_groups"] ?? context.metadata["test_groups"]
        )
        let testerEmails = CLIValues.commaSeparatedOrNil(
            context.metadata["firebase_tester_emails"] ?? context.metadata["tester_emails"]
        )

        let result = try await UploadToFirebaseTask().run(
            .init(
                binaryPath: artifactUrl.path,
                firebaseAppId: firebaseAppId,
                service: firebaseService,
                releaseNotes: releaseNotes,
                testGroups: testGroups,
                testerEmails: testerEmails,
                ensureGroupsExist: true
            )
        )

        if let version = result.displayVersion, !version.isEmpty {
            context.version ??= version
        }
        if let build = result.buildVersion, !build.isEmpty {
            context.buildNumber ??= build
        }
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

        Log("🟢 Successfully distributed \(artifactLabel) to Firebase App Distribution!".green.bold)
    }
}
