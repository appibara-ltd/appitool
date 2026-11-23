# Command Overview

`appitool` is built with Swift ArgumentParser. Run `appitool --help` (or `-h`) or `appitool <command> --help` at any level to inspect live options, or `appitool --version` to print the installed version.

## Complete Command Tree

| Command | Subcommands | Description |
|:---|:---|:---|
| [`flow`](/commands/flow) | `ios`, `android` | Runs the automated 7-stage release orchestration pipeline. |
| [`build`](/commands/build) | `ios`, `android` | Compiles and packages iOS (`.xcarchive`/`.ipa`) and Android (`.aab`/`.apk`) artifacts directly. |
| [`check`](/commands/check) | `ios`, `android` | Queries remote store/distribution metadata and latest build numbers. |
| [`match`](/commands/match) | `ios` *(default)*, `android` | Syncs, prunes, nukes, or adds Git-encrypted certificates, profiles, and keystores. |
| [`apple`](/commands/apple) | 23 subcommands | Manages App Store Connect & Developer Portal apps, identifiers, capabilities, profiles, certificates, devices, team users, invitations, and store screenshots. |
| [`google`](/commands/google) | `screenshots` (5 subcommands) | Manages Google Play Console store visuals and screenshots (`list`, `upload`, `download`, `delete`, `types`). |
| [`firebase`](/commands/firebase) | 9 subcommands | Manages Firebase App Distribution releases/groups, Firebase Auth users, and Cloud Firestore collections/documents. |
| [`inspect`](/commands/inspect) | — | Inspects local iOS and Android identifiers, versions, build numbers, and flavors (supports `--json`). |
| [`clean`](/commands/clean) | — | Cleans cached build outputs and Xcode DerivedData under `~/.appitool`. |
| [`notes`](/commands/notes) | — | Generates categorized Markdown release notes from Git conventional commits. |
| [`kokono`](/commands/kokono) | — | Sends push notifications to KokoNo webhooks (plain or E2E encrypted). |
| [`self-update`](/commands/self-update) | — | Checks GitHub Releases and updates the `appitool` binary with SHA256 verification. |
| [`status`](/commands/status) | — | Displays the tool name, purpose, and active version. |

---

## Distribution Modes (`BuildCommand.Distribution`)

Commands that accept `-d, --distribution` (`flow`, `build`, `check`) accept the following distribution values (case-insensitive):

| Value | Accepted Aliases | Typical Target |
|:---|:---|:---|
| `appstore` | `appstore`, `app-store` | Apple App Store / TestFlight or Google Play Console |
| `adhoc` | `adhoc`, `ad-hoc` | Firebase App Distribution (Ad-Hoc IPA / APK) |
| `development` | `development`, `dev` | Local development builds |

---

## Shared Option Groups

Several commands reuse standardized `OptionGroup` structs defined in `CredentialsOptions.swift`. Every option falls back to `.env` / environment variables when omitted.

### `AppleCredentialsOptions`

Used by `flow ios`, `build ios`, `check ios`, `match ios`, and all `apple` subcommands.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `--apple-key-id <id>` | `APPLE_KEY_ID` | App Store Connect API Key ID |
| `--apple-issuer-id <uuid>` | `APPLE_ISSUER_ID` | App Store Connect API Issuer ID |
| `--apple-key <key>` | `APPLE_KEY` | `.p8` file path, raw PEM content, or Base64 string |

### `GoogleCredentialsOptions`

Used by `flow ios`, `flow android`, `check ios`, `check android`, `GooglePlayAppOptions`, and `FirebaseProjectOptions`.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `-g, --google-key <key>` | `GOOGLE_KEY` | Service Account JSON path, raw JSON string, or Base64 string |

### `GooglePlayAppOptions`

Includes `GoogleCredentialsOptions` and resolves the Android application package name. Used by `google screenshots <list|upload|download|delete>`.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `-g, --google-key <key>` | `GOOGLE_KEY` | Inherited from `GoogleCredentialsOptions` |
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` or local Android project | Target Android application package name |

### `FirebaseProjectOptions`

Used by `firebase list-groups`, `create-group`, `list-users`, `delete-user`, `export-users`, and `firestore <collections|list|get|set|delete|query>` (note: `firestore` falls back to the `project_id` in `GOOGLE_KEY` rather than parsing `FIREBASE_*_APP_ID`).

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `-g, --google-key <key>` | `GOOGLE_KEY` | Inherited from `GoogleCredentialsOptions` |
| `--project <id>` | `FIREBASE_PROJECT_ID`, `GOOGLE_PROJECT_ID`, or parsed from `FIREBASE_*_APP_ID` | Firebase / Google Cloud project ID or project number |

### `FirebaseCredentialsOptions`

Includes `FirebaseProjectOptions` and adds app-level flags. Used by `firebase list-releases`, `create-release`, and `update-release`.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `--firebase-app-id <id>` | `FIREBASE_IOS_APP_ID` / `FIREBASE_ANDROID_APP_ID` | Target Firebase App ID |
| `-p, --platform <platform>` | — | Target platform for App ID resolution (`ios` or `android`) |
| `-g, --google-key <key>` | `GOOGLE_KEY` | Inherited from `FirebaseProjectOptions` |
| `--project <id>` | `FIREBASE_PROJECT_ID` | Inherited from `FirebaseProjectOptions` |

### `MatchStorageOptions`

Used by `match android`, `flow android`, and `build android` (and embedded in `MatchOptions`).

| Flag | `.env` Fallback / Default | Description |
|:---|:---|:---|
| `--match-git-url <url>` | `MATCH_GIT_URL` | Match Git repository URL |
| `--match-git-branch <branch>` | `MATCH_GIT_BRANCH` (default: `master`) | Git branch name |
| `--match-git-token <token>` | `MATCH_GIT_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN` | Git HTTPS PAT or SSH private/deploy key (file path, PEM, or Base64) |
| `--match-password <pass>` | `MATCH_PASSWORD` | AES decryption/encryption passphrase |

### `MatchOptions`

Includes `MatchStorageOptions` and adds Apple/iOS signing options. Used by `match ios` and `flow ios`.

| Flag | `.env` Fallback / Default | Description |
|:---|:---|:---|
| `--match-git-url <url>` | `MATCH_GIT_URL` | Inherited from `MatchStorageOptions` |
| `--match-git-branch <branch>` | `MATCH_GIT_BRANCH` (default: `master`) | Inherited from `MatchStorageOptions` |
| `--match-git-token <token>` | `MATCH_GIT_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN` | Inherited from `MatchStorageOptions` |
| `--match-password <pass>` | `MATCH_PASSWORD` | Inherited from `MatchStorageOptions` |
| `--keychain-name <name>` | `MATCH_KEYCHAIN_NAME` (default: `appitool`) | Custom macOS keychain name or path |
| `--keychain-password <pass>` | `MATCH_KEYCHAIN_PASSWORD` (default: `appipass`) | Keychain unlock password |
| `--team-id <id>` | `APPLE_TEAM_ID` | Apple Developer Team ID |
| `--readonly` | `MATCH_READONLY != "false"` in `flow ios` (defaults to `true`); `false` in `match ios` | Read-only mode (do not create new certs/profiles) |

### `NotificationOptions`

Used by `flow ios` and `flow android`.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `--slack-url <url>` | `SLACK_URL` | Slack incoming webhook URL |
| `--kokono-url <url>` | `KOKONO_URL` | KokoNo notification webhook URL |
| `--kokono-public-key <key>` | `KOKONO_E2E_PUBLIC_KEY` (ignored if `--kokono-url` flag is explicitly passed) | KokoNo E2E encryption public key |

### `GlobalCIOptions`

Available globally on `appitool` (can be placed before or after subcommands, as well as directly on guarded destructive subcommands and `match ios`). Auto-detects CI environment variables (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `BITRISE_IO`, `CIRCLECI`, `BUILDKITE`, `JENKINS_URL`, `TF_BUILD`, `TEAMCITY_VERSION`, `TRAVIS`, `CODEMAGIC_BUILD_ID`, `CI_XCODE_CLOUD`) when omitted. In CI mode, destructive commands (`apple delete-identifier`, `apple delete-profile`, `apple prune-profiles`, `apple delete-certificate`, `apple prune-certificates`, `apple disable-device`, `apple delete-user`, `apple cancel-invitation`, `apple screenshots delete`, `google screenshots delete`, `firebase delete-user`, `firebase firestore delete`, `match ios --nuke`, and `match ios --prune`) are skipped as a no-op with a warning (exit code `0`).

| Flag | Default / Env Fallback | Description |
|:---|:---|:---|
| `--ci` / `--no-ci` | `CI` and provider env vars (`false` if unset) | Explicitly enable or disable CI mode, overriding environment detection |

### `ReleaseNotesOptions`

Used by `flow ios` and `flow android`.

| Flag | Default | Description |
|:---|:---|:---|
| `--release-notes <text>` | — | Custom release notes text (bypasses Git commit generation) |
| `--notes-from <ref>` | — | Starting Git tag or commit reference for release notes generation (overrides auto-tag detection) |
| `--notes-locale <locale>` | `en-US` | Locale/language code for store release notes (e.g. `en-US`, `tr-TR`) |
