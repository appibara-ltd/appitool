# `appitool google`

Direct management of Google Play Console store visuals and resources via the Google Play Developer API v3.

All `google assets` subcommands (except `types`) accept [`GooglePlayAppOptions`](/commands/overview#googleplayappoptions) (`-g, --google-key`, `--package-name`), falling back to `GOOGLE_KEY`, `GOOGLE_PACKAGE_NAME` in `.env`, or auto-detection from the local Android project.

The default local folder is `~/.appitool/assets/<package-name>/google/`. When [`STORE_ASSETS_PATH`](/guide/configuration#store-assets-apple-assets-google-assets) is set, it is `<STORE_ASSETS_PATH>/google/` instead (default paths below then refer to that folder).

> [!NOTE]
> **CI Guard:** Destructive subcommands (`assets delete`, `delete-user`, `cancel-invitation`, `revoke-access`) accept [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and are skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

## Synopsis

```bash
appitool google <subcommand> [options]
```

## Subcommands Summary

| Domain | Subcommand | Description |
|:---|:---|:---|
| **Apps** | `list-apps` | Lists apps accessible with the service account key (package name and Play Console title). |
| | `signing-certs` | Shows SHA-1 / SHA-256 of Play App Signing certificates (incl. hybrid post-quantum) from Play-generated APKs or local certificate files. |
| **Store Visuals (`assets`)** | `assets list` | Lists existing store screenshots and graphic assets by locale and image type. |
| | `assets upload` | Uploads PNG/JPEG screenshots, icons, feature graphics, or banners and commits an edit. |
| | `assets download` | Downloads store screenshots and graphics locally to `~/.appitool/assets/<package>/google/` (or `-o`). |
| | `assets delete` | Deletes an individual image by ID or all images of a given type for a locale. |
| | `assets types` | Lists all supported Google Play `imageType` keys, aliases, and descriptions. |
| **Store Listing Text (`metadata`)** | `metadata list` | Shows title, short/full description, and video per language. |
| | `metadata download` | Writes listing text to `<locale>/metadata/<field>.txt` files. |
| | `metadata upload` | Sends changed fields in one edit and commits it. |
| **Users & Invitations** | `list-users` | Lists developer account users with account and per-app permissions. |
| | `invite-user` | Invites a user (account permissions and/or access to one app). |
| | `update-user` | Changes a user's account permissions or access expiration. |
| | `delete-user` | Removes a user. |
| | `list-invitations` | Lists pending or expired invitations. |
| | `cancel-invitation` | Cancels a pending invitation. |
| | `grant-access` | Gives a user permissions for one app (creates or replaces the grant). |
| | `revoke-access` | Removes a user's permissions for one app. |

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

---

## Metadata (`appitool google metadata`)

Manages Google Play store listing text as one plain-text file per field: `<root>/<locale>/metadata/<field>.txt`, where `<root>` is `$STORE_ASSETS_PATH/google/` or `~/.appitool/assets/<package-name>/google/` (the same folder as `google assets`; image commands ignore `metadata/` folders). Store listings have no versions, so there is one current set of files per language. Release notes ("What's new") belong to track releases on Google Play and are not part of listing metadata.

| File | Field | Limit |
|:---|:---|:---|
| `title.txt` | Title | 30 |
| `short_description.txt` | Short description | 80 |
| `full_description.txt` | Full description | 4000 |
| `video.txt` | Promo video URL | — |

**App-level details** (one value for the app, `edits.details`) live in `<root>/metadata/<field>.txt`: `contact_email.txt`, `contact_phone.txt`, `contact_website.txt`, and `default_language.txt` (BCP-47, e.g. `en-US`).

### `appitool google metadata list`

Shows the app-level details (`[app]`) and every listing field per language with its character count and limit (read-only edit, discarded).

| Option | Description |
|:---|:---|
| `--locale <bcp47>` | Show only this language (app-level details are skipped). |

### `appitool google metadata download`

Writes each non-empty field to `<locale>/metadata/<field>.txt` and the app-level details to `metadata/<field>.txt`. Existing files are overwritten.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | — | Download only this language (app-level details are skipped). |
| `-o, --output <dir>` | `$STORE_ASSETS_PATH/google/` or `~/.appitool/assets/<package-name>/google/` | Metadata root directory. |
| `--dry-run` | `false` | Preview files without writing them. |

### `appitool google metadata upload`

Compares local files with the current listings and app details (surrounding whitespace ignored) and patches only fields that differ, all languages and the app details in one edit committed once. Missing and empty files are ignored. Length limits are checked before the edit is opened; nothing is sent when there are no changes. Local languages without a Play listing are skipped with a warning.

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `--locale <bcp47>` | — | Upload only this language (app-level details are skipped). |
| `--validate-only` | `false` | Validate the edit (`edits.validate`) without committing. |
| `--changes-not-sent-for-review` | `false` | Commit without automatically sending the changes for review. |
| `--dry-run` | `false` | Print the per-field changes without opening an edit with changes. |
| `<path>` | `$STORE_ASSETS_PATH/google/` or `~/.appitool/assets/<package-name>/google/` | Metadata root containing `<locale>/metadata/` folders. |

```bash
appitool google metadata download
appitool google metadata upload --dry-run
appitool google metadata upload
```

---

## Apps

### `appitool google list-apps`

Lists every app the service account can access, using the Play Developer Reporting API `apps.search` (`GET https://playdeveloperreporting.googleapis.com/v1beta1/apps:search`, all pages). Useful for finding package names (`GOOGLE_PACKAGE_NAME`) and checking that a key works. It does not return Play Console account IDs; no Google Play API exposes those (see [`GOOGLE_PLAY_ACCOUNT_ID`](/guide/configuration)).

Requires the **Google Play Developer Reporting API** to be enabled in the service account's Google Cloud project (HTTP 403 otherwise) and access to the apps in Play Console. The title is the one set in Play Console and may not be live yet.

| Option | Description |
|:---|:---|
| `-g, --google-key <key>` | Service account key (`GOOGLE_KEY`). |
| `-n, --name <text>` | Filter by app title (case-insensitive substring). |
| `-l, --limit <count>` | Maximum number of apps to show. |

```bash
appitool google list-apps
appitool google list-apps -n kokono
```

### `appitool google signing-certs`

Shows the SHA-1 and SHA-256 fingerprints of the certificates Play App Signing uses, e.g. for Firebase, Google Sign-In, or `assetlinks.json`. Play Console's certificate download can contain three certificates: `deployment_cert.der` (app signing, RSA), `hybrid_classical_cert.der` (RSA), and `hybrid_pqc_cert.der` (post-quantum ML-DSA); all are covered.

**From the API (default):**

1. Reads the Play-generated APKs of a version code (`GET applications/{package}/generatedApks/{versionCode}`), grouped by signing key; the API reports each key's certificate SHA-256.
2. Downloads the smallest Play-generated APK per signing key (a config split of a few KB when available, otherwise a standalone or universal APK; held in memory only) and reads every certificate from its APK Signing Block — v2, v3, v3.1, the `hybrid` block (`0x70E1C89F`, Play's classical + post-quantum certificates; not in Android's public docs, identified from Play-generated APKs), and other unknown blocks (shown as `block 0x…`) — then prints SHA-1, SHA-256, and the algorithm (RSA, ECDSA, ML-DSA-44/65/87) of each and whether it matches the API's SHA-256.

Generated APKs exist for app bundles (AAB) uploaded with Play App Signing. The service account needs release access to the app (HTTP 403 otherwise). The upload key certificate is not available through the API; it is your own keystore's certificate (`appitool match android`).

**From local files (`-f`):** fingerprints certificate files directly (DER `.der`/`.cer`/`.crt` or PEM `.pem`; folders are expanded), without any API call — for example the folder Play Console's certificate download creates. A fingerprint is the hash of the DER bytes, so this also works for post-quantum certificates that older tools such as `openssl` cannot parse.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` / project | App to inspect (API mode). |
| `--version-code <code>` | Highest version code on your tracks | Version code whose generated APKs are read. |
| `--sha256-only` | `false` | Only print the API's SHA-256 values (no APK download, no SHA-1). |
| `-f, --file <path>` | — | Certificate file or folder to fingerprint locally (repeatable). Skips the API. |
| `-g, --google-key <key>` | `GOOGLE_KEY` | Service account key (API mode). |

```bash
# Fingerprints from Play (latest version code)
appitool google signing-certs

# Fingerprints of the certificates downloaded from Play Console
appitool google signing-certs -f ~/Downloads/certificates
```

---

## Users & Invitations

Manages Play Console users of the developer account through the Play Developer API `users` and `grants` resources. A user has account-wide permissions (`developerAccountPermissions`) and per-app grants (`appLevelPermissions`). Google has no separate invitation object: an invited user has `accessState` `INVITED` (or `INVITATION_EXPIRED`) until they accept.

All user commands accept `-g, --google-key` (`GOOGLE_KEY`) and `--account-id <id>` (`GOOGLE_PLAY_ACCOUNT_ID`): your Play Console account ID, the number in `play.google.com/console/developers/<id>` (not the Google Cloud project, service account, or package name). The service account needs the **Manage users and permissions** (admin) permission in Play Console; API errors are shown with a likely cause (e.g. 403 → missing permission or wrong account ID).

**Permission values** are comma-separated and case-insensitive, written as `can-see-all-apps` or `CAN_SEE_ALL_APPS`:

- Account-wide (`--permissions` on `invite-user` / `update-user`; the `_GLOBAL` suffix is optional): `can-see-all-apps`, `can-view-financial-data`, `can-manage-permissions`, `can-edit-games`, `can-publish-games`, `can-reply-to-reviews`, `can-manage-public-apks`, `can-manage-track-apks`, `can-manage-track-users`, `can-manage-public-listing`, `can-manage-draft-apps`, `can-create-managed-play-apps`, `can-change-managed-play-setting`, `can-manage-orders`, `can-manage-app-content`, `can-view-non-financial-data`, `can-view-app-quality`, `can-manage-deeplinks`, `can-view-connected-apps`, `can-edit-connected-apps`.
- Per app (`--app-permissions` on `invite-user`, `--permissions` on `grant-access`): `can-access-app`, `can-view-financial-data`, `can-manage-permissions`, `can-reply-to-reviews`, `can-manage-public-apks`, `can-manage-track-apks`, `can-manage-track-users`, `can-manage-public-listing`, `can-manage-draft-apps`, `can-manage-orders`, `can-manage-app-content`, `can-view-non-financial-data`, `can-view-app-quality`, `can-manage-deeplinks`.

Some of these values are returned by the live API but missing from Google's API spec; they are accepted as well.

| Command | Options | Notes |
|:---|:---|:---|
| `list-users` | `-e, --email`, `-l, --limit` | Users who accepted (state `ACCESS_GRANTED` / `ACCESS_EXPIRED`), with account permissions, expiration, and per-app grants. |
| `list-invitations` | `-e, --email`, `-l, --limit` | Users in `INVITED` / `INVITATION_EXPIRED` state. |
| `invite-user` | `-e, --email` (required), `--permissions`, `--package-name` + `--app-permissions`, `--expiration <iso8601>` | At least one of `--permissions` or `--app-permissions` is required; `--package-name` and `--app-permissions` go together. The app grant is created right after the invitation. |
| `update-user` | `-e, --email` (required), `--permissions`, `--expiration <iso8601>` | Replaces the account-wide permissions and/or sets a new (future) expiration. Per-app permissions use `grant-access` / `revoke-access`. |
| `delete-user` | `-e, --email` (required) | Removes the user. Destructive (CI-guarded). |
| `cancel-invitation` | `-e, --email` (required) | Only for users who have not accepted yet; otherwise use `delete-user`. Destructive (CI-guarded). |
| `grant-access` | `-e, --email` (required), `--package-name` (`GOOGLE_PACKAGE_NAME` / project), `--permissions` (required) | Creates the app grant, or replaces its permissions if the user already has one. The user must exist (invite first). |
| `revoke-access` | `-e, --email` (required), `--package-name` | Removes the user's grant for that app. Destructive (CI-guarded). |

```bash
appitool google list-users
appitool google invite-user -e dev@example.com --package-name com.example.app --app-permissions can-access-app,can-manage-track-apks
appitool google grant-access -e dev@example.com --permissions can-access-app,can-reply-to-reviews
appitool google update-user -e dev@example.com --expiration 2027-01-01T00:00:00Z
appitool google cancel-invitation -e dev@example.com
```
