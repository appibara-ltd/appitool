# `appitool build`

Compiles and packages platform binaries directly without running the full 7-stage `flow` pipeline.

## Synopsis

```bash
appitool build ios [options]
appitool build android [options]
```

---

## `appitool build ios`

Builds and packages an iOS application using `xcodebuild` (comparable to Fastlane `build_app` / `gym`).

Artifacts are written under `~/.appitool/ios/<MainTarget>/build/<yyyy_MM_dd_HH_mm>/` with DerivedData isolated in `~/.appitool/ios/<MainTarget>/derivedData/`.

### Options

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-d, --distribution <method>` | `appstore` | Distribution method: `adhoc`, `development`, or `appstore`. Mapped to `app-store-connect`, `release-testing`, or `debugging` export methods. |
| `-w, --workspace <path>` | `XCODE_WORKSPACE` or auto-detected | Path to `.xcworkspace`. |
| `-p, --project <path>` | `XCODE_PROJECT` or auto-detected | Path to `.xcodeproj`. |
| `-s, --scheme <name>` | `XCODE_SCHEME` or inferred | Xcode scheme to build (inferred via `xcodebuild -list -json`). |
| `-c, --configuration <name>` | `XCODE_CONFIGURATION` or `Release` | Build configuration (`Debug`, `Release`). |
| `-t, --team-id <id>` | `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `--codesigning-identity <id>` | — | Code signing identity override (e.g., `"Apple Distribution"`, `"Apple Development"`). |
| `--clean` | `false` | Clean build folder before building. |
| `--skip-build-archive` | `false` | Skip compiling `.xcarchive` and export an IPA from the latest `.xcarchive` found under `~/.appitool/ios/<MainTarget>/build/`. |
| `--skip-package-ipa` | `false` | Only compile `.xcarchive` and skip IPA packaging. |
| `--allow-provisioning-updates` | `false` | Allow `xcodebuild` to communicate with Apple Developer Portal for provisioning updates (passes `-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID` automatically if `APPLE_KEY` is a file path). |
| `--manage-build-number` | `false` | Allow App Store Connect to automatically manage/increment version and build numbers during export. |
| `--silent` | `false` | Suppress `xcodebuild` stdout logs. |
| `--xcodebuild-formatter <cmd>` | `XCODEBUILD_FORMATTER` or `xcbeautify --renderer github-actions` | Formatter command piped from `xcodebuild` output. |

Plus [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`).

### Examples

```bash
# Build App Store IPA (auto-discover workspace & scheme)
appitool build ios -d appstore

# Build Ad-Hoc IPA with automatic provisioning updates and clean build
appitool build ios -d adhoc --clean --allow-provisioning-updates

# Re-export IPA from the most recent existing .xcarchive
appitool build ios -d adhoc --skip-build-archive
```

---

## `appitool build android`

Builds an Android App Bundle (`.aab`) or APK (`.apk`) using Gradle (`./gradlew`).

Artifacts are written under `~/.appitool/android/<Target>/build/<yyyy_MM_dd_HH_mm>/` named `<Target>_<flavor_><buildType>.<aab|apk>`.

### Signing Resolution Order

`build android` resolves signing credentials in the following order:
1. Base64 keystore via `--keystore-base64` / `ANDROID_KEYSTORE` (decoded temporarily into `~/.appitool/android/keystores/<packageName>.keystore` and removed automatically after build).
2. Local keystore file via `--keystore-path` / `ANDROID_KEYSTORE_PATH`.
3. Match Git repository if `--match` is passed (or if `MATCH_GIT_URL` and `MATCH_PASSWORD` are set when no local keystore path was provided).

### Options

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-d, --distribution <method>` | `appstore` | Distribution method: `adhoc`, `development`, or `appstore`. |
| `-p, --package-name <name>` | `GOOGLE_PACKAGE_NAME` or Gradle-resolved | Target Android package name. |
| `-f, --flavor <name>` | `ANDROID_FLAVOR` | Gradle product flavor (e.g., `production`, `staging`). |
| `-c, --configuration <type>` | `ANDROID_CONFIGURATION` or `Release` | Build configuration/type (`Release`, `Debug`). |
| `--format <format>` | `aab` for `appstore`; `apk` for `adhoc`/`development` | Packaging format (`aab` or `apk`). |
| `--clean` | `false` | Run Gradle `clean` before building. |
| `--silent` | `false` | Suppress Gradle stdout logs. |
| `--project-dir <path>` | `ANDROID_PROJECT_DIR`, `./android`, or `.` | Android root directory containing `gradlew`. |
| `--keystore-path <path>` | `ANDROID_KEYSTORE_PATH` | Path to local keystore file. |
| `--keystore-base64 <str>` | `ANDROID_KEYSTORE` | Base64-encoded keystore content. |
| `--keystore-password <pass>` | `ANDROID_KEYSTORE_PASSWORD` | Keystore store password. |
| `--key-alias <alias>` | `ANDROID_KEY_ALIAS` | Key alias inside keystore. |
| `--key-password <pass>` | `ANDROID_KEY_PASSWORD` | Key password. |
| `--gradle-opts <opts>` | — | Custom JVM options passed via `GRADLE_OPTS` (automatically appends `-Dorg.gradle.daemon=false` if omitted). |
| `--match` | `false` | Fetch signing keystore from Match Git repository. |

Plus [`MatchStorageOptions`](/commands/overview#matchstorageoptions).

### Examples

```bash
# Build signed release AAB for Google Play using Match keystore
appitool build android -d appstore --match

# Build staging flavor APK cleanly with custom JVM heap
appitool build android -d adhoc -f staging --format apk --clean --gradle-opts "-Xmx4g"
```
