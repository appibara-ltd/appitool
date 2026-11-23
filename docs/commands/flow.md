# `appitool flow`

Executes the automated 7-stage release orchestration pipeline (`setup` → `prebuild` → `build` → `postbuild` → `prerelease` → `release` → `postrelease`) with centralized error handling and webhook alerts.

## Synopsis

```bash
appitool flow ios [options]
appitool flow android [options]
```

See [Flow Architecture](/guide/flow-architecture) for full stage-by-stage details and preset behaviors.

---

## `appitool flow ios`

Executes the automated release flow for iOS.

- When `-d appstore` (default) is used, runs **`IOSInternalPreset`** (App Store Connect / TestFlight upload).
- When `-d adhoc` or `-d development` is used, runs **`IOSAdHocPreset`** (Firebase App Distribution upload to `internal` tester group).

### Options

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-d, --distribution <method>` | `appstore` | Distribution method: `adhoc`, `development`, or `appstore`. |
| `--dry-run` | `false` | Simulate pipeline execution without modifying Xcode projects, running builds, or uploading binaries. Forces Match `readonly` and skips notifications. |
| `-b, --bundle-id <id>` | `APPLE_BUNDLE_ID` | Target iOS bundle identifier. Auto-detected from Xcode project if omitted. |
| `-s, --scheme <scheme>` | `XCODE_SCHEME` | Xcode scheme to build. Auto-inferred if omitted. |
| `-c, --configuration <config>` | `XCODE_CONFIGURATION` | Build configuration (`Debug`, `Release`). |
| `--firebase-app-id <id>` | `FIREBASE_IOS_APP_ID` | Firebase App ID for iOS (used for Ad-Hoc / Firebase distribution). |
| `--silent` / `--no-silent` | `true` (`--silent`) | Suppress (`--silent`) or stream (`--no-silent`) `xcodebuild` and Match stdout logs. |
| `--wait-processing` / `--no-wait-processing` | `true` (`--wait-processing`) | Wait for App Store Connect build processing to apply TestFlight release notes (use `--no-wait-processing` to return immediately after upload even when release notes were generated). |

Plus shared option groups:
- [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`)
- [`GoogleCredentialsOptions`](/commands/overview#googlecredentialsoptions) (`-g, --google-key`)
- [`MatchOptions`](/commands/overview#matchoptions) (`--match-git-url`, `--match-git-branch`, `--match-git-token`, `--match-password`, `--keychain-name`, `--keychain-password`, `--team-id`, `--readonly`)
- [`NotificationOptions`](/commands/overview#notificationoptions) (`--slack-url`, `--kokono-url`, `--kokono-public-key`)
- [`ReleaseNotesOptions`](/commands/overview#releasenotesoptions) (`--release-notes`, `--notes-from`, `--notes-locale`)

### Examples

```bash
# Release to TestFlight / App Store Connect
appitool flow ios -d appstore -b com.example.app

# Distribute Ad-Hoc IPA via Firebase App Distribution with live build logs
appitool flow ios -d adhoc --no-silent

# Validate configuration and dry-run build increment
appitool flow ios -d appstore --dry-run
```

---

## `appitool flow android`

Executes the automated release flow for Android.

- When `-d appstore` (default) is used, runs **`AndroidInternalPreset`** (Google Play Console `internal` track).
- When `-d adhoc` or `-d development` is used, runs **`AndroidAdHocPreset`** (Firebase App Distribution upload to `internal` tester group).

### Options

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-d, --distribution <method>` | `appstore` | Distribution method: `adhoc`, `development`, or `appstore`. |
| `--dry-run` | `false` | Validate configuration, resolve Match keystore, inspect remote `versionCode`, and simulate upload without building or mutating state. |
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` | Target Android package name. Auto-detected from Gradle if omitted. |
| `--format <format>` | `aab` for `appstore`; `apk` for `adhoc`/`development` | Packaging format (`aab` or `apk`). `-d appstore` requires `aab` (Google Play rejects APKs); `--format apk` with `appstore` fails validation. |
| `--flavor <name>` | `ANDROID_FLAVOR` | Gradle product flavor (e.g., `production`, `staging`). Builds `bundle<Flavor>Release` / `assemble<Flavor>Release`, resolves flavor-specific `applicationId` (when `--package-name` is omitted), `versionName`, and `versionCode`, and names the artifact `<Target>_<flavor>_release`. |
| `--firebase-app-id <id>` | `FIREBASE_ANDROID_APP_ID` | Firebase App ID for Android (used for Ad-Hoc / Firebase distribution). |
| `--silent` / `--no-silent` | `true` (`--silent`) | Suppress (`--silent`) or show (`--no-silent`) Gradle and Match output. |

Plus shared option groups:
- [`GoogleCredentialsOptions`](/commands/overview#googlecredentialsoptions) (`-g, --google-key`)
- [`MatchStorageOptions`](/commands/overview#matchstorageoptions) (`--match-git-url`, `--match-git-branch`, `--match-git-token`, `--match-password`)
- [`NotificationOptions`](/commands/overview#notificationoptions) (`--slack-url`, `--kokono-url`, `--kokono-public-key`)
- [`ReleaseNotesOptions`](/commands/overview#releasenotesoptions) (`--release-notes`, `--notes-from`, `--notes-locale`)

### Examples

```bash
# Build AAB and upload to Google Play Console internal track
appitool flow android -d appstore --package-name com.example.app

# Build APK and distribute to Firebase App Distribution
appitool flow android -d adhoc --no-silent

# Build the production flavor AAB and upload to Google Play Console internal track
appitool flow android -d appstore --flavor production

# Dry-run Android Ad-Hoc flow
appitool flow android -d adhoc --dry-run
```
