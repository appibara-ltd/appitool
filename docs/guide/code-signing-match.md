# Code Signing & Match

`appitool match` implements Git-backed encrypted storage for Apple signing assets and Android keystores, providing binary and encryption parity with **Fastlane Match**.

## How Match Works

1. **Clone Git Storage (`GitStorage`)**: Clones the target Git repository branch (shallow clone when in `readonly` / `sync` mode) into a temporary directory under `~/.appitool/match/<UUID>` and cleans it up in `defer`. If the requested branch does not yet exist on the remote, `appitool` creates an isolated orphan branch (matching Fastlane Match behavior).
2. **Decrypt Assets (`MatchEncryption`)**: Decrypts certificates, provisioning profiles, and Android keystores in-place using `MATCH_PASSWORD`.
3. **Sync / Prune / Nuke / Add**:
   - **iOS**: Validates certificates and profiles against Apple Developer Portal (when App Store Connect API credentials are supplied), creates missing/expired assets when writable, imports `.p12` certificates into a dedicated macOS Keychain, and installs `.mobileprovision` / `.provisionprofile` files for Xcode.
   - **Android**: Resolves `<packageName>.keystore` (or `.jks` / `.p12`) and `<packageName>.json` credential metadata, or encrypts and pushes a new keystore when adding.
4. **Re-encrypt & Push**: Encrypts modified assets using Match V2 (`AES-256-GCM`) and commits/pushes changes back to the remote Git repository.

---

## Encryption Compatibility (V1 & V2)

`MatchEncryption` supports both Fastlane Match encryption formats:

| Format | Header Prefix | Algorithm | Key Derivation | Behavior |
|:---|:---|:---|:---|:---|
| **V2 (Default for writes)** | `match_encrypted_v2__` | `AES-256-GCM` (Base64-encoded, 64-char lines) | PBKDF2-HMAC-SHA256 (10,000 iterations, 8-byte random salt, 24-byte AAD) | Used for all newly encrypted files |
| **V1 (Legacy read support)** | `Salted__` | `AES-256-CBC` (Base64-encoded) | OpenSSL `EVP_BytesToKey` (MD5, SHA-256) or PBKDF2-HMAC-SHA256 fallback | Supported seamlessly during decryption |

---

## Git Repository Structure

```text
<match-git-repo>/
├── certs/
│   ├── development/
│   │   ├── <CERT_ID>.cer
│   │   └── <CERT_ID>.p12
│   ├── distribution/          # Used by both 'appstore' and 'adhoc'
│   │   ├── <CERT_ID>.cer
│   │   └── <CERT_ID>.p12
│   ├── enterprise/
│   └── developer_id/
├── profiles/
│   ├── development/
│   │   └── Development_<bundleId>[_tvos|_catalyst].mobileprovision
│   ├── adhoc/
│   │   └── AdHoc_<bundleId>[_tvos|_catalyst].mobileprovision
│   ├── appstore/
│   │   └── AppStore_<bundleId>[_tvos|_catalyst].mobileprovision
│   ├── enterprise/
│   │   └── InHouse_<bundleId>.mobileprovision
│   └── developer_id/
│       └── DeveloperID_<bundleId>.provisionprofile
└── android/
    ├── release/
    │   ├── <packageName>.keystore
    │   └── <packageName>.json
    └── debug/
        ├── <packageName>.keystore
        └── <packageName>.json
```

### Wildcard Profile Matching (iOS)

When searching for a profile matching `<bundleId>`, `MatchRunner` looks for:
1. Exact match (`<Prefix>_<bundleId><suffix>.<ext>`)
2. Partial wildcard matches (`com.example.*`, selecting the longest/most specific prefix)
3. Global wildcard match (`*`)

---

## macOS Keychain & Xcode Installation

- **Keychain Isolation (`KeychainManager`)**:
  - Defaults to `appitool` (`~/Library/Keychains/appitool.keychain-db`) with password `appipass`, customizable via `MATCH_KEYCHAIN_NAME` and `MATCH_KEYCHAIN_PASSWORD` (or `--keychain-name` / `--keychain-password`).
  - Automatically creates the keychain if missing, unlocks it, clears auto-lock timeouts (`set-keychain-settings`), and adds it to the user's keychain search list.
- **Provisioning Profile Path (`ProfileInstaller`)**:
  - Installs profiles into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision` (or `.provisionprofile` for macOS/Catalyst).
- **Fastlane-Compatible Metadata**:
  - Generates `MatchResult.envVariables` entries (`sigh_<bundleId>_<type>`, `_uuid`, `_profile-path`, `_profile-name`, `_team-id`).

---

## Read-Only Mode Semantics

Notice the difference between standalone `appitool match ios` and `appitool flow`:

- **`appitool match ios`**: `--readonly` defaults to `false` (can create certificates/profiles on Apple Developer Portal if credentials are provided). Pass `-r, --readonly` for CI read-only sync.
- **`appitool flow ios` / `flow android`**: `MatchOptions` defaults `readonly` to `true` unless `MATCH_READONLY=false` is explicitly set in the environment (and `--dry-run` always forces `readonly: true`).
