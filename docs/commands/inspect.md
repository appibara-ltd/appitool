# `appitool inspect`

Inspects local iOS (Xcode) and Android (Gradle) project files in a workspace and prints resolved identifiers, versions, build numbers / version codes, targets, schemes, and product flavors. When `-s, --scheme` is omitted on iOS, all distributable schemes are inspected and listed; when `--flavor` is omitted on Android, all product flavors are listed with their effective application IDs, versions, and version codes.

## Synopsis

```bash
appitool inspect [options]
```

## Options & Flags

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-p, --platform <platform>` | `all` | Platform to inspect: `all`, `ios`, or `android`. |
| `-w, --workspace-name <name>` | Auto-detected | Custom Xcode workspace or project name. |
| `-s, --scheme <scheme>` | All distributable schemes | Specific Xcode scheme name to inspect (omit to list every distributable scheme). |
| `-c, --configuration <config>` | Auto-inferred | Xcode build configuration (e.g., `Debug`, `Release`). |
| `--flavor <name>` | All product flavors | Specific Android product flavor to resolve (omit to list all `productFlavors` with resolved overrides). |
| `-d, --project-dir <path>` / `--workspace-root <path>` | Current directory | Path to the project root directory. |
| `--json` | `false` | Output results as pretty-printed, key-sorted JSON (`ios.schemes[]`, `ios.version`, `ios.buildNumber`, `android.versionName`, `android.versionCode`, and resolved `android.flavors[]`). |

## Examples

```bash
# Inspect all iOS schemes and all Android flavors (including versions and build numbers)
appitool inspect

# Inspect a single iOS scheme as JSON
appitool inspect -p ios -s MyApp -c Release --json

# Inspect Android metadata filtered to a single product flavor
appitool inspect -p android --flavor staging

# Inspect a project located in another directory
appitool inspect --workspace-root ~/projects/my-mobile-app
```
