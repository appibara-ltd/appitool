# `appitool self-update`

Checks GitHub Releases (`appibara-ltd/appitool`) for a newer semantic version and upgrades the currently running `appitool` binary in place after verifying its SHA256 checksum against `checksums.txt` and, when the GitHub CLI (`gh`) is installed, its GitHub build provenance attestation.

## How It Works

1. Queries `https://api.github.com/repos/appibara-ltd/appitool/releases/latest`.
2. Compares the remote tag (`SemanticVersion`) against the running binary's version.
3. Selects the matching archive for the current OS & CPU architecture:
   - `appitool-darwin-arm64.tar.gz` (or `universal`)
   - `appitool-linux-x86_64.tar.gz` / `appitool-linux-arm64.tar.gz`
4. Downloads the archive and `checksums.txt` and verifies the SHA256 digest.
5. **Build provenance:** if `gh` is found on `PATH` (or in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`), fetches the archive's Sigstore attestation bundles from the public attestations API (`/repos/appibara-ltd/appitool/attestations/sha256:<digest>`) and runs `gh attestation verify --bundle … --repo appibara-ltd/appitool --signer-workflow appibara-ltd/appitool/.github/workflows/release.yml`. This proves the archive was built by the release workflow, not just uploaded to the release. No `gh auth login` is required. A missing or invalid attestation aborts the update; without `gh` the check is skipped with a notice.
6. Extracts `appitool` and atomically swaps the executable (with rollback on failure).

> [!TIP]
> If you hit GitHub API rate limits (e.g., in CI or shared networks), export `GITHUB_TOKEN` (or `GH_TOKEN`) or configure `GITHUB_TOKEN` in `.env`.

## Synopsis

```bash
appitool self-update [options]
```

## Flags

| Flag | Default | Description |
|:---|:---|:---|
| `--check` | `false` | Check whether an update is available without downloading or installing. |
| `--force` | `false` | Force download and re-installation even if already on the latest version. |
| `--skip-attestation` | `false` | Skip the GitHub build provenance check that runs when `gh` is installed (the SHA256 checksum is still verified). |

## Examples

```bash
# Check if a newer release exists
appitool self-update --check

# Upgrade to the latest release
appitool self-update

# Force reinstall (use sudo if installed into a root-owned /usr/local/bin)
sudo appitool self-update --force

# Update without the gh build provenance check
appitool self-update --skip-attestation
```
