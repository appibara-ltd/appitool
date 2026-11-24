# `appitool firebase`

Manages Firebase apps (iOS, Android, web), App Distribution releases and tester groups, Firebase Authentication user accounts, and Cloud Firestore collections and documents.

> [!NOTE]
> **CI Guard:** Destructive subcommands (`delete-app`, `delete-user`, and `firestore delete`) accept [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and are skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

## Synopsis

```bash
appitool firebase <subcommand> [options]
```

## Subcommands Summary

| Domain | Subcommand | Description |
|:---|:---|:---|
| **Apps** | `list-apps` | Lists the iOS, Android, and web apps registered in a Firebase project. |
| | `add-app` | Registers an iOS, Android, or web app (reports the existing app if already registered). |
| | `delete-app` | Removes an app (restorable for 30 days unless `--immediate`). |
| | `sync-fingerprints` | Adds the Play App Signing SHA-1/SHA-256 fingerprints to a Firebase Android app. |
| **App Distribution** | `list-releases` | Lists uploaded releases for a Firebase App ID. |
| | `create-release` | Uploads an `.apk`, `.aab`, or `.ipa` binary, attaches notes, and distributes to groups/testers. |
| | `update-release` | Updates release notes or distributes an existing release to tester groups/emails. |
| | `list-groups` | Lists tester groups registered in a Firebase project. |
| | `create-group` | Creates a new tester group or retrieves an existing one by alias. |
| **Authentication** | `list-users` | Lists Firebase Auth users with search, anonymous filter, and pagination. |
| | `delete-user` | Deletes user(s) by UID, email, or bulk-deletes all anonymous users. |
| | `export-users` | Exports Firebase Auth users to a CSV file. |
| **Cloud Firestore** | `firestore collections` | Lists root collection IDs or subcollections under a document path. |
| | `firestore list` | Lists documents in a Firestore collection. |
| | `firestore get` | Fetches a single Firestore document by path. |
| | `firestore set` | Creates or updates a Firestore document (supports `--merge` and auto-ID creation). |
| | `firestore delete` | Deletes a Firestore document by path (supports `--dry-run`). |
| | `firestore query` | Runs structured queries with `--where`, `--order-by`, `--limit`, and `--all-descendants`. |

---

## Firebase Apps Commands

Uses the Firebase Management API (`projects.searchApps`, `projects.{iosApps|androidApps|webApps}.create` / `.remove`, and `projects.androidApps.sha`). The service account needs a role that can manage Firebase apps in the project (e.g. Firebase Admin).

### `appitool firebase list-apps`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) (`-g, --google-key`, `--project`).

Lists every app of the project grouped by platform, with display name, bundle ID / package name, and Firebase App ID (all pages).

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-p, --platform <platform>` | all | Only list `ios`, `android`, or `web` apps. |
| `--show-deleted` | `false` | Also list apps deleted within the last 30 days. |

```bash
appitool firebase list-apps -p ios
```

### `appitool firebase add-app`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions).

Registers an app in the project and waits for Firebase to finish creating it, then prints its Firebase App ID and the `.env` variable to set (`FIREBASE_IOS_APP_ID` / `FIREBASE_ANDROID_APP_ID`). If an app with the same platform and bundle ID / package name is already registered, it is reported instead of created.

| Option | Default | Description |
|:---|:---|:---|
| `-p, --platform <platform>` | **Required** | `ios`, `android`, or `web`. |
| `-b, --bundle-id <id>` | `APPLE_BUNDLE_ID` / Xcode project | iOS bundle identifier (`-p ios` only). |
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` / Android project | Android package name (`-p android` only). |
| `-n, --name <display>` | — | Display name in Firebase (required for `-p web`). |
| `--app-store-id <id>` | — | Apple ID of the app in the App Store (`-p ios` only). |
| `--team-id <id>` | — | Apple Developer Team ID (`-p ios` only). |
| `--sha1 <hex>` | — | SHA-1 certificate fingerprint to register, colons optional (`-p android` only; repeatable). |
| `--sha256 <hex>` | — | SHA-256 certificate fingerprint to register, colons optional (`-p android` only; repeatable). |

```bash
appitool firebase add-app -p ios -n "My App"
appitool firebase add-app -p android --package-name com.example.app --sha1 16:00:71:...
appitool firebase add-app -p web -n "My Web App"
```

### `appitool firebase delete-app`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) and [`GlobalCIOptions`](/commands/overview#globalcioptions) (skipped in CI unless `--no-ci`).

Removes an app from the project. By default the removal can be undone in the Firebase console for 30 days; `--immediate` deletes it permanently. The app is chosen explicitly (the `FIREBASE_*_APP_ID` variables are not used as defaults).

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--firebase-app-id <id>` | — | Firebase App ID of the app to remove. |
| `-p, --platform <platform>` | — | `ios`, `android`, or `web`; used instead of `--firebase-app-id` with one of the next three options. |
| `-b, --bundle-id <id>` | — | iOS bundle identifier (`-p ios`). |
| `--package-name <name>` | — | Android package name (`-p android`). |
| `-n, --name <display>` | — | Display name of the web app (`-p web`). |
| `--immediate` | `false` | Delete permanently right away instead of the 30-day restorable removal. |
| `--dry-run` | `false` | Validate the removal with Firebase without removing the app. |

```bash
appitool firebase delete-app -p android --package-name com.example.app --dry-run
appitool firebase delete-app --firebase-app-id 1:123456789:ios:abc123
```

### `appitool firebase sync-fingerprints`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions). The same service account key (`-g, --google-key` / `GOOGLE_KEY`) is used for Google Play and Firebase, so it needs release access to the app in Play Console and a Firebase role that can manage apps.

Registers certificate fingerprints on a Firebase Android app (needed for Google Sign-In, Phone Auth, Dynamic/App Links, etc.):

1. Reads the Play App Signing certificates exactly like [`google signing-certs`](/commands/google#appitool-google-signing-certs) — the deployment certificate and the hybrid classical + post-quantum certificates — and takes the SHA-1 and SHA-256 of each. If an APK cannot be read, only the API's SHA-256 is used for that key.
2. Adds certificates from `-f, --file` (e.g. your upload or debug certificate) and fingerprints from `--sha1` / `--sha256`.
3. Compares with the app's registered fingerprints and adds the missing ones. Existing fingerprints are kept unless `--replace` is passed.

The Firebase app is `--firebase-app-id`, else `FIREBASE_ANDROID_APP_ID`, else the Android app registered for the package name. Download a fresh `google-services.json` afterwards if your build embeds it.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--firebase-app-id <id>` | `FIREBASE_ANDROID_APP_ID` / app for the package name | Firebase Android App ID. |
| `--package-name <name>` | `GOOGLE_PACKAGE_NAME` / Android project | Android package name (Play lookup and app lookup). |
| `--version-code <code>` | Highest version code on your tracks | Version code whose Play-generated APKs are read. |
| `--play` / `--no-play` | `--play` | Read the Play App Signing certificates from Google Play. `--no-play` needs `-f`, `--sha1`, or `--sha256`. |
| `-f, --file <path>` | — | Additional certificate file or folder to register (`.der`/`.cer`/`.crt`/`.pem`; repeatable). |
| `--sha1 <hex>` | — | Additional SHA-1 fingerprint (repeatable; colons optional). |
| `--sha256 <hex>` | — | Additional SHA-256 fingerprint (repeatable; colons optional). |
| `--replace` | `false` | Also remove registered fingerprints that are not in the synced set. |
| `--dry-run` | `false` | Show the changes without applying them. |

```bash
# Add the Play App Signing fingerprints (deployment + hybrid)
appitool firebase sync-fingerprints

# Also register the upload certificate, preview first
appitool firebase sync-fingerprints -f upload_cert.der --dry-run
```

---

## App Distribution Commands

All three release subcommands use [`FirebaseCredentialsOptions`](/commands/overview#firebasecredentialsoptions) (`--firebase-app-id`, `-p, --platform`, `-g, --google-key`, `--project`).

### `appitool firebase list-releases`

Lists uploaded releases for a Firebase application (version, build, creation timestamp, release notes, and console URI).

| Option | Default | Description |
|:---|:---|:---|
| `-l, --limit <count>` | `25` | Maximum number of releases to return (`1–100`). |
| `--order-by <expr>` | — | Ordering expression (e.g. `'createTime desc'`). |

```bash
appitool firebase list-releases --platform ios -l 10
```

### `appitool firebase create-release`

Uploads an `.apk`, `.aab`, or `.ipa` binary to Firebase App Distribution, waits for processing, optionally attaches release notes, and distributes to tester groups/emails.

| Option | Description |
|:---|:---|
| `--binary <path>` | Path to `.apk`, `.aab`, or `.ipa` binary (**Required**). |
| `--release-notes <text>` | Release notes text for testers. |
| `--test-groups <aliases>` | Comma-separated tester group aliases (e.g. `'internal,qa'`). Missing groups are created automatically before upload. |
| `--tester-emails <emails>` | Comma-separated tester email addresses. |

```bash
appitool firebase create-release \
  --platform android \
  --binary ./app-release.apk \
  --release-notes "QA build #42" \
  --test-groups "internal,qa"
```

### `appitool firebase update-release`

Updates an existing Firebase App Distribution release by attaching new release notes and/or distributing to tester groups or emails.

| Option | Description |
|:---|:---|
| `--release-id <id>` | Full release resource path (`projects/.../apps/.../releases/<id>`) or short release ID (**Required**; `--firebase-app-id` is required if passing a short ID). |
| `--release-notes <text>` | New release notes text to attach. |
| `--test-groups <aliases>` | Comma-separated tester group aliases to distribute to. |
| `--tester-emails <emails>` | Comma-separated tester emails to distribute to. |

```bash
appitool firebase update-release \
  --platform ios \
  --release-id 1a2b3c4d5e \
  --release-notes "Updated notes" \
  --test-groups "internal"
```

### `appitool firebase list-groups`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) (`-g, --google-key`, `--project`).

Lists tester groups registered in a Firebase project with alias, tester count, and release count.

| Option | Default | Description |
|:---|:---|:---|
| `-l, --limit <count>` | `25` | Maximum number of groups to return (`1–1000`). |

### `appitool firebase create-group`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions).

Creates a new tester group (or returns the existing group if the alias already exists).

| Option | Default | Description |
|:---|:---|:---|
| `--alias <alias>` | **Required** | Unique alias/ID for the group (e.g. `internal`, `qa-team`). |
| `-n, --name <display>` | `<alias>` | Human-readable display name (e.g. `'Internal Testers'`). |

```bash
appitool firebase create-group --alias qa-team -n "QA Team"
```

---

## Firebase Authentication Commands

All user management subcommands use [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) (`-g, --google-key`, `--project`).

### `appitool firebase list-users`

Lists Firebase Authentication users with optional exact/partial search by email or UID, anonymous filtering, and pagination token support.

| Option | Default | Description |
|:---|:---|:---|
| `-l, --limit <count>` | `100` | Maximum number of users to return. |
| `--search <query>` | — | Search users by email or UID (attempts fast exact lookup on page 1 before paginated scan). |
| `--anonymous <filter>` | `all` | Filter by anonymous status: `all`, `only`, or `exclude`. |
| `--page-token <token>` | — | Pagination token printed at the end of the previous page output. |

```bash
# List up to 50 non-anonymous users
appitool firebase list-users -l 50 --anonymous exclude

# Search for a user by email
appitool firebase list-users --search user@example.com
```

### `appitool firebase delete-user`

Deletes Firebase Authentication user(s) by UID, by email lookup, or deletes all anonymous accounts in batches of 500.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `--uid <uid>` | — | UID (`localId`) of the user to delete. |
| `-e, --email <email>` | — | Email address of the user to look up and delete. |
| `--anonymous` | `false` | Delete all anonymous users in the project (cannot be combined with `--uid` or `-e`). |
| `--dry-run` | `false` | Preview matching user(s) without deleting them. |

```bash
# Preview bulk anonymous user cleanup
appitool firebase delete-user --anonymous --dry-run

# Delete a specific user by email
appitool firebase delete-user -e tester@example.com
```

### `appitool firebase export-users`

Exports all Firebase Authentication users to a UTF-8 CSV file with columns:
`uid,email,email_verified,display_name,phone_number,photo_url,is_anonymous,disabled,providers,created_at,last_login_at`.

| Option | Default | Description |
|:---|:---|:---|
| `--anonymous <filter>` | `all` | Filter exported users: `all`, `only`, or `exclude`. |
| `-o, --output <path>` | `firebase_users_<project>.csv` | Output CSV filename or path. |

```bash
appitool firebase export-users --anonymous exclude -o ./exports/users.csv
```

---

## Cloud Firestore Commands

All `appitool firebase firestore` subcommands use [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) (`-g, --google-key`, `--project`) and `--database <id>` (defaults to `(default)`).

> [!NOTE]
> - **Project ID Resolution:** Firestore requires a string Google Cloud `project_id` resolved in order: `--project` → `FIREBASE_PROJECT_ID` / `GOOGLE_PROJECT_ID` → `project_id` embedded inside the `GOOGLE_KEY` Service Account JSON.
> - **IAM Permissions:** The Service Account must hold `Cloud Datastore Viewer` (`roles/datastore.viewer`) for read-only commands (`collections`, `list`, `get`, `query`) or `Cloud Datastore User` (`roles/datastore.user`) for read/write/delete commands (`set`, `delete`). Service Account requests bypass client Firestore Security Rules.

### `appitool firebase firestore collections`

Lists root collection IDs or subcollection IDs beneath a specific document path.

| Option / Argument | Default | Description |
|:---|:---|:---|
| `<path>` | — | Optional parent document path (even number of segments, e.g. `users/alice`). |
| `-l, --limit <count>` | `100` | Maximum number of collection IDs to return. |
| `--page-token <token>` | — | Pagination token to fetch the next page of collection IDs. |
| `--json` | `false` | Output raw JSON. |

```bash
appitool firebase firestore collections
appitool firebase firestore collections users/alice --json
```

### `appitool firebase firestore list`

Lists documents in a Firestore collection.

| Option / Argument | Default | Description |
|:---|:---|:---|
| `<path>` | **Required** | Firestore collection path (odd number of segments, e.g. `users` or `users/alice/orders`). |
| `-l, --limit <count>` | `50` | Maximum number of documents to return. |
| `--order-by <expr>` | — | Sort expression (e.g. `'createdAt desc'`). |
| `--page-token <token>` | — | Pagination token to fetch the next page of documents. |
| `--json` | `false` | Output raw JSON. |

```bash
appitool firebase firestore list users -l 20
```

### `appitool firebase firestore get`

Fetches a single Firestore document by path.

| Option / Argument | Default | Description |
|:---|:---|:---|
| `<path>` | **Required** | Firestore document path (even number of segments, e.g. `users/alice`). |
| `--json` | `false` | Output raw JSON. |

```bash
appitool firebase firestore get users/alice --json
```

### `appitool firebase firestore set`

Writes a document at a document path (`PATCH`, creating or overwriting) or creates a document with an auto-generated ID when given a collection path (`POST`).

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `<path>` | **Required** | Document path (`users/alice`) or collection path (`users`). |
| `--data <json>` | — | Inline JSON object string containing document fields (mutually exclusive with `-f`). |
| `-f, --file <path>` | — | Path to a JSON file containing document fields (mutually exclusive with `--data`). |
| `--merge` | `false` | Merge provided top-level fields using `updateMask.fieldPaths` (requires a document path). |
| `--json` | `false` | Output raw JSON. |

```bash
appitool firebase firestore set users/alice --data '{"role":"admin","active":true}' --merge
appitool firebase firestore set logs -f ./event.json
```

### `appitool firebase firestore delete`

Deletes a Firestore document by path.

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `<path>` | **Required** | Firestore document path (even number of segments, e.g. `users/alice`). |
| `--dry-run` | `false` | Check whether the document exists without deleting it. |

```bash
appitool firebase firestore delete users/alice --dry-run
appitool firebase firestore delete users/alice
```

### `appitool firebase firestore query`

Runs a structured query (`:runQuery`) against a collection (or collection group when `--all-descendants` is set).

| Option / Flag / Argument | Default | Description |
|:---|:---|:---|
| `<path>` | **Required** | Firestore collection path (odd number of segments, e.g. `users` or `orders`). |
| `-w, --where <expr>` | — | Repeatable filter expression: `<field> <op> <value>`. Supported `<op>`: `==`, `!=`, `<`, `<=`, `>`, `>=`, `array-contains`, `in`, `not-in`, `array-contains-any`. |
| `--order-by <expr>` | — | Repeatable sort clause (`<field> [asc\|desc]`). |
| `-l, --limit <count>` | `50` | Maximum number of documents to return. |
| `--all-descendants` | `false` | Query across all descendant collections matching the final collection ID (collection group query). |
| `--json` | `false` | Output raw JSON. |

```bash
appitool firebase firestore query users \
  -w 'active == true' \
  -w 'age >= 18' \
  --order-by 'age desc' \
  -l 10 \
  --json
```
