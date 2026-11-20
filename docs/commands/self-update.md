# `appitool self-update`

Checks GitHub Releases (`appibara-ltd/appitool`) for a newer semantic version and upgrades the currently running `appitool` binary in place after verifying its SHA256 checksum against `checksums.txt`.

## How It Works

1. Queries `https://api.github.com/repos/appibara-ltd/appitool/releases/latest`.
2. Compares the remote tag (`SemanticVersion`) against the running binary's version.
3. Selects the matching archive for the current OS & CPU architecture:
   - `appitool-darwin-arm64.tar.gz` (or `universal`)
   - `appitool-linux-x86_64.tar.gz` / `appitool-linux-arm64.tar.gz`
4. Downloads the archive and `checksums.txt`, verifies the SHA256 digest, extracts `appitool`, and atomically swaps the executable (with rollback on failure).

> [!TIP]
> If the release repository is private or you hit GitHub API rate limits, export `GITHUB_TOKEN` (or `GH_TOKEN`) or configure `GITHUB_TOKEN` in `.env`.

## Synopsis

```bash
appitool self-update [options]
```

## Flags

| Flag | Default | Description |
|:---|:---|:---|
| `-c, --check` | `false` | Check whether an update is available without downloading or installing. |
| `-f, --force` | `false` | Force download and re-installation even if already on the latest version. |

## Examples

```bash
# Check if a newer release exists
appitool self-update --check

# Upgrade to the latest release
appitool self-update

# Force reinstall (use sudo if installed into a root-owned /usr/local/bin)
sudo appitool self-update --force
```
