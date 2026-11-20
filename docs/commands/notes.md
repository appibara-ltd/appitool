# `appitool notes`

Generates categorized Markdown release notes from Git commit history between two tags or revisions (`git log --no-merges`).

## How Commits Are Categorized

`GenerateReleaseNotesTask` parses Conventional Commit prefixes (`type(scope): description`):
- `feat` → **`### 🚀 Features`**
- `fix` → **`### 🐛 Bug Fixes`**
- All other commit types / non-conventional commits → **`### 🔧 Other Changes`**

Within each category, scoped commits are grouped under `* **<scope>**:`, and commit hashes are automatically formatted as clickable Markdown links when `remote.origin.url` resolves to an HTTP/HTTPS/SSH Git host (e.g. `([#abc1234](https://github.com/org/repo/commit/abc1234))`).

## Synopsis

```bash
appitool notes [options]
```

## Options

| Option | Default | Description |
|:---|:---|:---|
| `-f, --from <ref>` | Latest Git tag at or before `--to` (or last 20 commits if untagged) | Starting Git tag or commit reference (exclusive). If omitted and `--to` (or `HEAD`) already sits on a matching tag, no commits are returned; pass `-f` explicitly to inspect a tagged release. |
| `-t, --to <ref>` | `HEAD` | Ending Git tag or commit reference (inclusive). |
| `-p, --tag-prefix <prefix>` | — | Filter auto-detected tags by prefix when `--from` is omitted (e.g. `v`, `ios-v`, `android-`). |
| `-o, --output <path>` | Print to stdout | File path to write the generated Markdown release notes. |

## Examples

```bash
# Auto-detect commits since the latest Git tag (or last 20 commits if untagged)
appitool notes

# Auto-detect commits since the latest iOS-prefixed tag (e.g. ios-v1.2.0..HEAD)
appitool notes -p ios-v

# Print release notes from v0.8.0 to HEAD
appitool notes -f v0.8.0

# Generate notes between two tags and save to CHANGELOG_DRAFT.md
appitool notes -f v0.8.0 -t v0.9.0 -o CHANGELOG_DRAFT.md
```
