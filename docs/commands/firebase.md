# `appitool firebase`

Manages Firebase App Distribution releases and tester groups, as well as Firebase Authentication user accounts.

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

---

## App Distribution Commands

All three release subcommands use [`FirebaseCredentialsOptions`](/commands/overview#firebasecredentialsoptions) (`--firebase-app-id`, `--platform`, `-g, --google-key`, `-p, --project`).

### `appitool firebase list-releases`

Lists uploaded releases for a Firebase application (version, build, creation timestamp, release notes, and console URI).

| Option | Default | Description |
|:---|:---|:---|
| `-l, --limit <count>` | `25` | Maximum number of releases to return (`1–100`). |
| `-o, --order-by <expr>` | — | Ordering expression (e.g. `'createTime desc'`). |

```bash
appitool firebase list-releases --platform ios -l 10
```

### `appitool firebase create-release`

Uploads an `.apk`, `.aab`, or `.ipa` binary to Firebase App Distribution, waits for processing, optionally attaches release notes, and distributes to tester groups/emails.

| Option | Description |
|:---|:---|
| `-b, --binary <path>` | Path to `.apk`, `.aab`, or `.ipa` binary (**Required**). |
| `-r, --release-notes <text>` | Release notes text for testers. |
| `--test-groups <aliases>` | Comma-separated tester group aliases (e.g. `'internal,qa'`). |
| `--tester-emails <emails>` | Comma-separated tester email addresses. |

```bash
appitool firebase create-release \
  --platform android \
  -b ./app-release.apk \
  -r "QA build #42" \
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

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) (`-g, --google-key`, `-p, --project`).

Lists tester groups registered in a Firebase project with alias, tester count, and release count.

| Option | Default | Description |
|:---|:---|:---|
| `-l, --limit <count>` | `25` | Maximum number of groups to return (`1–1000`). |

### `appitool firebase create-group`

Uses [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions).

Creates a new tester group (or returns the existing group if the alias already exists).

| Option | Default | Description |
|:---|:---|:---|
| `-a, --alias <alias>` | **Required** | Unique alias/ID for the group (e.g. `internal`, `qa-team`). |
| `-n, --name <display>` | `<alias>` | Human-readable display name (e.g. `'Internal Testers'`). |

```bash
appitool firebase create-group -a qa-team -n "QA Team"
```

---

## Firebase Authentication Commands

All user management subcommands use [`FirebaseProjectOptions`](/commands/overview#firebaseprojectoptions) (`-g, --google-key`, `-p, --project`).

### `appitool firebase list-users`

Lists Firebase Authentication users with optional exact/partial search by email or UID, anonymous filtering, and pagination token support.

| Option | Default | Description |
|:---|:---|:---|
| `-l, --limit <count>` | `100` | Maximum number of users to return. |
| `-s, --search <query>` | — | Search users by email or UID (attempts fast exact lookup on page 1 before paginated scan). |
| `-a, --anonymous <filter>` | `all` | Filter by anonymous status: `all`, `only`, or `exclude`. |
| `-t, --page-token <token>` | — | Pagination token printed at the end of the previous page output. |

```bash
# List up to 50 non-anonymous users
appitool firebase list-users -l 50 -a exclude

# Search for a user by email
appitool firebase list-users -s user@example.com
```

### `appitool firebase delete-user`

Deletes Firebase Authentication user(s) by UID, by email lookup, or deletes all anonymous accounts in batches of 500.

| Option / Flag | Default | Description |
|:---|:---|:---|
| `-u, --uid <uid>` | — | UID (`localId`) of the user to delete. |
| `-e, --email <email>` | — | Email address of the user to look up and delete. |
| `-a, --anonymous` | `false` | Delete all anonymous users in the project (cannot be combined with `-u` or `-e`). |
| `-d, --dry-run` | `false` | Preview matching user(s) without deleting them. |

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
| `-a, --anonymous <filter>` | `all` | Filter exported users: `all`, `only`, or `exclude`. |
| `-o, --output <path>` | `firebase_users_<project>.csv` | Output CSV filename or path. |

```bash
appitool firebase export-users -a exclude -o ./exports/users.csv
```
