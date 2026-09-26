# Appitool Flow Architecture

## 1. Overview & Philosophy

`appitool flow` is an opinionated, automated release orchestration pipeline inspired by Fastlane lanes, designed with a standardized, predictable 7-stage lifecycle.

Unlike unstructured scripts, every flow follows an identical stage progression across all platforms (iOS & Android). This enforces consistent CI/CD execution, deterministic artifact generation, and centralized error handling with automated webhook notifications.

---

## 2. Standard Flow Lifecycle

Every execution of `appitool flow ios` or `appitool flow android` transitions sequentially through the following 7 stages:

```
┌─────────┐   ┌──────────┐   ┌─────────┐   ┌───────────┐   ┌────────────┐   ┌───────────┐   ┌─────────────┐
│  setup  │──▶│ prebuild │──▶│  build  │──▶│ postbuild │──▶│ prerelease │──▶│  release  │──▶│ postrelease │
└─────────┘   └──────────┘   └─────────┘   └───────────┘   └────────────┘   └───────────┘   └─────────────┘
     │              │              │              │              │               │                 │
     ▼              ▼              ▼              ▼              ▼               ▼                 ▼
  Fail Early    Bump Build     xcodebuild     Collect &       Generate       Upload to         Success
  & Validate    Number +1       / gradle     Verify Build     Changelog    TestFlight/Play    Notification
     Env       Config State      Runner       Artifacts      & Packaging     & Firebase         & Summary
```

---

### Stage 1: `setup`
- **Objective:** Fail fast if environment, project, or credentials are invalid.
- **Responsibilities:**
  - Verify environment variables (`.env`, system environment).
  - Detect and validate mobile project in current working directory (Xcode project/workspace for iOS, Gradle project for Android).
  - Check platform SDK and tooling availability (`xcodebuild`, `xcrun`, `gradle`, Java version).
  - Validate store credentials (API keys, Service Accounts, Firebase tokens) required for the target distribution.
  - Halt immediately with actionable diagnosis if any requirement is missing.

---

### Stage 2: `prebuild`
- **Objective:** Prepare project configuration and versioning before compilation.
- **Responsibilities:**
  - Retrieve the latest remote build number using `GetLatestBuildNumberTask` (TestFlight, Play Console, or Firebase App Distribution).
  - Compute next version code / build number (`current + 1`).
  - Update project build settings, `Info.plist`, or `build.gradle` / `version.properties`.
  - Apply build flavors, schemes, bundle IDs, or provisioning profiles according to distribution method (`appstore`, `adhoc`, `development`).

---

### Stage 3: `build`
- **Objective:** Execute platform-specific build compilers.
- **Responsibilities:**
  - **iOS:** Execute `xcodebuild` archive with scheme, configuration, code signing, and export options (`.ipa`, `.xcarchive`, `.dSYM`).
  - **Android:** Execute `./gradlew` assemble/bundle tasks (`assembleRelease`, `bundleRelease`) with keystore signing.
  - Stream logs with formatting and capture compilation diagnostics.

---

### Stage 4: `postbuild`
- **Objective:** Verify compilation outputs and organize artifacts.
- **Responsibilities:**
  - Verify generated binaries exist and validate file integrity / size (non-zero bytes).
  - Collect and structure artifacts into a unified output directory (e.g., `build/outputs/appitool/{platform}/{distribution}/`).
  - Extract and verify metadata from generated binary (bundle ID, package name, version, build number).

---

### Stage 5: `prerelease`
- **Objective:** Prepare distribution assets and release documentation.
- **Responsibilities:**
  - Generate automated changelog (git commit logs between releases, conventional commit parsing).
  - Compress or archive symbol files (dSYM zip, ProGuard mapping file).
  - Prepare release notes per locale / store requirements.

---

### Stage 6: `release`
- **Objective:** Deploy build artifacts to target distribution channels.
- **Responsibilities:**
  - **Ad-Hoc Distribution:** Upload `.ipa` or `.apk` to Firebase App Distribution with release notes and tester groups.
  - **App Store Distribution:**
    - iOS: Upload `.ipa` to App Store Connect / TestFlight via App Store Connect API.
    - Android: Upload `.aab` to Google Play Console track (internal, alpha, beta, production) via Google Play Developer API.
  - **GitHub Release (Optional):** Create a tagged release with attached binary assets.

---

### Stage 7: `postrelease`
- **Objective:** Report completion, publish metrics, and notify teams.
- **Responsibilities:**
  - Send success notification webhooks (Slack, KokoNo, etc.) with release metadata, download links, build duration, and changelog.
  - Print consolidated summary table in terminal.
  - Clean up temporary build artifacts or restore working tree if temporary version bumps were applied.

---

## 3. Global Error Boundary & Fail Notifications

The entire flow pipeline is encapsulated in a strict error boundary:

```
┌────────────────────────────────────────────────────────┐
│                      FlowRunner                        │
│                                                        │
│   try {                                                │
│       for stage in [setup, prebuild, ..., postrelease] │
│           stage.execute(context)                       │
│   } catch (error) {                                    │
│       handleFailure(error, currentStage, context)      │
│       notifyWebhooks(failurePayload)                   │
│       printFailureSummary()                            │
│       exit(1)                                          │
│   }                                                    │
└────────────────────────────────────────────────────────┘
```

When an error occurs at **any** stage:
1. Execution halts immediately to prevent corrupt or partial releases.
2. The failing stage, error reason, elapsed duration, and git metadata are captured.
3. A failure webhook payload is dispatched to configured alert channels (e.g., Slack, KokoNo).
4. A structured failure diagnostic is printed to the terminal.

---

## 4. CLI Command Syntax

```bash
# iOS Flow
appitool flow ios -d <distribution> [options]
appitool flow ios --distribution appstore
appitool flow ios --distribution adhoc

# Android Flow
appitool flow android -d <distribution> [options]
appitool flow android --distribution appstore
appitool flow android --distribution adhoc
```

### Supported Distribution Options
- `appstore`: Apple TestFlight / Google Play Console
- `adhoc`: Firebase App Distribution
- `development`: Local development build validation

---

## 5. Directory & File Structure

```
Sources/appitool/
├── Commands/
│   └── Flow/
│       ├── FlowCommand.swift           # Root 'flow' command
│       ├── FlowIOSCommand.swift        # 'flow ios' subcommand
│       └── FlowAndroidCommand.swift    # 'flow android' subcommand
└── Flow/
    ├── FlowStage.swift                 # Enum of 7 standard lifecycle stages
    ├── FlowContext.swift               # State container passed across stages
    ├── FlowRunner.swift                # Engine orchestrating stages & error handling
    └── Stages/                         # Default stage implementations
        ├── SetupStage.swift
        ├── PreBuildStage.swift
        ├── BuildStage.swift
        ├── PostBuildStage.swift
        ├── PreReleaseStage.swift
        ├── ReleaseStage.swift
        └── PostReleaseStage.swift
```
