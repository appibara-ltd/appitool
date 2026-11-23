# `appitool clean`

Scans `~/.appitool/ios` and `~/.appitool/android` and deletes previously built archives (`.xcarchive`, `.ipa`, `.aab`, `.apk`) and optional Xcode DerivedData directories. System folders such as `~/.appitool/android/keystores` and `tmp` are preserved.

## Synopsis

```bash
appitool clean [options]
```

## Options & Flags

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-p, --platform <platform>` | `all` | Platform to clean: `ios`, `android`, or `all`. |
| `--dd, --derived-data` | `false` | Also clean Xcode `derivedData` directories under `~/.appitool/ios/<project>/derivedData`. |
| `--ddo, --derived-data-only` | `false` | Only clean Xcode `derivedData` directories without deleting build archives. |
| `--dry-run` | `false` | Scan and display items with disk sizes without deleting anything. |

## Examples

```bash
# Preview all build artifacts and Xcode DerivedData that would be removed
appitool clean --derived-data --dry-run

# Delete all iOS and Android build artifacts (keeps DerivedData)
appitool clean

# Delete only Xcode DerivedData directories
appitool clean --ddo

# Clean only Android build outputs
appitool clean -p android
```
