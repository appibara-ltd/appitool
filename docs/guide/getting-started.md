# Getting Started

![appitool](/banner.png)

`appitool` (`v0.9.0`) is a unified Swift CLI utility and release orchestration engine for Apple App Store Connect, Apple Developer Portal, Google Play Console, Firebase App Distribution, Firebase Authentication, and Git-backed code signing.

## Requirements

- **Prebuilt binary (`install.sh` / `self-update`)**:
  - **macOS**: Apple Silicon (`arm64`), macOS 13+
  - **Linux**: `x86_64` (`amd64`) or `arm64` (`aarch64`)
- **Platform build tooling** (only required when compiling mobile apps via `build` or `flow`):
  - **iOS**: macOS with Xcode command-line tools (`xcodebuild`, `xcrun`) and optionally `xcbeautify` (default formatter)
  - **Android**: Java JDK and project `./gradlew` wrapper
- **Building from source**: Swift `6.4+`

---

## Installation

### One-Line Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/appibara-ltd/appitool/main/install.sh | bash
```

The installer:
1. Detects your OS and CPU architecture (`darwin-arm64`, `linux-x86_64`, or `linux-arm64`).
2. Downloads the release tarball and `checksums.txt` from `appibara-ltd/appitool`.
3. Verifies the SHA256 checksum.
4. Installs the binary to `/usr/local/bin/appitool` (if writable) or `~/.local/bin/appitool` (automatically updating `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`, or `~/.config/fish/config.fish`).

### Installing from a Private Repository

If the repository is private, pass a GitHub Personal Access Token via `GITHUB_TOKEN` (or `GH_TOKEN`):

```bash
curl -fsSL -H "Authorization: Bearer $(gh auth token)" \
  https://raw.githubusercontent.com/appibara-ltd/appitool/main/install.sh | GITHUB_TOKEN=$(gh auth token) bash
```

### Build from Source

```bash
git clone https://github.com/appibara-ltd/appitool.git
cd appitool

# Build optimized release binary with minimal binary size
swift build -c release
strip .build/release/appitool

# Optional: Link to PATH
ln -sf "$(pwd)/.build/release/appitool" /usr/local/bin/appitool
```

You can also run directly via Swift Package Manager during development:

```bash
swift run appitool -h
```

---

## Upgrading

`appitool` includes a built-in self-updater with SHA256 verification:

```bash
# Check if a newer release is available
appitool self-update --check

# Upgrade in place
appitool self-update

# Force re-installation even if already on the latest version
appitool self-update --force
```

See [`appitool self-update`](/commands/self-update) for details.

---

## Quick Start

### 1. Create a `.env` File

Copy `.env.example` into your project root and configure your credentials:

```bash
cp .env.example .env
```

### 2. Inspect Local Project Identifiers

Discover iOS bundle identifiers (across targets/configurations) and Android `applicationId`, `namespace`, and product flavors in the current repository:

```bash
appitool list-identifiers
```

### 3. Verify Remote Store Connectivity

Validate your credentials and check the latest build numbers on App Store Connect, Google Play Console, or Firebase App Distribution:

```bash
# Check App Store Connect / TestFlight latest build
appitool check ios -d appstore

# Check Google Play Console latest build
appitool check android -d appstore

# Check Firebase App Distribution latest build
appitool check ios -d adhoc
appitool check android -d adhoc
```

### 4. Run a Dry-Run Release Flow

Validate all requirements, project detection, Match sync (in read-only mode), and build-number calculation without modifying project files or uploading binaries:

```bash
appitool flow ios -d appstore --dry-run
appitool flow android -d adhoc --dry-run
```
