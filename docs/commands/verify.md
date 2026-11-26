# `appitool verify`

Verifies a file's GitHub artifact attestation with [sigstore-swift](https://github.com/appibara-ltd/sigstore-swift), cross-checked with the GitHub CLI `gh` when it is installed. By default the file must be an `appitool` release archive (e.g. `appitool-darwin-arm64.tar.gz`), checked exactly as [`self-update`](/commands/self-update) checks it before installing. Use `--repo`, `--signer-workflow`, and `--predicate-type` to verify files attested by another GitHub repository, workflow, or predicate type.

## How It Works

1. Computes the file's SHA256 digest.
2. Fetches the attestation bundles for that digest from the repository's public attestations API (`/repos/<repo>/attestations/sha256:<digest>`; no `gh auth login` required for public repositories), or reads them from `--bundle`.
3. **sigstore-swift:** at least one bundle must verify against Sigstore's trusted root, fetched over TUF (public-good, or GitHub's instance with the TUF root embedded in appitool). TUF metadata is cached in `~/.sigstore/root` for one day. The bundle must:
   - be an in-toto statement for the file's digest with the `--predicate-type` predicate (default SLSA provenance v1, `https://slsa.dev/provenance/v1`);
   - be signed in GitHub Actions (issuer `https://token.actions.githubusercontent.com`) by the `--signer-workflow` workflow (certificate SAN `https://github.com/<signer-workflow>@…`; default `<repo>/.github/workflows/release.yml`);
   - come from `--repo` (certificate source repository `https://github.com/<repo>` and owner `https://github.com/<owner>`).
4. **`gh` cross-check (when installed, unless `--skip-gh`):** runs `gh attestation verify <file> --bundle … --repo <repo> --signer-workflow <signer-workflow> --predicate-type <predicate-type>`. If `gh` rejects what sigstore-swift accepted, the command fails.

The command exits with a non-zero status when the file has no attestation, no attestation verifies, a TUF repository is unreachable, or `gh` disagrees.

> [!NOTE]
> Only files the signing workflow attested verify. appitool's release workflow attests the `appitool-*.tar.gz` archives only, so `checksums.txt`, `install.sh`, and the extracted binary do not.

> [!TIP]
> If you hit GitHub API rate limits, or the repository is private, export `GITHUB_TOKEN` (or `GH_TOKEN`) or configure `GITHUB_TOKEN` in `.env`.

## Synopsis

```bash
appitool verify -f <file> [options]
```

## Options

| Option | Default | Description |
|:---|:---|:---|
| `-f, --file <path>` | **Required** | Path to the file to verify. |
| `--bundle <path>` | — | Sigstore bundle file (one JSON document or JSON Lines) to verify instead of fetching the file's attestations from GitHub, e.g. from `gh attestation download`. |
| `--repo <owner/name>` | `appibara-ltd/appitool` | Repository the file must have been built from; attestations are fetched from it. |
| `--signer-workflow <workflow>` | `<repo>/.github/workflows/release.yml` | Workflow that must have signed the attestation, as `owner/repo/.github/workflows/<file>.yml` (a `github.com/` or `https://github.com/` prefix and an `@ref` suffix are accepted and ignored). |
| `--predicate-type <uri>` | `https://slsa.dev/provenance/v1` | In-toto predicate type the attestation must have. |
| `--skip-gh` | `false` | Skip the `gh attestation verify` cross-check. |

## Examples

```bash
# Verify a downloaded appitool release archive
appitool verify -f ~/Downloads/appitool-darwin-arm64.tar.gz

# Verify against a bundle file saved with `gh attestation download`
appitool verify -f appitool-linux-x86_64.tar.gz --bundle sha256:<digest>.jsonl

# Verify another project's artifact, signed by its build workflow
appitool verify -f tool.zip --repo octo-org/octo-tool --signer-workflow octo-org/octo-tool/.github/workflows/build.yml

# sigstore-swift only, without the gh cross-check
appitool verify -f appitool-darwin-arm64.tar.gz --skip-gh
```
