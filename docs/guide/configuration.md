# Configuration & `.env`

`appitool` uses a strict, deterministic configuration model. Commands resolve CLI options with environment variable fallbacks, while internal tasks, services, and flow presets receive resolved values explicitly.

## Resolution Priority

Options and credentials are resolved in the following priority order (highest to lowest):

1. **Explicit CLI Flags** (e.g., `-b com.example.app`, `--apple-key-id ...`)
2. **Process Environment Variables** (already exported in your shell or CI runner)
3. **`.env` File** (automatically loaded from the current working directory if present; existing environment variables are **not** overwritten)

---

## `.env` Parser (`EnvLoader`)

The built-in `EnvLoader` parses `.env` files without external dependencies and supports:

- **Comments**: Full-line `#` comments and trailing inline comments preceded by a space (`KEY=value # comment`).
- **`export ` prefix**: Standard shell syntax like `export APPLE_KEY_ID=2X9R4HXF34`.
- **Single and double quotes**: Single quotes (`'...'`) preserve literal values; double quotes (`"..."`) unescape `\n`, `\r`, `\t`, `\"`, and `\\`.
- **Multiline quoted values**: Multiline PEM keys or JSON payloads enclosed in quotes.
- **`=` preservation**: Base64 padding (`=`) and URL query strings (`?token=...`) are preserved intact.
- **Tilde (`~`) expansion**: Paths starting with `~/` expand to the current user's home directory where path resolution is supported.
- **Empty value handling**: Keys with empty or whitespace-only values (e.g., `MATCH_GIT_BRANCH=`) are skipped during `.env` injection and treated as unset when read via `EnvLoader.value(for:)`, so built-in defaults and fallbacks apply across both `.env` files and CI/shell environments.

---

## Environment Variables Reference

### Apple App Store Connect & Developer Portal

| Variable | Description | Example / Default |
|:---|:---|:---|
| `APPLE_KEY_ID` | App Store Connect API Key ID | `2X9R4HXF34` |
| `APPLE_ISSUER_ID` | App Store Connect API Issuer UUID | `57246542-96fe-1a63-e053-0824d011072a` |
| `APPLE_KEY` | Path to `.p8` file, raw PEM string, or Base64-encoded `.p8` | `./AuthKey_2X9R4HXF34.p8` |
| `APPLE_BUNDLE_ID` | Default iOS bundle identifier | `com.example.app` |
| `APPLE_TEAM_ID` | Apple Developer Team ID (10-character alphanumeric) | `ABCDE12345` |

### iOS `xcodebuild` Configuration

| Variable | Description | Default / Behavior |
|:---|:---|:---|
| `XCODE_WORKSPACE` | Path to `.xcworkspace` | Auto-discovered in `.` or `ios/` |
| `XCODE_PROJECT` | Path to `.xcodeproj` | Auto-discovered in `.` or `ios/` |
| `XCODE_SCHEME` | Xcode scheme name to build | Auto-inferred via `xcodebuild -list -json` |
| `XCODE_CONFIGURATION` | Build configuration (`Release` or `Debug`) | `Release` |
| `XCODEBUILD_FORMATTER` | Pipe formatter for `xcodebuild` output | `xcbeautify --renderer github-actions` |

### Google Play Developer API

| Variable | Description | Example / Default |
|:---|:---|:---|
| `GOOGLE_KEY` | Path to Service Account JSON, raw JSON string, or Base64 JSON | `./service-account.json` |
| `GOOGLE_PACKAGE_NAME` | Target Android application package name | `com.example.app` |

### Android Gradle & Keystore Signing

| Variable | Description | Default / Behavior |
|:---|:---|:---|
| `ANDROID_PROJECT_DIR` | Android root directory containing `gradlew` | `./android` if present, else `.` |
| `ANDROID_FLAVOR` | Gradle product flavor (e.g., `production`, `staging`) | None |
| `ANDROID_CONFIGURATION` | Build type (`Release` or `Debug`) | `Release` |
| `ANDROID_KEYSTORE_PATH` | Path to local `.keystore` / `.jks` file | None |
| `ANDROID_KEYSTORE` | Base64-encoded keystore content (decoded to temporary keystore) | None |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore store password | None |
| `ANDROID_KEY_ALIAS` | Key alias inside keystore | None |
| `ANDROID_KEY_PASSWORD` | Key password | None |

### Firebase (App Distribution & Auth)

| Variable | Description | Notes |
|:---|:---|:---|
| `FIREBASE_IOS_APP_ID` | Firebase App ID for iOS (`1:<project>:ios:<hash>`) | Used by `check ios`, `flow ios -d adhoc`, and `firebase` commands |
| `FIREBASE_ANDROID_APP_ID` | Firebase App ID for Android (`1:<project>:android:<hash>`) | Used by `check android`, `flow android -d adhoc`, and `firebase` commands |
| `FIREBASE_PROJECT_ID` | Firebase / Google Cloud project ID or project number | Falls back to `GOOGLE_PROJECT_ID` or project number parsed from `FIREBASE_*_APP_ID` |
| `GOOGLE_PROJECT_ID` | Fallback Google Cloud project ID when `FIREBASE_PROJECT_ID` is unset | Used by `FirebaseProjectOptions` |

### Match Code Signing (`appitool match` & `flow`)

| Variable | Description | Default / Behavior |
|:---|:---|:---|
| `MATCH_GIT_URL` | Git repository URL for certificates/profiles/keystores | Required for Match |
| `MATCH_GIT_BRANCH` | Git branch name | `master` |
| `MATCH_GIT_TOKEN` | HTTPS Git Personal Access Token | Falls back to `GITHUB_TOKEN` |
| `MATCH_PASSWORD` | Passphrase for AES-256 encryption/decryption | Required for Match |
| `MATCH_KEYCHAIN_NAME` | Custom macOS keychain name or path | `appitool` |
| `MATCH_KEYCHAIN_PASSWORD` | Password used to create/unlock custom keychain | `appipass` |
| `MATCH_READONLY` | In `flow ios` (`MatchOptions`), read-only unless set to `"false"` | `true` (unless `"false"`) |
| `MATCH_TYPE` | Default Match profile type for `match ios` when positional type and `-t` are omitted | `appstore` |

### Webhook Notifications

| Variable | Description | Notes |
|:---|:---|:---|
| `SLACK_URL` | Slack incoming webhook URL | Used by `flow` for success/failure attachments |
| `KOKONO_URL` | KokoNo webhook URL (`https://kokono.me/notify?token=<token>`) | Used by `kokono` and `flow` |
| `KOKONO_E2E_PUBLIC_KEY` | Base64 X25519 recipient public key for KokoNo E2E encryption | Optional |

### GitHub Self-Update

| Variable | Description | Notes |
|:---|:---|:---|
| `GITHUB_TOKEN` | GitHub PAT for private release downloads & Match fallback | Falls back to `GH_TOKEN` in `self-update` |
| `GH_TOKEN` | Secondary fallback token in `self-update` | Checked if `GITHUB_TOKEN` is unset |

---

## Local Storage Architecture (`~/.appitool`)

`appitool` centralizes build artifacts, Xcode DerivedData, temporary keystores, and exported certificates under `~/.appitool` (`AppitoolPaths`):

```text
~/.appitool/
├── ios/
│   └── <TargetName>/
│       ├── build/
│       │   └── <yyyy_MM_dd_HH_mm>/
│       │       ├── <Scheme>.xcarchive
│       │       ├── <Scheme>.ipa
│       │       └── <Scheme>.app.dSYM.zip
│       └── derivedData/
├── android/
│   ├── <TargetName>/
│   │   └── build/
│   │       └── <yyyy_MM_dd_HH_mm>/
│   │           ├── <Target>_release.aab
│   │           └── <Target>_release.apk
│   ├── keystores/
│   │   └── <packageName>.keystore
│   └── tmp/
├── certs/
│   └── <type>/
└── match/
    └── <UUID>/                  # Temporary Git clone working directory (auto-cleaned)
```

Use [`appitool clean`](/commands/clean) to inspect sizes and prune old build artifacts and iOS `derivedData` directories safely.
