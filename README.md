<p align="center">
  <img src="banner.png" alt="appitool" width="100%" />
</p>

A unified CLI utility and release orchestration engine for Apple App Store Connect, Apple Developer Portal, Google Play Console, Firebase App Distribution, Firebase Authentication, and Git-backed code signing.

[![Swift](https://img.shields.io/badge/Swift-6.4-orange.svg?style=flat)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B%20%7C%20Linux-blue.svg?style=flat)](https://apple.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=flat)](LICENSE)
[![Docs](https://img.shields.io/badge/Docs-appibara--ltd.github.io%2Fappitool-0891b2.svg?style=flat)](https://appibara-ltd.github.io/appitool/)

---

## Features

- **Standardized Release Lifecycle:** Opinionated 7-stage automated pipeline (`setup` ➔ `prebuild` ➔ `build` ➔ `postbuild` ➔ `prerelease` ➔ `release` ➔ `postrelease`).
- **Unified Store API Client:** OpenAPI-generated clients for Apple App Store Connect and Google Play Developer APIs.
- **Multi-Track Distribution:** Deploy seamlessly to TestFlight, App Store, Google Play (Internal, Alpha, Beta, Production), and Firebase App Distribution.
- **Smart Notifications:** Real-time webhook dispatches to Slack and KokoNo with end-to-end (E2E) encryption support.
- **Git-Backed Code Signing (`match`):** Encrypted sync of iOS certificates/profiles and Android keystores via a private Git repository.
- **Store & Firebase Management:** Manage App Store Connect identifiers, capabilities, profiles, certificates, devices, and Firebase App Distribution releases, groups, and Auth users.
- **Release Notes:** Categorized Markdown release notes generated from Git conventional commits.
- **Built-in Self-Update:** Upgrade the CLI in-place on demand via `appitool self-update` with SHA256 checksum verification.
- **Dry-Run Mode:** Validate configurations, credentials, and stage workflows without triggering builds or mutating remote state.

---

## Installation

### One-Line Quick Install (macOS Apple Silicon, Linux x86_64 / arm64)

```bash
curl -fsSL https://raw.githubusercontent.com/appibara-ltd/appitool/main/install.sh | bash
```

> **Private Repository Access:** If installing from a private repository, provide a GitHub personal access token:
> ```bash
> curl -fsSL -H "Authorization: Bearer $(gh auth token)" https://raw.githubusercontent.com/appibara-ltd/appitool/main/install.sh | GITHUB_TOKEN=$(gh auth token) bash
> ```

The installer automatically places the executable in `/usr/local/bin` (or `~/.local/bin`) and ensures it is available in your shell `$PATH`.

### Build from Source

Requirements: Swift 6.4+

```bash
git clone https://github.com/appibara-ltd/appitool.git
cd appitool

# Build optimized release binary
swift build -c release
strip .build/release/appitool

# Optional: Link to your PATH
ln -sf "$(pwd)/.build/release/appitool" /usr/local/bin/appitool
```

---

## Self-Update

Keep `appitool` up to date with the latest release directly from your terminal:

```bash
# Check if an update is available without installing
appitool self-update --check

# Upgrade to the latest release
appitool self-update

# Force re-installation
appitool self-update --force
```

---

## Quick Start & Configuration

`appitool` resolves credentials and options in the following priority order:
1. **Explicit CLI Flags** (e.g., `-b, --bundle-id`, `-d, --distribution`)
2. **Environment Variables** (from shell environment)
3. **`.env` File** (in the current working directory)

Copy the template configuration file to get started:

```bash
cp .env.example .env
```

### Essential `.env` Variables

```ini
# --- Apple App Store Connect ---
APPLE_KEY_ID=2X9R4HXF34
APPLE_ISSUER_ID=57246542-96fe-1a63-e053-0824d011072a
APPLE_KEY=./AuthKey_2X9R4HXF34.p8
APPLE_BUNDLE_ID=com.example.app

# --- Google Play Developer API ---
GOOGLE_KEY=./service-account.json
GOOGLE_PACKAGE_NAME=com.example.app

# --- Firebase App Distribution (AdHoc) ---
FIREBASE_IOS_APP_ID=1:1234567890:ios:abcdef1234567890
FIREBASE_ANDROID_APP_ID=1:1234567890:android:abcdef1234567890

# --- Notifications ---
SLACK_URL=https://hooks.slack.com/services/...
KOKONO_URL=https://kokono.me/notify?token=...
KOKONO_E2E_PUBLIC_KEY=your_optional_public_key
```

---

## Commands & Usage

Run `appitool --help` or `appitool <command> --help` to inspect live options. Full reference: [`docs/commands/`](docs/commands/overview.md).

| Command | Subcommands | Description |
|:---|:---|:---|
| `flow` | `ios`, `android` | Runs the automated 7-stage release orchestration pipeline. |
| `build` | `ios`, `android` | Compiles and packages iOS (`.xcarchive`/`.ipa`) and Android (`.aab`/`.apk`) artifacts. |
| `check` | `ios`, `android` | Queries remote store/distribution metadata and latest build numbers. |
| `match` | `ios` *(default)*, `android` | Syncs, prunes, nukes, or adds Git-encrypted certificates, profiles, and keystores. |
| `apple` | 16 subcommands | Manages App Store Connect & Developer Portal apps, identifiers, capabilities, profiles, certificates, and devices. |
| `firebase` | 8 subcommands | Manages Firebase App Distribution releases/groups and Firebase Auth users. |
| `inspect` | — | Inspects local iOS bundle IDs and Android `applicationId`/`namespace`/flavors (supports `--json`). |
| `clean` | — | Cleans cached build outputs and Xcode DerivedData under `~/.appitool`. |
| `notes` | — | Generates categorized Markdown release notes from Git conventional commits. |
| `kokono` | — | Sends push notifications to KokoNo webhooks (plain or E2E encrypted). |
| `self-update` | — | Checks GitHub Releases and updates the binary with SHA256 verification. |
| `status` | — | Displays the tool name, purpose, and active version. |

Distribution values for `-d, --distribution` (`flow`, `build`, `check`): `appstore`, `adhoc`, `development`.

### `flow`

Automated release pipeline that runs all 7 stages sequentially.

```bash
# Run release flow for iOS (TestFlight / App Store)
appitool flow ios -b com.example.app -d appstore

# Run release flow for Android (Ad-Hoc via Firebase)
appitool flow android -p com.example.app -d adhoc

# Dry run: Validate configuration and simulate execution without mutations
appitool flow ios --dry-run
```

#### Pipeline Stages

| Stage | Name | Description |
|:---:|:---|:---|
| **01** | `setup` | Validates environment, tooling availability, and store credentials. |
| **02** | `prebuild` | Fetches latest remote build number and increments project versioning (`+1`). |
| **03** | `build` | Runs compiler builds (`xcodebuild` for iOS, `gradlew` for Android). |
| **04** | `postbuild` | Validates build artifacts integrity and extracts binary metadata. |
| **05** | `prerelease` | Prepares changelogs, dSYM/mapping symbol packages, and release notes. |
| **06** | `release` | Uploads binary to TestFlight, Google Play tracks, or Firebase. |
| **07** | `postrelease` | Dispatches success alerts (Slack, KokoNo) and prints execution summary. |

For detailed architectural specifications, see [Flow Architecture](docs/guide/flow-architecture.md).

### `check`

```bash
appitool check ios -b com.example.app
appitool check android -p com.example.app
```

### `build`

```bash
appitool build ios -d appstore
appitool build android -p com.example.app -d appstore
```

### `match`

```bash
appitool match ios appstore
appitool match ios adhoc --readonly -a "com.example.app,com.example.app.widget"
appitool match ios prune all
appitool match android
```

See [Code Signing (Match)](docs/guide/code-signing-match.md).

### `apple` / `firebase`

```bash
appitool apple list-apps -b com.example.app
appitool apple delete-identifier -a com.example.app
appitool firebase list-releases --platform ios -l 10
appitool firebase create-group -a qa-team -n "QA Team"
```

### `inspect` / `clean` / `notes`

```bash
appitool inspect -p ios -c Release --json
appitool clean --derived-data --dry-run
appitool notes -f v0.8.0 -t v0.9.0 -o CHANGELOG_DRAFT.md
```

### `kokono`

```bash
appitool kokono -m "Build completed successfully."
appitool kokono -m "Confidential deployment completed." -e "your_public_key"
```

### `status`

```bash
appitool status
```

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
