# `appitool google`

Direct management of Google Play Console store visuals and resources via the Google Play Developer API v3.

All `google assets` subcommands (except `types`) accept [`GooglePlayAppOptions`](/commands/overview#googleplayappoptions) (`-g, --google-key`, `--package-name`), falling back to `GOOGLE_KEY`, `GOOGLE_PACKAGE_NAME` in `.env`, or auto-detection from the local Android project.

The default local folder is `~/.appitool/assets/<package-name>/google/`. When [`STORE_ASSETS_PATH`](/guide/configuration#store-assets-apple-assets-google-assets) is set, it is `<STORE_ASSETS_PATH>/google/` instead (default paths below then refer to that folder).

> [!NOTE]
> **CI Guard:** Destructive subcommand `assets delete` accepts [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and is skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

## Synopsis

```bash
appitool google <subcommand> [options]
```

## Subcommands Summary

| Domain | Subcommand | Description |
|:---|:---|:---|
| **Store Visuals (`assets`)** | `assets list` | Lists existing store screenshots and graphic assets by locale and image type. |
| | `assets upload` | Uploads PNG/JPEG screenshots, icons, feature graphics, or banners and commits an edit. |
| | `assets download` | Downloads store screenshots and graphics locally to `~/.appitool/assets/<package>/google/` (or `-o`). |
| | `assets delete` | Deletes an individual image by ID or all images of a given type for a locale. |
| | `assets types` | Lists all supported Google Play `imageType` keys, aliases, and descriptions. |

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

## Screenshots & Visuals (`appitool google assets`)

### `appitool google assets list`

Opens a temporary read-only Google Play edit session (deleted automatically after reading), lists configured store listing languages (or the specified `--locale`), and prints images for each matching `(language, imageType)` slot.

| Option | Description |
|:---|:---|
| `--locale <bcp47>` | Filter by BCP-47 language code (e.g. `en-US`, `tr-TR`). Omit to inspect all listing languages. |
| `-t, --type <type>` | Filter by image type (e.g. `phone`, `tablet7`, `feature-graphic`, `icon`). Omit to inspect all types. |

```bash
appitool google assets list --package-name com.example.app
appitool google assets list --locale en-US -t phone
```

### `appitool google assets upload`

Uploads PNG/JPEG screenshots and graphics to Google Play Console inside a single atomic edit transaction—either for flat image path(s) (`--locale` required, `-t` defaults to `phone`) or symmetrically from a `<locale>/<type>/` directory tree defaulting to `~/.appitool/assets/<package-name>/google/` (`--locale` and `-t` optional filters).

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | — | BCP-47 language code (e.g. `en-US`, `tr-TR`). Required for flat files; optional filter for `<locale>/<type>/` trees. |
| `-t, --type <type>` | `phone` (flat) / all (tree) | Target image type (`phone`, `tablet7`, `tablet10`, `tv`, `wear`, `icon`, `feature-graphic`, `tv-banner`). |
| `--replace` | `false` | Delete existing images in each target slot before uploading. For `<locale>/<type>/` trees, also writes each folder's sync manifest after a committed edit. |
| `--sync` | `false` | Mirror `<locale>/<type>/` folders onto their slots using `.appitool-manifest.json` in a single edit (see [Image sync](#image-sync)). Cannot be combined with `--replace`; requires a directory tree, not explicit files or a flat folder. |
| `--validate-only` | `false` | Validate the edit session (`edits.validate`) without committing changes. |
| `--changes-not-sent-for-review` | `false` | Commit changes without automatically sending them for Google Play review. |
| `--dry-run` | `false` | Validate local image files and preview target slots without contacting Google Play. With `--sync`, reads Google Play in a discarded edit and prints the sync plan. |
| `<paths...>` | `~/.appitool/assets/<package-name>/google/` | Optional PNG/JPEG file(s), flat directory, or `<locale>/<type>/` directory tree. |

```bash
# Bulk-upload all locales and image types from ~/.appitool/assets/<package-name>/google/
appitool google assets upload --replace

# Bulk-upload only phone screenshots across all locales in the default folder
appitool google assets upload -t phone --replace

# Replace phone screenshots for en-US from a flat directory
appitool google assets upload \
  --package-name com.example.app \
  --locale en-US \
  -t phone \
  --replace \
  ./screenshots/android/en-US/phone/

# Upload a feature graphic banner
appitool google assets upload \
  --package-name com.example.app \
  --locale en-US \
  -t feature-graphic \
  ./assets/feature-graphic.png

# Preview, then apply, only the local changes since the last download/sync
appitool google assets upload --sync --dry-run
appitool google assets upload --sync
```

#### Image sync

`download`, `upload --replace` (directory trees), and `upload --sync` write a `.appitool-manifest.json` into each `<locale>/<type>/` folder. For every file it records the SHA-256 of the local file and Google Play's image `sha256`; remote images are matched by that hash.

Local files are classified the same way as for [`apple assets upload --sync`](/commands/apple#asset-sync): unchanged (including renamed with the same content), edited, new, and removed. Because Google Play has no reorder call and appends uploads, each slot is rebuilt from the first position that differs:

1. Keep the longest leading run of images that are unchanged and already in place.
2. Delete every remote image after that run.
3. Upload the remaining local files in file-name order (unchanged files after the first change are re-uploaded from the local file).

Examples: editing the 6th of 8 phone screenshots deletes and uploads 6–8; appending a new last file uploads only that file; editing the 1st file re-uploads the whole slot.

All slots are planned first; any planning error aborts before an edit with changes is opened. All changes are applied in one edit and committed once, so a failure leaves Google Play unchanged. Manifests are rewritten only after a successful commit (not with `--validate-only`).

| Rule | Behavior |
|:---|:---|
| No manifest, remote slot empty | Bootstrap: upload all files in file-name order and write the manifest. |
| No manifest, remote slot has images | Error: run `download` first or use `--replace`. |
| Manifest for a different slot | Error: run `download` again or delete the manifest and use `--replace`. |
| Remote image not in the manifest after the first change | Error (it cannot be re-uploaded): run `download` again or use `--replace`. |
| Limits | Phone 2–8, other screenshot types up to 8, `icon` / `feature-graphic` / `tv-banner` exactly 1. |

A `<locale>/<type>/` folder with no images is skipped, so emptying a folder does not clear its slot; use `google assets delete` for that.

### `appitool google assets download`

Downloads store screenshots and graphics from Google Play Console into `<output>/<locale>/<type>/01.<ext>` (rewriting CDN URLs to `=s0` for full original resolution). Opens a short-lived read-only edit session that is deleted before downloading binaries. By default, files are stored per project under `~/.appitool/assets/<package-name>/google/`.

Each slot folder also gets a `.appitool-manifest.json` for [`upload --sync`](#image-sync). Images written by a previous download that are no longer on Google Play are removed; other local images are kept and reported (`upload --sync` would add them).

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | — | Filter by BCP-47 language code (e.g. `en-US`, `tr-TR`). Omit to download all listing languages. |
| `-t, --type <type>` | — | Filter by image type (e.g. `phone`, `tablet7`, `feature-graphic`, `icon`). Omit to download all types. |
| `-o, --output <dir>` | `~/.appitool/assets/<package-name>/google/` | Custom destination root directory. |
| `--dry-run` | `false` | Preview target local paths and CDN URLs without downloading files. |

```bash
# Download all Google Play visuals to ~/.appitool/assets/<package-name>/google/
appitool google assets download

# Download only en-US phone screenshots into a custom folder
appitool google assets download --package-name com.example.app --locale en-US -t phone -o ./downloads/android
```

### `appitool google assets delete`

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
appitool google assets delete --locale en-US -t phone --all --dry-run

# Delete a single image by ID
appitool google assets delete --locale en-US -t phone --id AO7oq_example_id
```

### `appitool google assets types`

Prints all supported Google Play `imageType` keys, aliases, API names, and descriptions (no credentials required).

```bash
appitool google assets types
```
