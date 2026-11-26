# `appitool self-update`

Checks GitHub Releases (`appibara-ltd/appitool`) for a newer semantic version and upgrades the currently running `appitool` binary in place after verifying its SHA256 checksum against `checksums.txt` and its GitHub build provenance attestation (with [sigstore-swift](https://github.com/appibara-ltd/sigstore-swift), cross-checked with the GitHub CLI `gh` when it is installed).

## How It Works

1. Queries `https://api.github.com/repos/appibara-ltd/appitool/releases/latest`.
2. Compares the remote tag (`SemanticVersion`) against the running binary's version.
3. Selects the matching archive for the current OS & CPU architecture:
   - `appitool-darwin-arm64.tar.gz` (or `universal`)
   - `appitool-linux-x86_64.tar.gz` / `appitool-linux-arm64.tar.gz`
4. Downloads the archive and `checksums.txt` and verifies the SHA256 digest.
5. **Build provenance:** fetches the archive's Sigstore attestation bundles from the public attestations API (`/repos/appibara-ltd/appitool/attestations/sha256:<digest>`; no `gh auth login` required). This proves the archive was built by the release workflow, not just uploaded to the release.
   - **sigstore-swift (always):** at least one bundle must verify against Sigstore's trusted root, fetched over TUF (public-good from `tuf-repo-cdn.sigstore.dev`, or GitHub's instance from `tuf-repo.github.com` with the TUF root embedded in appitool, the same one `gh` ships). TUF metadata is cached in `~/.sigstore/root` for one day. The bundle must be an SLSA v1 provenance statement for the archive's SHA256 digest, signed by `https://github.com/appibara-ltd/appitool/.github/workflows/release.yml@…` (issuer `https://token.actions.githubusercontent.com`, source repository `https://github.com/appibara-ltd/appitool`). A missing or invalid attestation, or an unreachable TUF repository, aborts the update.
   - **`gh` cross-check (when installed):** if `gh` is found on `PATH` (or in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`), also runs `gh attestation verify --bundle … --repo appibara-ltd/appitool --signer-workflow appibara-ltd/appitool/.github/workflows/release.yml`. If `gh` rejects what sigstore-swift accepted, the update is aborted as a disagreement. Without `gh` the cross-check is skipped with a notice.
6. Extracts `appitool` and atomically swaps the executable (with rollback on failure).

To run the build provenance check on an archive you downloaded yourself, use [`appitool verify`](/commands/verify).

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
| `--skip-attestation` | `false` | Skip the GitHub build provenance check (sigstore-swift and the `gh` cross-check); the SHA256 checksum is still verified. |

## Examples

```bash
# Check if a newer release exists
appitool self-update --check

# Upgrade to the latest release
appitool self-update

# Force reinstall (use sudo if installed into a root-owned /usr/local/bin)
sudo appitool self-update --force

# Update without the build provenance check
appitool self-update --skip-attestation
```
