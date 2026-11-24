# `appitool apple`

Direct management of Apple App Store Connect and Apple Developer Portal resources via the App Store Connect OpenAPI client.

All `apple` subcommands accept [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`), falling back to `APPLE_KEY_ID`, `APPLE_ISSUER_ID`, and `APPLE_KEY` in `.env` / environment variables.

> [!NOTE]
> **CI Guard:** Destructive subcommands (`delete-identifier`, `delete-profile`, `prune-profiles`, `delete-certificate`, `prune-certificates`, `disable-device`, `delete-user`, `cancel-invitation`, and `assets delete`) accept [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and are skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

## Synopsis

```bash
appitool apple <subcommand> [options]
```

## Subcommands Summary

| Category | Subcommands |
|:---|:---|
| **Apps** | `list-apps` |
| **App / Bundle Identifiers** | `list-identifiers`, `create-identifier`, `delete-identifier`, `list-capabilities` |
| **Provisioning Profiles** | `list-profiles`, `create-profile`, `delete-profile`, `prune-profiles` |
| **Certificates** | `list-certificates`, `create-certificate`, `delete-certificate`, `prune-certificates` |
| **Devices** | `list-devices`, `add-device`, `disable-device` |
| **Users & Invitations** | `list-users`, `invite-user`, `update-user`, `delete-user`, `list-invitations`, `cancel-invitation` |
| **Assets** (screenshots, product page header, search results) | `assets list`, `assets upload`, `assets download`, `assets delete`, `assets types`, `assets specs` |

---

## Apps

### `appitool apple list-apps`

Lists applications registered in App Store Connect (name, bundle ID, App ID, SKU, primary locale).

| Option | Description |
|:---|:---|
| `-b, --bundle-id <id>` | Filter by bundle identifier (e.g. `com.example.app`). |
| `-n, --name <name>` | Filter by application name. |
| `-l, --limit <count>` | Maximum number of items to return (omit to fetch all). |

```bash
appitool apple list-apps
appitool apple list-apps -b com.example.app
```

---

## Bundle Identifiers & Capabilities

### `appitool apple list-identifiers`

Lists App/Bundle Identifiers registered on Apple Developer Portal.

| Option | Description |
|:---|:---|
| `-b, --bundle-id <id>` | Filter by bundle identifier. |
| `-l, --limit <count>` | Maximum number of items to return. |

```bash
appitool apple list-identifiers
```

### `appitool apple create-identifier`

Registers a new App/Bundle Identifier with optional capabilities on Apple Developer Portal.

| Option | Default | Description |
|:---|:---|:---|
| `-b, --bundle-id <id>` | — | App/Bundle identifier (e.g. `com.example.app`). |
| `-n, --name <name>` | Bundle ID | Description or name of the App Identifier. |
| `-p, --platform <platform>` | `universal` | Platform: `universal`, `ios`, or `macos`. |
| `--capabilities <list>` | — | Comma-separated capability keys (e.g. `push-notifications,in-app-purchase`). |

```bash
appitool apple create-identifier \
  -b com.example.app \
  -n "Example App" \
  --capabilities "push-notifications,sign-in-with-apple,associated-domains"
```

### `appitool apple delete-identifier`

Deletes an App/Bundle Identifier from Apple Developer Portal. Any provisioning profiles tied to the identifier are invalidated by Apple. Bundle IDs actively linked to an App Store Connect App record cannot be deleted.

| Option | Description |
|:---|:---|
| `-b, --bundle-id <id>` | App/Bundle identifier to delete (required). |

```bash
appitool apple delete-identifier -b com.example.app
```

### `appitool apple list-capabilities`

- When called **without `-b`**: Lists all 28 supported capability keys and their App Store Connect enum names (no credentials required).
- When called **with `-b, --bundle-id <id>`**: Queries Apple Developer Portal and lists capabilities enabled for that Bundle ID.

```bash
# List all supported capability keys
appitool apple list-capabilities

# Inspect capabilities enabled for an existing App ID
appitool apple list-capabilities -b com.example.app
```

#### Supported Capability Keys

| Category | CLI Key (Aliases) | API Enum | Description |
|:---|:---|:---|:---|
| **Push & Communication** | `push-notifications` (`push`) | `PUSH_NOTIFICATIONS` | APNs remote push notifications |
| | `inter-app-audio` | `INTER_APP_AUDIO` | Real-time audio streaming with host apps |
| | `coremedia-hls-low-latency` | `COREMEDIA_HLS_LOW_LATENCY` | Low-Latency HTTP Live Streaming (HLS) |
| **Authentication & Security** | `sign-in-with-apple` (`apple-sign-in`, `apple-id-auth`) | `APPLE_ID_AUTH` | Sign in with Apple authentication |
| | `data-protection` | `DATA_PROTECTION` | Hardware-based file-level encryption |
| | `autofill-credential-provider` | `AUTOFILL_CREDENTIAL_PROVIDER` | AutoFill password manager extensions |
| **App Integration & Domains** | `associated-domains` | `ASSOCIATED_DOMAINS` | Universal Links, App Clips, Web Credentials |
| | `app-groups` | `APP_GROUPS` | Shared container access for App Extensions & Widgets |
| | `icloud` | `ICLOUD` | CloudKit database and iCloud document storage |
| | `game-center` | `GAME_CENTER` | Game Center leaderboards, achievements & multiplayer |
| | `in-app-purchase` (`iap`) | `IN_APP_PURCHASE` | In-App Purchases & StoreKit |
| **Payments & Wallet** | `apple-pay` | `APPLE_PAY` | Apple Pay in-app payment processing |
| | `wallet` (`passbook`) | `WALLET` | Passes, tickets, and boarding passes in Apple Wallet |
| **Hardware & Networking** | `nfc-tag-reading` (`nfc`) | `NFC_TAG_READING` | Near Field Communication (NFC) tag reading |
| | `access-wifi-information` (`wifi-info`) | `ACCESS_WIFI_INFORMATION` | Access current Wi-Fi network SSID/BSSID |
| | `hot-spot` | `HOT_SPOT` | Wi-Fi HotSpot network configuration |
| | `personal-vpn` | `PERSONAL_VPN` | Personal VPN tunnels and connections |
| | `network-extensions` | `NETWORK_EXTENSIONS` | Custom network tunnels, DNS proxies, content filters |
| | `network-custom-protocol` | `NETWORK_CUSTOM_PROTOCOL` | Custom network protocol extensions |
| | `multipath` | `MULTIPATH` | Multipath TCP for concurrent Wi-Fi and Cellular data |
| | `wireless-accessory-configuration` | `WIRELESS_ACCESSORY_CONFIGURATION` | MFi accessory Wi-Fi configuration |
| **Health & Home** | `healthkit` | `HEALTHKIT` | HealthKit health and fitness records |
| | `homekit` | `HOMEKIT` | HomeKit smart home automation & accessories |
| **Siri & Maps & System** | `sirikit` | `SIRIKIT` | SiriKit voice shortcuts and intents |
| | `maps` | `MAPS` | MapKit turn-by-turn routing and directions |
| | `classkit` | `CLASSKIT` | ClassKit student progress & educational activities |
| | `system-extension-install` | `SYSTEM_EXTENSION_INSTALL` | macOS system extensions & driver extensions |
| | `user-management` | `USER_MANAGEMENT` | Multi-user management on Shared iPad |

---

## Provisioning Profiles

### `appitool apple list-profiles`

Lists provisioning profiles on Apple Developer Portal (name, Portal ID, UUID, type, state, expiration date).

| Option | Description |
|:---|:---|
| `-n, --name <name>` | Filter by provisioning profile name. |
| `-l, --limit <count>` | Maximum number of items to return. |

### `appitool apple create-profile`

Creates and optionally downloads a provisioning profile on Apple Developer Portal.

| Option | Default | Description |
|:---|:---|:---|
| `-b, --bundle-id <id>` | **Required** | Application Bundle Identifier. |
| `-n, --name <name>` | `match <type> <bundle-id>` | Provisioning profile name. |
| `-t, --type <type>` | `appstore` | Profile type: `appstore`, `development`, `adhoc`, `enterprise`, `developer_id`. |
| `-p, --platform <platform>` | `ios` | Target platform: `ios`, `macos`, `tvos`, `catalyst`. |
| `--certificate-id <id>` | First active matching cert | Certificate Portal ID to embed in the profile. |
| `--device-ids <ids>` | All enabled matching devices | Comma-separated device Portal IDs for `development`/`adhoc` profiles. |
| `-o, --output <path>` | — | File path to save the generated `.mobileprovision` / `.provisionprofile`. |

```bash
appitool apple create-profile -b com.example.app -t adhoc -o ./AdHoc_com.example.app.mobileprovision
```

### `appitool apple delete-profile`

Deletes a single provisioning profile by name, UUID, or Portal ID.

| Option | Description |
|:---|:---|
| `-n, --name <name>` | Provisioning profile name. |
| `--uuid <uuid>` | Provisioning profile UUID. |
| `--portal-id <id>` | Provisioning profile Portal ID. |

### `appitool apple prune-profiles`

Deletes all `INVALID` (and optionally expired) provisioning profiles from Apple Developer Portal.

| Flag | Default | Description |
|:---|:---|:---|
| `--dry-run` | `false` | Preview candidate profiles without deleting them. |
| `--include-expired` | `false` | Also prune expired profiles in addition to `INVALID` profiles. |

```bash
appitool apple prune-profiles --include-expired --dry-run
```

---

## Signing Certificates

### `appitool apple list-certificates`

Lists certificates registered on Apple Developer Portal with status (`ACTIVE` / `EXPIRED`), type, serial number, and expiration date.

| Option | Description |
|:---|:---|
| `-t, --type <filter>` | Filter by certificate type (`distribution`, `development`, `developer-id`, `ios-distribution`, `ios-development`, `mac-distribution`, `mac-development`). |
| `-l, --limit <count>` | Maximum number of items to return. |

### `appitool apple create-certificate`

Generates an RSA 2048-bit private key and CSR locally, submits it to Apple Developer Portal, and saves the `.cer` and private `.key` (plus optional `.p12` and Keychain import).

> [!WARNING]
> Keep the generated private key safe—Apple does not store private keys and they cannot be re-downloaded.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-t, --type <type>` | `distribution` | Certificate type: `development`, `distribution`, `developer-id`, `ios-development`, `ios-distribution`, `mac-development`, `mac-distribution`, `mac-installer`. |
| `-n, --name <cn>` | Auto-generated | Common Name (CN) for the CSR subject. |
| `-o, --output <dir>` | `~/.appitool/certs/{type}/` | Output directory for `.cer`, `.key`, and `.p12`. |
| `--p12` | `false` | Export a `.p12` (PKCS#12) archive containing certificate and private key. |
| `--p12-password <pass>` | `appitool` | Password for the exported `.p12` archive. |
| `--save-to-keychain` | `false` | Import certificate and private key into the `appitool` Keychain and delete `.p12` once verified. |

```bash
appitool apple create-certificate -t distribution --p12 --save-to-keychain
```

### `appitool apple delete-certificate`

Revokes/deletes a certificate from Apple Developer Portal by Portal ID, name, or serial number.

| Option | Description |
|:---|:---|
| `--portal-id <id>` | Certificate Portal ID. |
| `-n, --name <name>` | Certificate name. |
| `--serial-number <serial>` | Certificate serial number. |

### `appitool apple prune-certificates`

Deletes/revokes all expired certificates from Apple Developer Portal.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--dry-run` | `false` | Preview expired certificates without revoking them. |
| `-t, --type <type>` | — | Filter pruning by certificate type (e.g. `distribution`, `development`). |

---

## Devices

### `appitool apple list-devices`

Lists registered devices on Apple Developer Portal.

| Option | Description |
|:---|:---|
| `-p, --platform <platform>` | Filter by platform (`ios`, `macos`, `universal`). |
| `--status <status>` | Filter by status (`enabled`, `disabled`). |
| `-n, --name <query>` | Case-insensitive substring filter on device name. |
| `-l, --limit <count>` | Maximum number of items to return. |

### `appitool apple add-device`

Registers a new test device on Apple Developer Portal.

| Option | Default | Description |
|:---|:---|:---|
| `-n, --name <name>` | **Required** | Device display name (e.g. `"QA iPhone 16"`). |
| `--udid <udid>` | **Required** | Device Unique Device Identifier (UDID). |
| `-p, --platform <platform>` | `ios` | Platform: `ios`, `macos`, `universal`. |

```bash
appitool apple add-device -n "QA iPhone" --udid 00008130-001234567890001E
```

### `appitool apple disable-device`

Disables a registered device by UDID on Apple Developer Portal so it is excluded from new provisioning profiles.

| Option | Description |
|:---|:---|
| `--udid <udid>` | Device UDID to disable (**Required**). |

```bash
appitool apple disable-device --udid 00008130-001234567890001E
```

---

## Users & Invitations

> [!NOTE]
> Managing App Store Connect team users and invitations requires an API key with the **Admin** role. The `ACCOUNT_HOLDER` role cannot be assigned or modified via the API.
>
> **Supported Role Keys (comma-separated):** `admin`, `app-manager`, `developer`, `finance`, `sales`, `marketing`, `customer-support` (alias: `support`), `access-to-reports` (alias: `reports`), `create-apps`, `cloud-managed-developer-id`, `cloud-managed-app-distribution`, `generate-individual-keys`.

### `appitool apple list-users`

Lists active team users in App Store Connect.

| Option | Description |
|:---|:---|
| `--username <email>` | Filter by username (Apple ID email). |
| `-r, --roles <roles>` | Filter by comma-separated roles (e.g. `admin,developer`). |
| `-l, --limit <count>` | Maximum number of items to return (omit to fetch all). |

```bash
appitool apple list-users
appitool apple list-users -r admin,developer
```

### `appitool apple invite-user`

Sends an email invitation to add a new user to your App Store Connect team.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-e, --email <email>` | **Required** | Invitee email address. |
| `--first-name <name>` | **Required** | Invitee first name. |
| `--last-name <name>` | **Required** | Invitee last name. |
| `-r, --roles <roles>` | **Required** | Comma-separated roles to assign (e.g. `developer,app-manager`). |
| `--visible-apps <apps>` | — | Comma-separated App Store Connect App IDs or bundle IDs to grant access. |
| `--all-apps-visible` / `--no-all-apps-visible` | `true` (or `false` if `--visible-apps` is set) | Grant visibility to all apps. |
| `--provisioning-allowed` / `--no-provisioning-allowed` | Role default | Allow access to certificates, identifiers, and profiles. |

```bash
appitool apple invite-user \
  -e dev@example.com \
  --first-name Jane \
  --last-name Doe \
  -r developer \
  --visible-apps com.example.app \
  --provisioning-allowed
```

### `appitool apple update-user`

Updates an active team user's roles, app visibility, or provisioning access (identify user with `--id` or `--username`).

| Option / Flag | Description |
|:---|:---|
| `--id <id>` | User resource ID in App Store Connect. |
| `--username <email>` | User username (Apple ID email). |
| `-r, --roles <roles>` | Comma-separated roles to assign. |
| `--visible-apps <apps>` | Comma-separated App Store Connect App IDs or bundle IDs for visible apps. |
| `--all-apps-visible` / `--no-all-apps-visible` | Grant or restrict visibility to all apps. |
| `--provisioning-allowed` / `--no-provisioning-allowed` | Allow or disallow access to certificates, identifiers, and profiles. |

```bash
appitool apple update-user --username dev@example.com -r app-manager --all-apps-visible
```

### `appitool apple delete-user`

Removes an active team user from App Store Connect (identify user with `--id` or `--username`).

| Option | Description |
|:---|:---|
| `--id <id>` | User resource ID to remove. |
| `--username <email>` | User username (Apple ID email) to remove. |

```bash
appitool apple delete-user --username dev@example.com
```

### `appitool apple list-invitations`

Lists pending team user invitations in App Store Connect.

| Option | Description |
|:---|:---|
| `-e, --email <email>` | Filter by invitee email address. |
| `-r, --roles <roles>` | Filter by comma-separated roles. |
| `-l, --limit <count>` | Maximum number of items to return (omit to fetch all). |

```bash
appitool apple list-invitations
```

### `appitool apple cancel-invitation`

Cancels a pending user invitation in App Store Connect (identify invitation with `--id` or `-e, --email`).

| Option | Description |
|:---|:---|
| `--id <id>` | Invitation resource ID to cancel. |
| `-e, --email <email>` | Invitee email address whose pending invitation should be canceled. |

```bash
appitool apple cancel-invitation -e dev@example.com
```

---

## Assets (`appitool apple assets`)

Manages the App Store product page images of a version, per localization:

| Kind | `-t, --type` values | API |
|:---|:---|:---|
| Screenshots | screenshot device slots (`iphone-67`, `ipad-pro-129`, `iphone-duo`, … — see `assets types`) | `APP_SCREENSHOT` / `IMESSAGE_APP_SCREENSHOT` placements with the slot's placement group (e.g. `IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`) |
| Product page header (iOS 27+) | `header` | `PRODUCT_PAGE_HEADER_ASSET` placement |
| Search results (iOS 27+) | `search` | `APP_STORE_SEARCH_RESULTS_ASSET` placement |

All types use the App Store Connect **Asset Library** (API 4.6.1): an image is uploaded into the app's Asset Library (reserve → chunked upload → commit, then processing) and then *placed* on a version localization. Removing a placement keeps the image in the Asset Library. Screenshot slots hold up to 10 images in display order (reordered with placement ordering requests); `header` / `search` hold exactly one image, and placing a new one replaces the current one. Screenshots need an editable version; header/search can also be changed on a live version. Videos are not supported yet.

Everything lives in one local tree: `~/.appitool/assets/<project>/apple/<locale>/<type>/`, where `<type>` is a screenshot slot key (up to 10 images) or `header` / `search` (exactly one image). When [`STORE_ASSETS_PATH`](/guide/configuration#store-assets-apple-assets-google-assets) is set, the tree is `<STORE_ASSETS_PATH>/apple/<locale>/<type>/` instead (default paths below then refer to that folder).

All `assets` subcommands (except `types` and `specs`) accept shared app-resolution options:

| Option | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-b, --bundle-id <id>` | `APPLE_BUNDLE_ID` or auto-detected from Xcode project | Target application bundle identifier |
| `--app-id <id>` | — | Numeric App Store Connect App ID (takes precedence over `--bundle-id`) |
| `-p, --platform <platform>` | `ios` | Target platform (`ios`, `macos`, `tvos`, `visionos`) |
| `--app-version <ver>` | Auto-selects editable version (or latest for `list`) | Explicit App Store version string (e.g. `1.2.0`) |

### `appitool apple assets list`

Lists screenshots per device slot (in display order) and header / search results placements on the resolved App Store version, with placement IDs, dimensions, and states. Screenshots in device slots appitool does not know yet are reported with their placement group.

| Option | Description |
|:---|:---|
| `--locale <locale>` | Filter by App Store locale (e.g. `en-US`, `tr`). Omit to list all localizations. |
| `-t, --type <type>` | Filter by screenshot slot (e.g. `iphone-67`, `ipad-pro-129`, `iphone-duo`), `header`, or `search`. |
| `--asset-library` | Instead of the regular view, list every Asset Library placement on each localization (all placement types, including screenshot placements, with their placement group). |

```bash
appitool apple assets list -b com.example.app
appitool apple assets list -b com.example.app --app-version 1.2.0 --locale en-US -t iphone-67
```

### `appitool apple assets upload`

Uploads screenshots (to an editable App Store version, e.g. `PREPARE_FOR_SUBMISSION`; new screenshots are added at the end of their slot, and slots that would exceed 10 images are rejected before any change) and header / search results images either from explicit flat image paths (`--locale` and `-t` required) or symmetrically from a `<locale>/<type>/` directory tree defaulting to `~/.appitool/assets/<project>/apple/` (`--locale` and `-t` optional filters). Each `header` / `search` folder must contain exactly one image; it replaces that localization's current placement (a new placement is created first and the old one removed; if App Store Connect rejects a second placement, the old one is removed first). A file used for several localizations is uploaded to the Asset Library once.

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `--locale <locale>` | — | App Store localization locale (e.g. `en-US`, `tr`). Required for flat files; optional filter for `<locale>/<type>/` trees. |
| `-t, --type <type>` | — | Screenshot slot (e.g. `iphone-67`, `ipad-pro-129`, `APP_IPHONE_67`, `iphone-duo`), `header`, or `search`. Required for flat files; optional filter for directory trees. |
| `--replace` | `false` | Remove the existing screenshots of each target slot before uploading. For `<locale>/<type>/` trees, also writes each folder's sync manifest. Header/search slots are always replaced. |
| `--sync` | `false` | Mirror `<locale>/<type>/` folders using `.appitool-manifest.json` (see [Asset sync](#asset-sync)). Cannot be combined with `--replace`; requires a directory tree, not explicit files or a flat folder. |
| `--all-locales` | `false` | Place one explicit `header` or `search` file on every localization of the version (requires a file and `-t header` / `-t search`; cannot be combined with `--locale` or `--sync`). |
| `--wait-processing` / `--no-wait-processing` | `true` (`--wait-processing`) | Wait for App Store Connect to process each uploaded image. |
| `--dry-run` | `false` | Validate files and preview upload targets without contacting App Store Connect. With `--sync`, reads App Store Connect (no changes) and prints the sync plan. |
| `<paths...>` | `~/.appitool/assets/<project>/apple/` | Optional PNG/JPEG file(s), flat directory, or `<locale>/<type>/` directory tree. |

```bash
# Bulk-upload all locales and types from ~/.appitool/assets/<bundle-id>/apple/
appitool apple assets upload --replace

# Bulk-upload only en-US slots from the default per-project directory
appitool apple assets upload --locale en-US --replace

# Upload flat directory images for a single locale and display type
appitool apple assets upload \
  -b com.example.app \
  --locale en-US \
  -t iphone-67 \
  --replace \
  ./screenshots/ios/en-US/iphone-67/

# Preview, then apply, only the local changes since the last download/sync
appitool apple assets upload --sync --dry-run
appitool apple assets upload --sync

# Use one header image for every localization
appitool apple assets upload --all-locales -t header ./header.png

# Set the en-US search results image
appitool apple assets upload --locale en-US -t search ./search.png
```

#### Asset sync

`download`, `upload --replace` (directory trees), and `upload --sync` write a `.appitool-manifest.json` into each `<locale>/<type>/` folder. For screenshot folders it records the slot identity (`<version-id>/<locale>/<placement-group>`) and, for every file, the matching placement ID and the SHA-256 of the local file. For `header` / `search` folders it records the placed Asset Library image ID and the file's SHA-256.

`header` / `search` folders under `--sync`: unchanged file whose image is still placed → nothing is sent; changed file (or a different image placed) → upload and place; no manifest and nothing placed → upload and place; no manifest but an image is placed → error (run `download` first, or upload without `--sync` to replace it). Header/search slots are planned before any screenshot change.

Screenshot folders:

`upload --sync` plans every slot before changing anything; any planning error aborts the run without remote changes. Per slot:

| Local state | Action |
|:---|:---|
| File in manifest, checksum unchanged | Keep (no upload). |
| File in manifest, checksum changed | Replace: upload and place the new file, then remove the old placement (removes first when the slot already has 10 screenshots). |
| File renamed but content unchanged | Keep (matched by checksum). |
| File not in manifest | Add. |
| Manifest entry whose file was removed | Remove the placement from App Store Connect. |
| Screenshot on App Store Connect not in the manifest | Left untouched (warning) and placed after the managed screenshots. |

After uploads, the slot order is set to the local file-name order (`01_…`, `02_…`) with a placement ordering request, and the manifest is rewritten.

| Manifest | Remote slot | Result |
|:---|:---|:---|
| Missing | Empty | Bootstrap: upload all files in file-name order, write the manifest. |
| Missing | Has screenshots | Error: run `download` first or use `--replace`. |
| For a different slot or version | — | Error: run `download` again or delete the manifest and use `--replace`. |

Slots that would exceed App Store Connect's limit of 10 screenshots → error before any change. A `<locale>/<type>/` folder with no images is skipped, so emptying a folder does not clear its slot; use `apple assets delete` for that.

### `appitool apple assets download`

Downloads screenshots from App Store Connect (`imageAsset.templateUrl` at full resolution) into `<output>/<locale>/<type>/01_<name>.<ext>`, and placed header / search results images into `<output>/<locale>/<header|search>/<name>.<ext>`. By default, files are stored per project under `~/.appitool/assets/<bundle-or-app-id>/apple/`. Existing leading order prefixes (`01_...`) are stripped before applying the current store order prefix so round-tripping download → upload → download does not double-prefix filenames.

Downloaded files are the images served by Apple's CDN, which can be smaller than the originally uploaded files (same dimensions, different encoding). Each slot folder also gets a `.appitool-manifest.json` for [`upload --sync`](#asset-sync). Screenshots in device slots appitool does not know yet are skipped with a warning. Images written by a previous download whose screenshots no longer exist on App Store Connect are removed; other local images are kept and reported (`upload --sync` would add them).

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--locale <locale>` | — | Filter by App Store locale (e.g. `en-US`, `tr`). Omit to download all locales. |
| `-t, --type <type>` | — | Filter by screenshot slot (e.g. `iphone-67`, `ipad-pro-129`, `iphone-duo`), `header`, or `search`. |
| `-o, --output <dir>` | `~/.appitool/assets/<project>/apple/` | Custom destination root directory. |
| `--dry-run` | `false` | Preview target local paths and CDN URLs without downloading files. |

```bash
# Download all locales and display types for the project to ~/.appitool/assets/<bundle-id>/apple/
appitool apple assets download

# Download only en-US iPhone 6.7" screenshots into a custom folder
appitool apple assets download -b com.example.app --locale en-US -t iphone-67 -o ./downloads/ios
```

### `appitool apple assets delete`

Removes one placement by ID, or all assets for `--locale` (and optional `--type`). Removing a placement takes the image off the localization; the image stays in the Asset Library. Screenshots require an editable version; with `-t header` / `-t search` a live version can be used. Guarded in CI mode.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--id <placement-id>` | — | Placement ID to remove, as shown by `assets list` (mutually exclusive with `--all`). |
| `--locale <locale>` | — | App Store localization locale when deleting with `--all`. |
| `-t, --type <type>` | — | Optional filter when deleting with `--all`: a screenshot slot (e.g. `iphone-67`, `iphone-duo`), `header`, or `search`. Omit to remove all types (screenshots, header, and search). |
| `--all` | `false` | Remove all assets matching `--locale` (and optional `--type`). |
| `--dry-run` | `false` | Preview matching assets without removing them. |

```bash
appitool apple assets delete --id "<placement-id>"
appitool apple assets delete -b com.example.app --locale en-US -t iphone-67 --all --dry-run
```

### `appitool apple assets types`

Lists all supported screenshot slots (the 33 App Store Connect screenshot display types plus `iphone-duo` and `imessage-iphone-duo`) with their CLI aliases and Asset Library placement groups, plus `header` and `search` (no credentials required).

```bash
appitool apple assets types
```

### `appitool apple assets specs`

Shows Apple's current image specs live from `appAssetLibraryRefData` (needs only Apple credentials):

- **header / search:** size or size range, aspect ratio, formats, maximum file size, alpha, universal assets.
- **screenshot:** one entry per device slot with its `-t` key, display class (e.g. `IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY`), platform, screen dimensions, placement group, maximum count per version, and the accepted sizes and formats.

| Option | Description |
|:---|:---|
| `-t, --type <kind>` | `screenshot`, `header`, `search`, or one screenshot slot (e.g. `iphone-67`, `iphone-duo`). Omit to show all. |

```bash
appitool apple assets specs
appitool apple assets specs -t header
```
