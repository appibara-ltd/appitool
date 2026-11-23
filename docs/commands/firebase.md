# `appitool firebase`

Manages Firebase App Distribution releases and tester groups, Firebase Authentication user accounts, and Cloud Firestore collections and documents.

> [!NOTE]
> **CI Guard:** Destructive subcommands (`delete-user` and `firestore delete`) accept [`GlobalCIOptions`](/commands/overview#globalcioptions) (`--ci` / `--no-ci`) and are skipped as a no-op (exit code `0`) when running in CI mode. Pass `--no-ci` to force execution in CI.

## Synopsis

```bash
appitool firebase <subcommand> [options]
```

## Subcommands Summary

| Domain | Subcommand | Description |
|:---|:---|:---|
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
