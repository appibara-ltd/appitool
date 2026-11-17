# `appitool list-identifiers`

Inspects local iOS (Xcode) and Android (Gradle) project files in a workspace and prints resolved bundle identifiers, targets, `applicationId`, `namespace`, package name, and product flavors.

## Synopsis

```bash
appitool list-identifiers [options]
```

## Options & Flags

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-p, --platform <platform>` | `all` | Platform to inspect: `all`, `ios`, or `android`. |
| `-w, --workspace-name <name>` | Auto-detected | Custom Xcode workspace or project name. |
| `-s, --scheme <scheme>` | Auto-inferred | Xcode scheme name. |
| `-c, --configuration <config>` | Auto-inferred | Xcode build configuration (e.g., `Debug`, `Release`). |
| `--project-dir <path>` / `--workspace-root <path>` | Current directory | Path to the project root directory. |
| `--json` | `false` | Output results as pretty-printed, key-sorted JSON (ideal for CI scripts and AI agents). |

## Examples

```bash
# Inspect both iOS and Android identifiers in current directory
appitool list-identifiers

# Inspect only iOS identifiers for Release configuration as JSON
appitool list-identifiers -p ios -c Release --json

# Inspect a project located in another directory
appitool list-identifiers --workspace-root ~/projects/my-mobile-app
```
