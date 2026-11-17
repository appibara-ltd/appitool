# `appitool match`

Synchronizes, prunes, nukes, or adds encrypted code signing certificates, provisioning profiles, and Android keystores stored in a Git repository. Fully compatible with Fastlane Match V1 (`AES-256-CBC`) and V2 (`AES-256-GCM`) encryption.

## Synopsis

```bash
appitool match [ios] [<action-or-type>] [<target-type>] [options]
appitool match android [options]
```

> `ios` is the configured `defaultSubcommand`, so `appitool match ...` invokes `appitool match ios ...`.

---

## `appitool match ios`

Syncs, prunes, or nukes Apple certificates and provisioning profiles using Git storage.

### Positional Arguments

| Argument | Valid Values | Description |
|:---|:---|:---|
| `actionOrType` | `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`, `nuke`, `prune` | Distribution type to sync, or action (`nuke`, `prune`) to perform. |
| `targetType` | `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`, `all` | Target distribution type (or `all`) when the first argument is `nuke` or `prune`. |

### Options & Flags

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-t, --type <type>` | `MATCH_TYPE` or `appstore` | Distribution type: `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`. |
| `-g, --git-url <url>` | `MATCH_GIT_URL` | Git repository URL for certificates/profiles storage. |
| `-b, --git-branch <branch>` | `MATCH_GIT_BRANCH` or `master` | Git branch name. |
| `--platform <platform>` | `ios` | Target Apple platform: `ios`, `macos`, `tvos`, `catalyst`. |
| `--git-token <token>` | `MATCH_GIT_TOKEN` or `GITHUB_TOKEN` | Git Personal Access Token for HTTPS repositories. |
| `-p, --password <pass>` | `MATCH_PASSWORD` | Passphrase for AES encryption/decryption. |
| `-a, --app-identifiers <ids>` | Auto-discovered from local Xcode project | Comma-separated bundle identifiers to sync profiles for. |
| `-r, --readonly` | `false` | Read-only mode; prevents creating new certificates or profiles on Apple Developer Portal. |
| `--prune` | `false` | Prune revoked/expired certificates and profiles from Git storage. |
| `-A, --all` | `false` | Operate across all distribution types when pruning. |
| `--nuke` | `false` | Revoke certificates and delete provisioning profiles on Apple Developer Portal and in Git storage. |
| `-f, --force` | `false` | Force renewal of provisioning profiles even if still valid. |
| `--shallow-clone` / `--no-shallow-clone` | `true` for `--readonly`; `false` otherwise | Perform shallow Git clone (`--depth 1`). |
| `--team-id <id>` | `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `--team-name <name>` | — | Apple Developer Team Name (used as certificate CN when generating a new certificate). |
| `--keychain-name <name>` | `MATCH_KEYCHAIN_NAME` or `appitool` | Custom macOS keychain name or path. |
| `--keychain-password <pass>` | `MATCH_KEYCHAIN_PASSWORD` or `appipass` | Custom keychain password. |
| `--silent` | `false` | Suppress verbose logging. |

Plus [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`).

### Examples

```bash
# Sync App Store certificates and profiles (creates missing if writable)
appitool match ios appstore

# Read-only CI sync for Ad-Hoc profiles across specific bundle IDs
appitool match ios adhoc --readonly -a "com.example.app,com.example.app.widget"

# Prune invalid/expired assets across all profile types from Git storage
appitool match ios prune all

# Nuke development certificates and profiles on portal and Git repo
appitool match ios nuke development
```

---

## `appitool match android`

Syncs an encrypted Android keystore (`.keystore`, `.jks`, `.p12`) from Git storage or encrypts and adds a local keystore + metadata JSON into Git storage.

### Modes

- **Sync Mode (default)**: Clones and decrypts `android/<configuration>/<packageName>.<keystore|jks|p12>` and `<packageName>.json`, copying the keystore into `~/.appitool/android/keystores/<packageName>.keystore`.
- **Add Mode (`--add` or `-k, --keystore`)**: Encrypts the local keystore (and optional credential metadata JSON when `--alias`, `--store-password`, and `--key-password` are provided) using Match V2 (`AES-256-GCM`) and pushes it to the Git repository.

### Options & Flags

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-p, --package-name <name>` | `GOOGLE_PACKAGE_NAME` or Gradle-resolved | Target Android application package name. |
| `-c, --configuration <type>` | `release` | Build type (`release` or `debug`). |
| `--add <path>` | — | Path to local keystore file to encrypt and add to Match Git storage. |
| `-k, --keystore <path>` | — | Alias for `--add`. |
| `-a, --alias <name>` | `ANDROID_KEY_ALIAS` | Key alias inside keystore. |
| `--store-password <pass>` | `ANDROID_KEYSTORE_PASSWORD` | Keystore password. |
| `--key-password <pass>` | `ANDROID_KEY_PASSWORD` | Key password. |
| `-g, --git-url <url>` | `MATCH_GIT_URL` | Git repository URL for keystores storage. |
| `-b, --git-branch <branch>` | `MATCH_GIT_BRANCH` or `master` | Git branch name. |
| `--git-token <token>` | `MATCH_GIT_TOKEN` or `GITHUB_TOKEN` | Git authentication token. |
| `-P, --password <pass>` | `MATCH_PASSWORD` | Passphrase for AES encryption/decryption. |
| `--silent` | `false` | Suppress verbose output. |

### Examples

```bash
# Add and encrypt a local release keystore with credentials metadata
appitool match android \
  -p com.example.app \
  --add ./android/app/release.keystore \
  -a upload \
  --store-password "store_secret" \
  --key-password "key_secret"

# Sync release keystore from Match Git repository
appitool match android -p com.example.app -c release
```
