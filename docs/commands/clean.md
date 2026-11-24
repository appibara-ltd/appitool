# `appitool clean`

Scans `~/.appitool/ios` and `~/.appitool/android` and deletes previously built archives (`.xcarchive`, `.ipa`, `.aab`, `.apk`), optional Xcode DerivedData directories, and (with `--assets`) downloaded store assets under `~/.appitool/assets` (plus the legacy `~/.appitool/screenshots` folder used by older versions). System folders such as `~/.appitool/android/keystores` and `tmp` are preserved, and asset folders are only touched with `--assets`.

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
| `--assets` | `false` | Also clean downloaded store assets (screenshots, header/search images, Google Play graphics, and their sync manifests) under `~/.appitool/assets/<project>/<store>/` and the legacy `~/.appitool/screenshots/<project>/<store>/` (removed once empty). A custom `STORE_ASSETS_PATH` folder is never cleaned (it usually lives in your project). `-p ios` limits it to `apple`, `-p android` to `google`, `all` cleans every store folder. Combined with `--ddo`, cleans derived data and assets but no build archives. |
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

# Preview build artifacts plus downloaded App Store assets for iOS
appitool clean -p ios --assets --dry-run
```
