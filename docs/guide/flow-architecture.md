# Flow Architecture

`appitool flow` is an opinionated release orchestration engine inspired by Fastlane lanes. Every flow execution transitions sequentially through a standardized 7-stage lifecycle backed by a shared `FlowContext` and a strict error boundary in `FlowRunner`.

## The 7-Stage Pipeline

```text
┌─────────┐   ┌──────────┐   ┌─────────┐   ┌───────────┐   ┌────────────┐   ┌───────────┐   ┌─────────────┐
│  setup  │──▶│ prebuild │──▶│  build  │──▶│ postbuild │──▶│ prerelease │──▶│  release  │──▶│ postrelease │
└─────────┘   └──────────┘   └─────────┘   └───────────┘   └────────────┘   └───────────┘   └─────────────┘
```

| # | Stage (`FlowStage`) | Emoji | Display Name | Core Responsibilities |
|:---:|:---|:---:|:---|:---|
| 1 | `setup` | 🔍 | Setup & Environment | Inspect project (`Xcode` / `Gradle`), resolve bundle ID / package name, sync Match certs/profiles or keystore, fetch latest remote build number. |
| 2 | `prebuild` | 🔧 | Pre-Build & Versioning | Compute next build number / `versionCode` (`max(remote, local) + 1` via `BuildNumberPolicy`), snapshot `project.pbxproj`, apply temporary manual code signing to Xcode targets, and normalize literal `Info.plist` `CFBundleVersion` entries to `$(CURRENT_PROJECT_VERSION)` via `XCodeTasks.updateBuildNumber`. |
| 3 | `build` | 🔨 | Build Compilation | Run `xcodebuild` (injecting `CURRENT_PROJECT_VERSION=<buildNumber>` for `.xcarchive`, `.ipa`, and dSYM, then restoring `project.pbxproj` and any temporary `Info.plist` edits in `defer`) or `./gradlew` (`bundleRelease` / `assembleRelease`) and record artifact paths in `FlowContext`. |
| 4 | `postbuild` | 📦 | Post-Build | Verify that the generated `.ipa`, `.aab`, or `.apk` artifact exists on disk, is non-empty, and log its file size. |
| 5 | `prerelease` | 📝 | Pre-Release | Generate plain-text store release notes via `GenerateReleaseNotesTask` using platform tag prefix (`🍏_` for iOS, `🤖_` for Android) and store character limits (left empty if `HEAD` already sits on a matching tag); supports `--release-notes`, `--notes-from`, and `--notes-locale` overrides and logs the resolved source and preview. |
| 6 | `release` | 🚀 | Release & Store Upload | Upload binary to App Store Connect / TestFlight, Google Play Console `internal` track, or Firebase App Distribution. |
| 7 | `postrelease` | 📣 | Post-Release & Notifications | Create & push the release Git tag (`🍏_<version>_<buildNumber>[_adhoc]` / `🤖_<version>_<buildNumber>[_adhoc]`) via `GitTagTask` and dispatch completion notifications to configured Slack and KokoNo webhooks (previewed / skipped in `--dry-run` mode). |

---

## Built-in Flow Presets

Choosing a platform (`ios` / `android`) and distribution (`appstore`, `adhoc`, `development`) automatically selects a `FlowPreset`:

| Command Invocation | Preset | Target Destination |
|:---|:---|:---|
| `flow ios -d appstore` | `IOSInternalPreset` (`iOS Internal`) | App Store Connect / TestFlight |
| `flow ios -d adhoc` or `-d development` | `IOSAdHocPreset` (`iOS AdHoc`) | Firebase App Distribution (`internal` group) |
| `flow android -d appstore` | `AndroidInternalPreset` (`Android Internal`) | Google Play Console (`internal` track) |
| `flow android -d adhoc` or `-d development` | `AndroidAdHocPreset` (`Android AdHoc`) | Firebase App Distribution (`internal` group) |

> Presets share stage implementations and only supply what differs per destination. Sources are grouped by platform under `Sources/appitool/Flow/Presets/`:
> `iOS/IOSPresetHelpers.swift` (project detection, Match sync, manual signing + build-number bump, archive/export),
> `Android/AndroidPresetHelpers.swift` (project/flavor detection, Gradle build), and
> `Shared/FirebasePresetHelpers.swift` (Firebase upload/distribution used by both ad-hoc presets).

### 1. `IOSInternalPreset` (`flow ios -d appstore`)

- **Required Configuration (`requirements`)**:
  - `APPLE_KEY_ID`
  - `APPLE_ISSUER_ID`
  - `APPLE_KEY`
  - `MATCH_GIT_URL`
  - `MATCH_PASSWORD`
- **Stage Execution**:
  - `setup`: Detects `.xcworkspace`/`.xcodeproj`, scheme, configuration, main target, bundle ID, and project version. Runs `MatchTask` with `type: .appstore` (forced `readonly` when `--dry-run` is set). Queries App Store Connect (`GetLatestBuildNumberTask`) for the latest TestFlight build number.
  - `prebuild`: Extracts signing identity (`iPhone Distribution` or `Apple Distribution`) and Team ID from installed certificates. Snapshots `project.pbxproj`, configures manual code signing per target via `XCodeTasks.configureManualSigning`, computes `max(appstore_build_number, project build number) + 1` in `context.buildNumber`, and calls `XCodeTasks.updateBuildNumber` to normalize literal `Info.plist` `CFBundleVersion` values to `$(CURRENT_PROJECT_VERSION)` without editing `project.pbxproj` (permanently when `CURRENT_PROJECT_VERSION` is already defined in `project.pbxproj`, or registered for post-build restore otherwise; skipped in `--dry-run`).
  - `build`: Prepares macOS keychain (`KeychainManager`), compiles `.xcarchive` (passing `CURRENT_PROJECT_VERSION=<buildNumber>`) and exports `.ipa` with `.appStore` export method and manual signing via `XcodeBuildTask`, restoring `project.pbxproj` and any temporary `Info.plist` edits immediately in `defer` (skipped in `--dry-run`).
  - `postbuild`: Verifies `.ipa` existence and non-zero file size (skipped in `--dry-run`).
  - `prerelease`: Generates plain-text release notes (max 4,000 chars) from commits since the latest `🍏_*` tag (excluding `*_adhoc` / `*_development`) via `GenerateReleaseNotesTask`.
  - `release`: Uploads `.ipa` via `UploadToAppStoreTask`, waits for App Store Connect build processing (unless `--no-wait-processing` is passed), and sets TestFlight "What to Test" notes via `setWhatsNew` when `changelog` is populated.
  - `postrelease`: Creates and pushes Git tag `🍏_<version>_<buildNumber>` via `GitTagTask` and dispatches Slack/KokoNo notifications (skipped in `--dry-run`).

### 2. `IOSAdHocPreset` (`flow ios -d adhoc` / `development`)

- **Required Configuration (`requirements`)**:
  - `MATCH_GIT_URL`
  - `MATCH_PASSWORD`
  - `FIREBASE_IOS_APP_ID`
  - `GOOGLE_KEY`
- **Stage Execution**:
  - `setup`: Inspects iOS project, runs `MatchTask` with `type: .adhoc`, and queries Firebase App Distribution (`GetLatestBuildNumberTask`) for the latest build number.
  - `prebuild`: Snapshots `project.pbxproj`, configures manual signing on Xcode targets, computes `max(firebase_build_number, project build number) + 1` in `context.buildNumber`, and normalizes literal `Info.plist` `CFBundleVersion` values to `$(CURRENT_PROJECT_VERSION)` via `XCodeTasks.updateBuildNumber` (kept permanently when `CURRENT_PROJECT_VERSION` exists in `project.pbxproj`, or registered for post-build restore otherwise; skipped in `--dry-run`).
  - `build`: Prepares keychain, builds `.xcarchive` (passing `CURRENT_PROJECT_VERSION=<buildNumber>`) and exports `.ipa` with `.adHoc` export method, restoring `project.pbxproj` and temporary `Info.plist` edits immediately in `defer` (skipped in `--dry-run`).
  - `postbuild`: Verifies `.ipa` existence and non-zero file size (skipped in `--dry-run`).
  - `prerelease`: Generates plain-text release notes (max 4,000 chars) from commits since the latest `🍏_*` tag via `GenerateReleaseNotesTask`.
  - `release`: Uploads the `.ipa` with generated release notes via the shared `FirebasePresetHelpers.distribute`, which runs `UploadToFirebaseTask` with `ensureGroupsExist` so the `internal` tester group is created on Firebase (`createOrGetGroup`) before upload.
  - `postrelease`: Creates and pushes Git tag `🍏_<version>_<buildNumber>_adhoc` (or `_development`) via `GitTagTask` and dispatches success notification to configured Slack and KokoNo webhooks (skipped in `--dry-run`).

### 3. `AndroidInternalPreset` (`flow android -d appstore`)

- **Required Configuration (`requirements`)**:
  - `GOOGLE_KEY`
- **Stage Execution**:
  - `setup`: Extracts `packageName`, `applicationId`, `namespace`, `versionName`, `versionCode`, and flavors via regex (`AndroidTasks.getAndroidIdentifiers`) and Gradle evaluation (`evaluateAppInfoViaGradle`). When `--flavor` / `ANDROID_FLAVOR` is set, the selected flavor's effective `applicationId` (unless `--package-name` is given), `versionName`, and `versionCode` are used, and a warning is logged if the flavor is not found. If `MATCH_GIT_URL` and `MATCH_PASSWORD` are configured, resolves the release keystore via `AndroidPresetHelpers.resolveMatchKeystore` (the flow fails if the package name is unknown or the Match lookup fails, instead of building unsigned). Queries Google Play Console (`internal` track) for the latest `versionCode`.
  - `prebuild`: Sets `versionCode` to `max(googleplay_version_code, project versionCode) + 1` in `context.buildNumber`.
  - `build`: Executes Gradle `bundleRelease` (or `bundle<Flavor>Release` with `--flavor`) producing an `.aab` with `-PversionCode` and `-PversionName` plus Match signing config if present.
  - `postbuild`: Verifies `.aab` existence and logs file size.
  - `prerelease`: Generates plain-text release notes (max 500 chars for Google Play) from commits since the latest `🤖_*` tag (excluding `*_adhoc` / `*_development`) via `GenerateReleaseNotesTask`.
  - `release`: Uploads `.aab` and generated release notes to Google Play Console `internal` track with `releaseStatus: .completed` via `UploadToGooglePlayConsoleTask`.
  - `postrelease`: Creates and pushes Git tag `🤖_<version>_<buildNumber>` via `GitTagTask` and dispatches success notification to Slack and KokoNo webhooks (skipped in `--dry-run`).

### 4. `AndroidAdHocPreset` (`flow android -d adhoc` / `development`)

- **Required Configuration (`requirements`)**:
  - `FIREBASE_ANDROID_APP_ID`
  - `GOOGLE_KEY`
- **Stage Execution**:
  - `setup`: Inspects Android project, resolves the release keystore from Match when configured (failing the flow if the lookup fails), and retrieves latest Firebase App Distribution build info.
  - `prebuild`: Sets `versionCode` to `max(firebase_build_number, project versionCode) + 1`.
  - `build`: Runs Gradle `assembleRelease` (default `.apk` for `adhoc`/`development`) or `bundleRelease` (if `--format aab` is specified); with `--flavor`, runs `assemble<Flavor>Release` / `bundle<Flavor>Release`.
  - `postbuild`: Verifies artifact file integrity and logs size.
  - `prerelease`: Generates plain-text release notes (max 4,000 chars) from commits since the latest `🤖_*` tag via `GenerateReleaseNotesTask`.
  - `release`: Uploads the `.apk`/`.aab` with generated release notes via the shared `FirebasePresetHelpers.distribute` (same as iOS Ad-Hoc), which runs `UploadToFirebaseTask` with `ensureGroupsExist` so the `internal` tester group is created before upload.
  - `postrelease`: Creates and pushes Git tag `🤖_<version>_<buildNumber>_adhoc` (or `_development`) via `GitTagTask` and dispatches success notification to Slack and KokoNo webhooks (skipped in `--dry-run`).

---

## Global Error Boundary & Cleanup

`FlowRunner` wraps all stage execution inside a unified error boundary:

- **Pre-flight Validation**: `preset.requirements(context:)` runs before any stage executes, throwing `FlowRequirementError` with the full list of missing configuration keys.
- **Temporary File & Keystore Cleanup**: `TemporaryFileRestorer` (owned by `FlowContext.fileRestorer`) snapshots `project.pbxproj` before signing mutations and any temporary `Info.plist` edits made when `CURRENT_PROJECT_VERSION` is missing in `project.pbxproj`; iOS `build` restores them in `defer` and `FlowRunner`'s `defer` block (plus `SIGINT`/`SIGTERM` signal handlers) acts as an emergency fallback if a stage exits early. For Android, any temporary keystore decrypted by Match (`context.androidSigningTempUrl`) and empty `~/.appitool/android/keystores` directories are deleted automatically.
- **Failure Handling**: If any stage throws:
  1. Pipeline execution halts immediately.
  2. `FlowRunner` prints a highlighted banner showing the failing stage (`context.currentStage`) and error reason.
  3. `NotifyTask().notifyAllConfigured(status: .failure, ...)` dispatches failure alerts to Slack and KokoNo containing `Platform`, `Distribution`, `Failing Stage`, `Elapsed Time`, and `Bundle ID` / `Package Name` (skipped when `--dry-run` is active).
- **Success Summary**: Upon completing all configured stages, `FlowRunner` prints total elapsed time and per-stage durations.
