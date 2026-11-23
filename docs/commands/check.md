# `appitool check`

Verifies store credentials, API connectivity, application registration, and retrieves the latest remote build version and build number.

## Synopsis

```bash
appitool check ios [options]
appitool check android [options]
```

---

## `appitool check ios`

Checks iOS application metadata and latest build information from Firebase App Distribution (`adhoc`, default) or App Store Connect (`appstore`).

### Behavior by Distribution

- **`adhoc` (default)**: Requires `FIREBASE_IOS_APP_ID` (or `--firebase-app-id`) and `GOOGLE_KEY` (or `-g, --google-key`). Fetches Firebase iOS App info (`appId`, `bundleId`, `displayName`, `projectId`, `appStoreId`, `teamId`, `state`) and the latest Firebase release version/build number.
- **`appstore`**: Requires App Store Connect credentials (`APPLE_KEY`, `APPLE_KEY_ID`, `APPLE_ISSUER_ID`) and a bundle identifier (flag or auto-detected from Xcode project). Retrieves the latest TestFlight/App Store build version and build number.
- **`development`**: Prints a notice that development distribution has no remote store information.

### Options

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-d, --distribution <method>` | `adhoc` | Distribution method: `adhoc`, `development`, or `appstore`. |
| `-b, --bundle-id <id>` | `APPLE_BUNDLE_ID` or auto-detected from Xcode project | Target iOS bundle identifier. |
| `--firebase-app-id <id>` | `FIREBASE_IOS_APP_ID` | Firebase App ID for iOS (used when `-d adhoc`). |

Plus [`AppleCredentialsOptions`](/commands/overview#applecredentialsoptions) (`--apple-key-id`, `--apple-issuer-id`, `--apple-key`) and [`GoogleCredentialsOptions`](/commands/overview#googlecredentialsoptions) (`-g, --google-key`).

### Examples

```bash
# Check latest Firebase App Distribution iOS app info & build
appitool check ios -d adhoc

# Check latest App Store Connect / TestFlight build for bundle ID
appitool check ios -d appstore -b com.example.app
```

---

## `appitool check android`

Checks Android application metadata and latest build information from Firebase App Distribution (`adhoc`, default) or Google Play Console (`appstore`).

### Behavior by Distribution

- **`adhoc` (default)**: Requires `FIREBASE_ANDROID_APP_ID` (or `--firebase-app-id`) and `GOOGLE_KEY` (or `-g, --google-key`). Displays Firebase Android App info (`appId`, `packageName`, `displayName`, `projectId`, `state`) and latest build info.
- **`appstore`**: Requires `GOOGLE_KEY` (or `-g, --google-key`) and a package name (flag or auto-detected from Android project). Queries Google Play Console for the latest version and build number (`versionCode`).
- **`development`**: Prints a notice that development distribution has no remote store information.

### Options

| Option / Flag | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-d, --distribution <method>` | `adhoc` | Distribution method: `adhoc`, `development`, or `appstore`. |
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` or auto-detected from Android project | Target Android package name. |
| `--firebase-app-id <id>` | `FIREBASE_ANDROID_APP_ID` | Firebase App ID for Android (used when `-d adhoc`). |

Plus [`GoogleCredentialsOptions`](/commands/overview#googlecredentialsoptions) (`-g, --google-key`).

### Examples

```bash
# Check Firebase App Distribution Android app info & latest release
appitool check android -d adhoc

# Check latest build versionCode on Google Play Console
appitool check android -d appstore --package-name com.example.app
```
