# `appitool apple`

Direct management of Apple App Store Connect and Apple Developer Portal resources via the App Store Connect OpenAPI client.

All `apple` subcommands accept [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`), falling back to `APPLE_KEY_ID`, `APPLE_ISSUER_ID`, and `APPLE_KEY` in `.env` / environment variables.

> [!NOTE]
> **CI Guard:** Destructive subcommands (`delete-identifier`, `delete-profile`, `prune-profiles`, `delete-certificate`, `prune-certificates`, `disable-device`, `delete-user`, and `cancel-invitation`) accept [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and are skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

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
| `-i, --identifier <id>` | Filter by bundle identifier. |
| `-l, --limit <count>` | Maximum number of items to return. |

```bash
appitool apple list-identifiers
```

### `appitool apple create-identifier`

Registers a new App/Bundle Identifier with optional capabilities on Apple Developer Portal.

| Option | Default | Description |
|:---|:---|:---|
| `-b, --bundle-id <id>` | — | App/Bundle identifier (e.g. `com.example.app`). |
| `-a, --app-identifier <id>` | — | Alternative flag for bundle identifier. |
| `-n, --name <name>` | Bundle ID | Description or name of the App Identifier. |
| `--platform <platform>` | `universal` | Platform: `universal`, `ios`, or `macos`. |
| `-c, --capabilities <list>` | — | Comma-separated capability keys (e.g. `push-notifications,in-app-purchase`). |

```bash
appitool apple create-identifier \
  -b com.example.app \
  -n "Example App" \
  -c "push-notifications,sign-in-with-apple,associated-domains"
```

### `appitool apple delete-identifier`

Deletes an App/Bundle Identifier from Apple Developer Portal. Any provisioning profiles tied to the identifier are invalidated by Apple. Bundle IDs actively linked to an App Store Connect App record cannot be deleted.

| Option | Description |
|:---|:---|
| `-a, --app-identifier <id>` | App/Bundle identifier to delete (required). |

```bash
appitool apple delete-identifier -a com.example.app
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
| `--platform <platform>` | `ios` | Target platform: `ios`, `macos`, `tvos`, `catalyst`. |
| `-c, --certificate-id <id>` | First active matching cert | Certificate Portal ID to embed in the profile. |
| `-d, --device-ids <ids>` | All enabled matching devices | Comma-separated device Portal IDs for `development`/`adhoc` profiles. |
| `-o, --output <path>` | — | File path to save the generated `.mobileprovision` / `.provisionprofile`. |

```bash
appitool apple create-profile -b com.example.app -t adhoc -o ./AdHoc_com.example.app.mobileprovision
```

### `appitool apple delete-profile`

Deletes a single provisioning profile by name, UUID, or Portal ID.

| Option | Description |
|:---|:---|
| `-n, --name <name>` | Provisioning profile name. |
| `-u, --uuid <uuid>` | Provisioning profile UUID. |
| `-p, --portal-id <id>` | Provisioning profile Portal ID. |

### `appitool apple prune-profiles`

Deletes all `INVALID` (and optionally expired) provisioning profiles from Apple Developer Portal.

| Flag | Default | Description |
|:---|:---|:---|
| `-d, --dry-run` | `false` | Preview candidate profiles without deleting them. |
| `-i, --include-expired` | `false` | Also prune expired profiles in addition to `INVALID` profiles. |

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
| `-p, --portal-id <id>` | Certificate Portal ID. |
| `-n, --name <name>` | Certificate name. |
| `-s, --serial-number <serial>` | Certificate serial number. |

### `appitool apple prune-certificates`

Deletes/revokes all expired certificates from Apple Developer Portal.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-d, --dry-run` | `false` | Preview expired certificates without revoking them. |
| `-t, --type <type>` | — | Filter pruning by certificate type (e.g. `distribution`, `development`). |

---

## Devices

### `appitool apple list-devices`

Lists registered devices on Apple Developer Portal.

| Option | Description |
|:---|:---|
| `-p, --platform <platform>` | Filter by platform (`ios`, `macos`, `universal`). |
| `-s, --status <status>` | Filter by status (`enabled`, `disabled`). |
| `-n, --name <query>` | Case-insensitive substring filter on device name. |
| `-l, --limit <count>` | Maximum number of items to return. |

### `appitool apple add-device`

Registers a new test device on Apple Developer Portal.

| Option | Default | Description |
|:---|:---|:---|
| `-n, --name <name>` | **Required** | Device display name (e.g. `"QA iPhone 16"`). |
| `-u, --udid <udid>` | **Required** | Device Unique Device Identifier (UDID). |
| `-p, --platform <platform>` | `ios` | Platform: `ios`, `macos`, `universal`. |

```bash
appitool apple add-device -n "QA iPhone" -u 00008130-001234567890001E
```

### `appitool apple disable-device`

Disables a registered device by UDID on Apple Developer Portal so it is excluded from new provisioning profiles.

| Option | Description |
|:---|:---|
| `-u, --udid <udid>` | Device UDID to disable (**Required**). |

```bash
appitool apple disable-device -u 00008130-001234567890001E
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
| `-u, --username <email>` | Filter by username (Apple ID email). |
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
| `-f, --first-name <name>` | **Required** | Invitee first name. |
| `-l, --last-name <name>` | **Required** | Invitee last name. |
| `-r, --roles <roles>` | **Required** | Comma-separated roles to assign (e.g. `developer,app-manager`). |
| `-a, --visible-apps <apps>` | — | Comma-separated App Store Connect App IDs or bundle IDs to grant access. |
| `--all-apps-visible` / `--no-all-apps-visible` | `true` (or `false` if `--visible-apps` is set) | Grant visibility to all apps. |
| `--provisioning-allowed` / `--no-provisioning-allowed` | Role default | Allow access to certificates, identifiers, and profiles. |

```bash
appitool apple invite-user \
  -e dev@example.com \
  -f Jane \
  -l Doe \
  -r developer \
  -a com.example.app \
  --provisioning-allowed
```

### `appitool apple update-user`

Updates an active team user's roles, app visibility, or provisioning access (identify user with `-i, --id` or `-u, --username`).

| Option / Flag | Description |
|:---|:---|
| `-i, --id <id>` | User resource ID in App Store Connect. |
| `-u, --username <email>` | User username (Apple ID email). |
| `-r, --roles <roles>` | Comma-separated roles to assign. |
| `-a, --visible-apps <apps>` | Comma-separated App Store Connect App IDs or bundle IDs for visible apps. |
| `--all-apps-visible` / `--no-all-apps-visible` | Grant or restrict visibility to all apps. |
| `--provisioning-allowed` / `--no-provisioning-allowed` | Allow or disallow access to certificates, identifiers, and profiles. |

```bash
appitool apple update-user -u dev@example.com -r app-manager --all-apps-visible
```

### `appitool apple delete-user`

Removes an active team user from App Store Connect (identify user with `-i, --id` or `-u, --username`).

| Option | Description |
|:---|:---|
| `-i, --id <id>` | User resource ID to remove. |
| `-u, --username <email>` | User username (Apple ID email) to remove. |

```bash
appitool apple delete-user -u dev@example.com
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

Cancels a pending user invitation in App Store Connect (identify invitation with `-i, --id` or `-e, --email`).

| Option | Description |
|:---|:---|
| `-i, --id <id>` | Invitation resource ID to cancel. |
| `-e, --email <email>` | Invitee email address whose pending invitation should be canceled. |

```bash
appitool apple cancel-invitation -e dev@example.com
```
