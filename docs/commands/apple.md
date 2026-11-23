# `appitool apple`

Direct management of Apple App Store Connect and Apple Developer Portal resources via the App Store Connect OpenAPI client.

All `apple` subcommands accept [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`), falling back to `APPLE_KEY_ID`, `APPLE_ISSUER_ID`, and `APPLE_KEY` in `.env` / environment variables.

> [!NOTE]
> **CI Guard:** Destructive subcommands (`delete-identifier`, `delete-profile`, `prune-profiles`, `delete-certificate`, `prune-certificates`, `disable-device`, `delete-user`, `cancel-invitation`, and `screenshots delete`) accept [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and are skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

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
| **Screenshots** | `screenshots list`, `screenshots upload`, `screenshots download`, `screenshots delete`, `screenshots types` |

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

## Screenshots (`appitool apple screenshots`)

Manages App Store Connect screenshot sets and localized screenshot assets using the 3-step reserve → chunked upload → MD5 commit workflow.

All `screenshots` subcommands (except `types`) accept shared app-resolution options:

| Option | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-b, --bundle-id <id>` | `APPLE_BUNDLE_ID` or auto-detected from Xcode project | Target application bundle identifier |
| `--app-id <id>` | — | Numeric App Store Connect App ID (takes precedence over `--bundle-id`) |
| `-p, --platform <platform>` | `ios` | Target platform (`ios`, `macos`, `tvos`, `visionos`) |
| `--app-version <ver>` | Auto-selects editable version (or latest for `list`) | Explicit App Store version string (e.g. `1.2.0`) |

### `appitool apple screenshots list`

Lists screenshot sets and individual screenshots registered on the resolved App Store version.

| Option | Description |
|:---|:---|
| `--locale <locale>` | Filter by App Store locale (e.g. `en-US`, `tr`). Omit to list all localizations. |
| `-t, --type <display-type>` | Filter by screenshot display type (e.g. `iphone-67`, `ipad-pro-129`). |

```bash
appitool apple screenshots list -b com.example.app
appitool apple screenshots list -b com.example.app --app-version 1.2.0 --locale en-US -t iphone-67
```

### `appitool apple screenshots upload`

Uploads screenshots to an editable App Store version (e.g. `PREPARE_FOR_SUBMISSION`) either from explicit flat image paths (`--locale` and `-t` required) or symmetrically from a `<locale>/<type>/` directory tree defaulting to `~/.appitool/screenshots/<project>/apple/` (`--locale` and `-t` optional filters).

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `--locale <locale>` | — | App Store localization locale (e.g. `en-US`, `tr`). Required for flat files; optional filter for `<locale>/<type>/` trees. |
| `-t, --type <display-type>` | — | Screenshot display type (e.g. `iphone-67`, `ipad-pro-129`, `APP_IPHONE_67`). Required for flat files; optional filter for directory trees. |
| `--replace` | `false` | Delete existing screenshots in each target set before uploading. |
| `--wait-processing` / `--no-wait-processing` | `true` (`--wait-processing`) | Wait for App Store Connect to process each uploaded screenshot (`COMPLETE` / `FAILED`). |
| `--dry-run` | `false` | Validate files and preview upload targets without contacting App Store Connect. |
| `<paths...>` | `~/.appitool/screenshots/<project>/apple/` | Optional PNG/JPEG file(s), flat directory, or `<locale>/<type>/` directory tree. |

```bash
# Bulk-upload all locales and display types from ~/.appitool/screenshots/<bundle-id>/apple/
appitool apple screenshots upload --replace

# Bulk-upload only en-US sets from the default per-project directory
appitool apple screenshots upload --locale en-US --replace

# Upload flat directory images for a single locale and display type
appitool apple screenshots upload \
  -b com.example.app \
  --locale en-US \
  -t iphone-67 \
  --replace \
  ./screenshots/ios/en-US/iphone-67/
```

### `appitool apple screenshots download`

Downloads screenshots from App Store Connect (`imageAsset.templateUrl` at full resolution) into `<output>/<locale>/<type>/01_<name>.<ext>`. By default, files are stored per project under `~/.appitool/screenshots/<bundle-or-app-id>/apple/`. Existing leading order prefixes (`01_...`) are stripped before applying the current store order prefix so round-tripping download → upload → download does not double-prefix filenames.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--locale <locale>` | — | Filter by App Store locale (e.g. `en-US`, `tr`). Omit to download all locales. |
| `-t, --type <display-type>` | — | Filter by screenshot display type (e.g. `iphone-67`, `ipad-pro-129`). |
| `-o, --output <dir>` | `~/.appitool/screenshots/<project>/apple/` | Custom destination root directory. |
| `--dry-run` | `false` | Preview target local paths and CDN URLs without downloading files. |

```bash
# Download all locales and display types for the project to ~/.appitool/screenshots/<bundle-id>/apple/
appitool apple screenshots download

# Download only en-US iPhone 6.7" screenshots into a custom folder
appitool apple screenshots download -b com.example.app --locale en-US -t iphone-67 -o ./downloads/ios
```

### `appitool apple screenshots delete`

Deletes an individual screenshot by resource ID or all screenshots for `--locale` (and optional `--type`) on an editable App Store version (guarded in CI mode).

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--id <screenshot-id>` | — | Specific App Store screenshot resource ID to delete (mutually exclusive with `--all`). |
| `--locale <locale>` | — | App Store localization locale when deleting with `--all`. |
| `-t, --type <display-type>` | — | Optional screenshot display type filter when deleting with `--all`. |
| `--all` | `false` | Delete all screenshots matching `--locale` (and optional `--type`). |
| `--dry-run` | `false` | Preview matching screenshot(s) without deleting them. |

```bash
appitool apple screenshots delete --id "<screenshot-id>"
appitool apple screenshots delete -b com.example.app --locale en-US -t iphone-67 --all --dry-run
```

### `appitool apple screenshots types`

Lists all 33 supported App Store Connect screenshot display types and their CLI aliases (no credentials required).

```bash
appitool apple screenshots types
```
