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
| 2 | `prebuild` | 🔧 | Pre-Build & Versioning | Compute next build number / `versionCode` (`remote + 1`), apply manual code signing settings to Xcode targets, bump iOS build number. |
| 3 | `build` | 🔨 | Build Compilation | Run `xcodebuild` (`.xcarchive` + `.ipa` + dSYM) or `./gradlew` (`bundleRelease` / `assembleRelease`) and record artifact paths in `FlowContext`. |
| 4 | `postbuild` | 📦 | Post-Build | Verify that the generated `.ipa`, `.aab`, or `.apk` artifact exists on disk, is non-empty, and log its file size. |
| 5 | `prerelease` | 📝 | Pre-Release | Generate plain-text store release notes via `GenerateReleaseNotesTask` using platform tag prefix (`🍏_` for iOS, `🤖_` for Android) and store character limits. |
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

### 1. `IOSInternalPreset` (`flow ios -d appstore`)

- **Required Configuration (`requirements`)**:
  - `APPLE_KEY_ID`
  - `APPLE_ISSUER_ID`
  - `APPLE_KEY`
  - `MATCH_GIT_URL`
  - `MATCH_PASSWORD`
- **Stage Execution**:
  - `setup`: Detects `.xcworkspace`/`.xcodeproj`, scheme, configuration, main target, bundle ID, and project version. Runs `MatchTask` with `type: .appstore` (forced `readonly` when `--dry-run` is set). Queries App Store Connect (`GetLatestBuildNumberTask`) for the latest TestFlight build number.
  - `prebuild`: Extracts signing identity (`iPhone Distribution` or `Apple Distribution`) and Team ID from installed certificates. Configures manual code signing per target via `XCodeTasks.configureManualSigning` and increments build number (`appstore_build_number + 1`) in Xcode project (skipped in `--dry-run`).
  - `build`: Prepares macOS keychain (`KeychainManager`), compiles `.xcarchive` and exports `.ipa` with `.appStore` export method and manual signing via `XcodeBuildTask` (skipped in `--dry-run`).
  - `postbuild`: Verifies `.ipa` existence and non-zero file size (skipped in `--dry-run`).
  - `prerelease`: Generates plain-text release notes (max 4,000 chars) from commits since the latest `🍏_*` tag (excluding `*_adhoc` / `*_development`) via `GenerateReleaseNotesTask`.
  - `release`: Uploads `.ipa` via `UploadToAppStoreTask` and sets TestFlight "What to Test" notes via `setWhatsNew` when `changelog` is populated (unless `--no-wait-processing` is passed).
  - `postrelease`: Creates and pushes Git tag `🍏_<version>_<buildNumber>` via `GitTagTask` and dispatches Slack/KokoNo notifications (skipped in `--dry-run`).

### 2. `IOSAdHocPreset` (`flow ios -d adhoc` / `development`)

- **Required Configuration (`requirements`)**:
  - `MATCH_GIT_URL`
  - `MATCH_PASSWORD`
  - `FIREBASE_IOS_APP_ID`
  - `GOOGLE_KEY`
- **Stage Execution**:
  - `setup`: Inspects iOS project, runs `MatchTask` with `type: .adhoc`, and queries Firebase App Distribution (`GetLatestBuildNumberTask`) for the latest build number.
  - `prebuild`: Configures manual signing on Xcode targets and increments build number (`firebase_build_number + 1`) unless `--dry-run`.
  - `build`: Prepares keychain and builds `.ipa` with `.adHoc` export method.
  - `postbuild`: Verifies `.ipa` existence and non-zero file size (skipped in `--dry-run`).
  - `prerelease`: Generates plain-text release notes (max 4,000 chars) from commits since the latest `🍏_*` tag via `GenerateReleaseNotesTask`.
  - `release`: Ensures tester group `internal` exists on Firebase (`createOrGetGroup`) and uploads the `.ipa` with generated release notes via `UploadToFirebaseTask`.
  - `postrelease`: Creates and pushes Git tag `🍏_<version>_<buildNumber>_adhoc` (or `_development`) via `GitTagTask` and dispatches success notification to configured Slack and KokoNo webhooks (skipped in `--dry-run`).

### 3. `AndroidInternalPreset` (`flow android -d appstore`)

- **Required Configuration (`requirements`)**:
  - `GOOGLE_KEY`
- **Stage Execution**:
  - `setup`: Extracts `packageName`, `applicationId`, `namespace`, `versionName`, `versionCode`, and flavors via regex (`AndroidTasks.getAndroidIdentifiers`) and Gradle evaluation (`evaluateAppInfoViaGradle`). If `MATCH_GIT_URL` and `MATCH_PASSWORD` are configured, resolves the release keystore via `MatchRunner().runAndroid`. Queries Google Play Console (`internal` track) for the latest `versionCode`.
  - `prebuild`: Computes `nextCode = baseCode + 1` in `context.buildNumber`.
  - `build`: Executes Gradle `bundleRelease` producing an `.aab` with `-PversionCode` and `-PversionName` plus Match signing config if present.
  - `postbuild`: Verifies `.aab` existence and logs file size.
  - `prerelease`: Generates plain-text release notes (max 500 chars for Google Play) from commits since the latest `🤖_*` tag (excluding `*_adhoc` / `*_development`) via `GenerateReleaseNotesTask`.
  - `release`: Uploads `.aab` and generated release notes to Google Play Console `internal` track with `releaseStatus: .completed` via `UploadToGooglePlayConsoleTask`.
  - `postrelease`: Creates and pushes Git tag `🤖_<version>_<buildNumber>` via `GitTagTask` and dispatches success notification to Slack and KokoNo webhooks (skipped in `--dry-run`).

### 4. `AndroidAdHocPreset` (`flow android -d adhoc` / `development`)

- **Required Configuration (`requirements`)**:
  - `FIREBASE_ANDROID_APP_ID`
  - `GOOGLE_KEY`
- **Stage Execution**:
  - `setup`: Inspects Android project, optionally resolves release keystore from Match, and retrieves latest Firebase App Distribution build info.
  - `prebuild`: Increments `versionCode` by `+1`.
  - `build`: Runs Gradle `assembleRelease` (default `.apk` for `adhoc`/`development`) or `bundleRelease` (if `-f aab` is specified).
  - `postbuild`: Verifies artifact file integrity and logs size.
  - `prerelease`: Generates plain-text release notes (max 4,000 chars) from commits since the latest `🤖_*` tag via `GenerateReleaseNotesTask`.
  - `release`: Ensures `internal` tester group exists and uploads binary with generated release notes via `UploadToFirebaseTask`.
  - `postrelease`: Creates and pushes Git tag `🤖_<version>_<buildNumber>_adhoc` (or `_development`) via `GitTagTask` and dispatches success notification to Slack and KokoNo webhooks (skipped in `--dry-run`).

---

## Global Error Boundary & Cleanup

`FlowRunner` wraps all stage execution inside a unified error boundary:

- **Pre-flight Validation**: `preset.requirements(context:)` runs before any stage executes, throwing `FlowRequirementError` with the full list of missing configuration keys.
- **Temporary Keystore Cleanup**: In `defer`, any temporary keystore decrypted by Match for Android (`context.androidSigningTempUrl`) and empty `~/.appitool/android/keystores` directories are deleted automatically.
- **Failure Handling**: If any stage throws:
  1. Pipeline execution halts immediately.
  2. `FlowRunner` prints a highlighted banner showing the failing stage (`context.currentStage`) and error reason.
  3. `NotifyTask().notifyAllConfigured(status: .failure, ...)` dispatches failure alerts to Slack and KokoNo containing `Platform`, `Distribution`, `Failing Stage`, `Elapsed Time`, and `Bundle ID` / `Package Name` (skipped when `--dry-run` is active).
- **Success Summary**: Upon completing all configured stages, `FlowRunner` prints total elapsed time and per-stage durations.
