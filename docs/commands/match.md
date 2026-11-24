# `appitool match`

Synchronizes, prunes, nukes, or adds encrypted code signing certificates, provisioning profiles, and Android keystores stored in a Git repository. Fully compatible with Fastlane Match V1 (`AES-256-CBC`) and V2 (`AES-256-GCM`) encryption.

## Synopsis

```bash
appitool match ios [sync] [options]
appitool match ios nuke [options]
appitool match ios prune [options]
appitool match android [options]
```

> `ios` is the `defaultSubcommand` of `match`, and `sync` is the `defaultSubcommand` of `match ios`, so `appitool match -t adhoc` runs `appitool match ios sync -t adhoc`. Actions (`sync`, `nuke`, `prune`) are subcommands; distribution types are always passed with `-t, --type`.

---

## `appitool match ios`

Groups the Apple code signing actions. Each action is its own subcommand with its own options.

| Subcommand | Destructive | Description |
|:---|:---|:---|
| `sync` *(default)* | No | Syncs certificates and profiles from Git storage, creating missing or expired ones when writable. |
| `nuke` | Yes | Revokes certificates and deletes provisioning profiles of one distribution type on Apple Developer Portal and in Git storage. |
| `prune` | Yes | Removes certificates and profiles that are revoked on Apple Developer Portal or expired from Git storage. |

### Shared Options (all `match ios` subcommands)

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-p, --platform <platform>` | `ios` | Target Apple platform: `ios`, `macos`, `tvos`, `catalyst`. |
| `--silent` / `--no-silent` | `true` (`--silent`) | Suppress (`--silent`) or show (`--no-silent`) verbose logging. |

Plus [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`) and [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`).

---

### `appitool match ios sync`

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-t, --type <type>` | `MATCH_TYPE` or `appstore` | Distribution type: `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`. |
| `--identifiers <ids>` | Auto-discovered from local Xcode project | Comma-separated bundle identifiers to sync profiles for. |
| `--force` | `false` | Force renewal of provisioning profiles even if still valid. |
| `--shallow-clone` / `--no-shallow-clone` | `true` for `--readonly`; `false` otherwise | Perform shallow Git clone (`--depth 1`). |
| `--team-name <name>` | — | Apple Developer Team Name (used as certificate CN when generating a new certificate). |

Plus [`MatchOptions`](/commands/overview#matchoptions) (`--match-git-url`, `--match-git-branch`, `--match-git-token`, `--match-password`, `--keychain-name`, `--keychain-password`, `--team-id`, `--readonly`; `--readonly` defaults to `false` in `match ios sync`).

`sync` is not destructive, so it runs normally in CI mode.

---

### `appitool match ios nuke`

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-t, --type <type>` | `MATCH_TYPE` or `appstore` | Distribution type to nuke: `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`. |

Plus [`MatchStorageOptions`](/commands/overview#matchstorageoptions) (`--match-git-url`, `--match-git-branch`, `--match-git-token`, `--match-password`).

Requires App Store Connect API credentials. Skipped as a no-op (exit code `0`) in CI mode unless `--no-ci` is passed.

---

### `appitool match ios prune`

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-t, --type <type>` | `MATCH_TYPE` or `appstore` | Distribution type to prune: `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`. |
| `--all` | `false` | Prune across all distribution types (cannot be combined with `-t, --type`). |

Plus [`MatchStorageOptions`](/commands/overview#matchstorageoptions) (`--match-git-url`, `--match-git-branch`, `--match-git-token`, `--match-password`).

Requires App Store Connect API credentials. Skipped as a no-op (exit code `0`) in CI mode unless `--no-ci` is passed.

---

### Examples

```bash
# Sync App Store certificates and profiles (creates missing if writable)
appitool match ios -t appstore

# Read-only CI sync for Ad-Hoc profiles across specific bundle IDs
appitool match ios sync -t adhoc --readonly --identifiers "com.example.app,com.example.app.widget"

# Prune revoked/expired assets across all profile types from Git storage
appitool match ios prune --all

# Nuke development certificates and profiles on portal and Git repo
appitool match ios nuke -t development
```

---

## `appitool match android`

Syncs an encrypted Android keystore (`.keystore`, `.jks`, `.p12`) from Git storage or encrypts and adds a local keystore + metadata JSON into Git storage.

### Modes

- **Sync Mode (default)**: Clones and decrypts `android/<configuration>/<packageName>.<keystore|jks|p12>` and `<packageName>.json`, copying the keystore into `~/.appitool/android/keystores/<packageName>.keystore`.
- **Add Mode (`-k, --keystore`)**: Encrypts the local keystore (and optional credential metadata JSON when `--alias`, `--keystore-password`, and `--key-password` are provided) using Match V2 (`AES-256-GCM`) and pushes it to the Git repository.

### Options & Flags

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` or Gradle-resolved | Target Android application package name. |
| `-c, --configuration <type>` | `release` | Build type (`release` or `debug`). |
| `-k, --keystore <path>` | — | Path to local keystore file to encrypt and add to Match Git storage (omit to sync). |
| `--alias <name>` | `ANDROID_KEY_ALIAS` | Key alias inside keystore. |
| `--keystore-password <pass>` | `ANDROID_KEYSTORE_PASSWORD` | Keystore password. |
| `--key-password <pass>` | `ANDROID_KEY_PASSWORD` | Key password. |
| `--silent` / `--no-silent` | `true` (`--silent`) | Suppress (`--silent`) or show (`--no-silent`) verbose output. |

Plus [`MatchStorageOptions`](/commands/overview#matchstorageoptions) (`--match-git-url`, `--match-git-branch`, `--match-git-token`, `--match-password`).

### Examples

```bash
# Add and encrypt a local release keystore with credentials metadata
appitool match android \
  --package-name com.example.app \
  -k ./android/app/release.keystore \
  --alias upload \
  --keystore-password "store_secret" \
  --key-password "key_secret"

# Sync release keystore from Match Git repository
appitool match android --package-name com.example.app -c release
```
