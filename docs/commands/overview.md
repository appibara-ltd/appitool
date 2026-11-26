# Command Overview

`appitool` is built with Swift ArgumentParser. Run `appitool --help` (or `-h`) or `appitool <command> --help` at any level to inspect live options, or `appitool --version` to print the installed version.

## Command Structure

Store commands follow `appitool <store> <resource> <action>`: a plural resource noun, then a single verb, e.g. `appitool apple users list`, `appitool google invitations cancel`, `appitool firebase apps create`. Common verbs are `list`, `create`, `update`, and `delete`; some resources add their own (`prune`, `disable`, `invite`, `cancel`, `grant`, `revoke`, `sync`, `export`). Run `appitool <store> <resource> --help` to see a resource's actions.

## Complete Command Tree

| Command | Subcommands / resources | Description |
|:---|:---|:---|
| [`flow`](/commands/flow) | `ios`, `android` | Runs the automated 7-stage release orchestration pipeline. |
| [`build`](/commands/build) | `ios`, `android` | Compiles and packages iOS (`.xcarchive`/`.ipa`) and Android (`.aab`/`.apk`) artifacts directly. |
| [`check`](/commands/check) | `ios`, `android` | Queries remote store/distribution metadata and latest build numbers. |
| [`match`](/commands/match) | `ios` *(default)*, `android` | Syncs, prunes, nukes, or adds Git-encrypted certificates, profiles, and keystores. |
| [`apple`](/commands/apple) | `apps`, `versions`, `identifiers`, `capabilities`, `profiles`, `certificates`, `devices`, `users`, `invitations`, `assets`, `metadata` | Manages App Store Connect & Developer Portal apps and versions, identifiers, capabilities, profiles, certificates, devices, team users, invitations, store assets (screenshots, product page header, search results), and listing metadata. |
| [`google`](/commands/google) | `apps`, `signing-certs`, `users`, `invitations`, `assets`, `metadata` | Lists accessible apps and signing certificate fingerprints, and manages Google Play Console store visuals and screenshots (`list`, `upload`, `download`, `delete`, `types`), store listing text (`list`, `download`, `upload`), and Play Console users, invitations, and per-app access. |
| [`firebase`](/commands/firebase) | `apps`, `fingerprints`, `releases`, `groups`, `users`, `firestore` | Manages Firebase apps, App Distribution releases/groups, Firebase Auth users, and Cloud Firestore collections/documents. |
| [`inspect`](/commands/inspect) | — | Inspects local iOS and Android identifiers, versions, build numbers, and flavors (supports `--json`). |
| [`clean`](/commands/clean) | — | Cleans cached build outputs, Xcode DerivedData, and (with `--assets`) downloaded store assets under `~/.appitool`. |
| [`notes`](/commands/notes) | — | Generates categorized Markdown release notes from Git conventional commits. |
| [`kokono`](/commands/kokono) | — | Sends push notifications to KokoNo webhooks (plain or E2E encrypted). |
| [`self-update`](/commands/self-update) | — | Checks GitHub Releases and updates the `appitool` binary with SHA256 and build provenance verification (sigstore-swift, cross-checked with `gh` when installed). |
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

Used by `flow ios`, `build ios`, `check ios`, `match ios`, and all `apple` commands.

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

Includes `GoogleCredentialsOptions` and resolves the Android application package name. Used by `google assets <list|upload|download|delete>`.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `-g, --google-key <key>` | `GOOGLE_KEY` | Inherited from `GoogleCredentialsOptions` |
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` or local Android project | Target Android application package name |

### `FirebaseProjectOptions`

Used by `firebase apps <list|create|delete>`, `fingerprints sync`, `groups <list|create>`, `users <list|delete|export>`, and `firestore <collections|list|get|set|delete|query>` (note: `firestore` falls back to the `project_id` in `GOOGLE_KEY` rather than parsing `FIREBASE_*_APP_ID`).

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `-g, --google-key <key>` | `GOOGLE_KEY` | Inherited from `GoogleCredentialsOptions` |
| `--project <id>` | `FIREBASE_PROJECT_ID`, `GOOGLE_PROJECT_ID`, or parsed from `FIREBASE_*_APP_ID` | Firebase / Google Cloud project ID or project number |

### `FirebaseCredentialsOptions`

Includes `FirebaseProjectOptions` and adds app-level flags. Used by `firebase releases <list|create|update>`.

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

Includes `MatchStorageOptions` and adds Apple/iOS signing options. Used by `match ios sync` and `flow ios` (`match ios nuke` and `match ios prune` use only `MatchStorageOptions`).

| Flag | `.env` Fallback / Default | Description |
|:---|:---|:---|
| `--match-git-url <url>` | `MATCH_GIT_URL` | Inherited from `MatchStorageOptions` |
| `--match-git-branch <branch>` | `MATCH_GIT_BRANCH` (default: `master`) | Inherited from `MatchStorageOptions` |
| `--match-git-token <token>` | `MATCH_GIT_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN` | Inherited from `MatchStorageOptions` |
| `--match-password <pass>` | `MATCH_PASSWORD` | Inherited from `MatchStorageOptions` |
| `--keychain-name <name>` | `MATCH_KEYCHAIN_NAME` (default: `appitool`) | Custom macOS keychain name or path |
| `--keychain-password <pass>` | `MATCH_KEYCHAIN_PASSWORD` (default: `appipass`) | Keychain unlock password |
| `--team-id <id>` | `APPLE_TEAM_ID` | Apple Developer Team ID |
| `--readonly` | `MATCH_READONLY != "false"` in `flow ios` (defaults to `true`); `false` in `match ios sync` | Read-only mode (do not create new certs/profiles) |

### `NotificationOptions`

Used by `flow ios` and `flow android`.

| Flag | `.env` Fallback | Description |
|:---|:---|:---|
| `--slack-url <url>` | `SLACK_URL` | Slack incoming webhook URL |
| `--kokono-url <url>` | `KOKONO_URL` | KokoNo notification webhook URL |
| `--kokono-public-key <key>` | `KOKONO_E2E_PUBLIC_KEY` (ignored if `--kokono-url` flag is explicitly passed) | KokoNo E2E encryption public key |

### `GlobalCIOptions`

Available globally on `appitool` (can be placed before or after subcommands, as well as directly on guarded destructive subcommands and `match ios sync`). Auto-detects CI environment variables (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `BITRISE_IO`, `CIRCLECI`, `BUILDKITE`, `JENKINS_URL`, `TF_BUILD`, `TEAMCITY_VERSION`, `TRAVIS`, `CODEMAGIC_BUILD_ID`, `CI_XCODE_CLOUD`) when omitted. In CI mode, destructive commands (`apple identifiers delete`, `apple profiles delete`, `apple profiles prune`, `apple certificates delete`, `apple certificates prune`, `apple devices disable`, `apple users delete`, `apple invitations cancel`, `apple versions delete`, `apple assets delete`, `google assets delete`, `google users delete`, `google invitations cancel`, `google users revoke`, `firebase apps delete`, `firebase users delete`, `firebase firestore delete`, `match ios nuke`, and `match ios prune`) are skipped as a no-op with a warning (exit code `0`).

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
