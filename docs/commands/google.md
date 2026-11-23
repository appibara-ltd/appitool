# `appitool google`

Direct management of Google Play Console store visuals and resources via the Google Play Developer API v3.

All `google screenshots` subcommands (except `types`) accept [`GooglePlayAppOptions`](/commands/overview#googleplayappoptions) (`-g, --google-key`, `--package-name`), falling back to `GOOGLE_KEY`, `GOOGLE_PACKAGE_NAME` in `.env`, or auto-detection from the local Android project.

> [!NOTE]
> **CI Guard:** Destructive subcommand `screenshots delete` accepts [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and is skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

## Synopsis

```bash
appitool google <subcommand> [options]
```

## Subcommands Summary

| Domain | Subcommand | Description |
|:---|:---|:---|
| **Store Visuals (`screenshots`)** | `screenshots list` | Lists existing store screenshots and graphic assets by locale and image type. |
| | `screenshots upload` | Uploads PNG/JPEG screenshots, icons, feature graphics, or banners and commits an edit. |
| | `screenshots download` | Downloads store screenshots and graphics locally to `~/.appitool/screenshots/<package>/google/` (or `-o`). |
| | `screenshots delete` | Deletes an individual image by ID or all images of a given type for a locale. |
| | `screenshots types` | Lists all supported Google Play `imageType` keys, aliases, and descriptions. |

---

## Supported Store Visual Types

| CLI Key | Aliases | API `imageType` | Description |
|:---|:---|:---|:---|
| `phone` | `phone-screenshots`, `phone_screenshots` | `phoneScreenshots` | Phone screenshots (PNG/JPEG, 2–8 images) |
| `tablet7` | `seven-inch`, `7-inch`, `seven-inch-screenshots` | `sevenInchScreenshots` | 7-inch tablet screenshots (PNG/JPEG) |
| `tablet10` | `ten-inch`, `10-inch`, `ten-inch-screenshots` | `tenInchScreenshots` | 10-inch tablet screenshots (PNG/JPEG) |
| `tv` | `tv-screenshots`, `tv_screenshots` | `tvScreenshots` | Android TV screenshots (PNG/JPEG) |
| `wear` | `watch`, `wear-screenshots`, `wear_screenshots` | `wearScreenshots` | Wear OS screenshots (PNG/JPEG) |
| `icon` | `app-icon` | `icon` | High-res app icon (512x512 PNG/JPEG) |
| `feature-graphic` | `feature`, `feature_graphic` | `featureGraphic` | Feature graphic banner (1024x500 PNG/JPEG) |
| `tv-banner` | `banner`, `tv_banner` | `tvBanner` | Android TV banner (1280x720 PNG/JPEG) |

---

## Screenshots & Visuals (`appitool google screenshots`)

### `appitool google screenshots list`

Opens a temporary read-only Google Play edit session (deleted automatically after reading), lists configured store listing languages (or the specified `--locale`), and prints images for each matching `(language, imageType)` slot.

| Option | Description |
|:---|:---|
| `--locale <bcp47>` | Filter by BCP-47 language code (e.g. `en-US`, `tr-TR`). Omit to inspect all listing languages. |
| `-t, --type <type>` | Filter by image type (e.g. `phone`, `tablet7`, `feature-graphic`, `icon`). Omit to inspect all types. |

```bash
appitool google screenshots list --package-name com.example.app
appitool google screenshots list --locale en-US -t phone
```

### `appitool google screenshots upload`

Uploads PNG/JPEG screenshots and graphics to Google Play Console inside a single atomic edit transaction—either for flat image path(s) (`--locale` required, `-t` defaults to `phone`) or symmetrically from a `<locale>/<type>/` directory tree defaulting to `~/.appitool/screenshots/<package-name>/google/` (`--locale` and `-t` optional filters).

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | — | BCP-47 language code (e.g. `en-US`, `tr-TR`). Required for flat files; optional filter for `<locale>/<type>/` trees. |
| `-t, --type <type>` | `phone` (flat) / all (tree) | Target image type (`phone`, `tablet7`, `tablet10`, `tv`, `wear`, `icon`, `feature-graphic`, `tv-banner`). |
| `--replace` | `false` | Delete existing images in each target slot before uploading. |
| `--validate-only` | `false` | Validate the edit session (`edits.validate`) without committing changes. |
| `--changes-not-sent-for-review` | `false` | Commit changes without automatically sending them for Google Play review. |
| `--dry-run` | `false` | Validate local image files and preview target slots without contacting Google Play. |
| `<paths...>` | `~/.appitool/screenshots/<package-name>/google/` | Optional PNG/JPEG file(s), flat directory, or `<locale>/<type>/` directory tree. |

```bash
# Bulk-upload all locales and image types from ~/.appitool/screenshots/<package-name>/google/
appitool google screenshots upload --replace

# Bulk-upload only phone screenshots across all locales in the default folder
appitool google screenshots upload -t phone --replace

# Replace phone screenshots for en-US from a flat directory
appitool google screenshots upload \
  --package-name com.example.app \
  --locale en-US \
  -t phone \
  --replace \
  ./screenshots/android/en-US/phone/

# Upload a feature graphic banner
appitool google screenshots upload \
  --package-name com.example.app \
  --locale en-US \
  -t feature-graphic \
  ./assets/feature-graphic.png
```

### `appitool google screenshots download`

Downloads store screenshots and graphics from Google Play Console into `<output>/<locale>/<type>/01.<ext>` (rewriting CDN URLs to `=s0` for full original resolution). Opens a short-lived read-only edit session that is deleted before downloading binaries. By default, files are stored per project under `~/.appitool/screenshots/<package-name>/google/`.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | — | Filter by BCP-47 language code (e.g. `en-US`, `tr-TR`). Omit to download all listing languages. |
| `-t, --type <type>` | — | Filter by image type (e.g. `phone`, `tablet7`, `feature-graphic`, `icon`). Omit to download all types. |
| `-o, --output <dir>` | `~/.appitool/screenshots/<package-name>/google/` | Custom destination root directory. |
| `--dry-run` | `false` | Preview target local paths and CDN URLs without downloading files. |

```bash
# Download all Google Play visuals to ~/.appitool/screenshots/<package-name>/google/
appitool google screenshots download

# Download only en-US phone screenshots into a custom folder
appitool google screenshots download --package-name com.example.app --locale en-US -t phone -o ./downloads/android
```

### `appitool google screenshots delete`

Deletes a specific image by ID or all images of a given type for a locale in Google Play Console (guarded in CI mode).

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | **Required** | BCP-47 language code (e.g. `en-US`, `tr-TR`). |
| `-t, --type <type>` | **Required** | Target image type (`phone`, `tablet7`, `tablet10`, `tv`, `wear`, `icon`, `feature-graphic`, `tv-banner`). |
| `--id <image-id>` | — | Specific Google Play image ID to delete (mutually exclusive with `--all`). |
| `--all` | `false` | Delete all images of the specified type for the language (mutually exclusive with `--id`). |
| `--changes-not-sent-for-review` | `false` | Commit changes without automatically sending them for Google Play review. |
| `--dry-run` | `false` | Preview matching image(s) without deleting or committing changes. |

```bash
# Preview images that would be removed
appitool google screenshots delete --locale en-US -t phone --all --dry-run

# Delete a single image by ID
appitool google screenshots delete --locale en-US -t phone --id AO7oq_example_id
```

### `appitool google screenshots types`

Prints all supported Google Play `imageType` keys, aliases, API names, and descriptions (no credentials required).

```bash
appitool google screenshots types
```
