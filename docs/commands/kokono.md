# `appitool kokono`

Dispatches a push notification to a KokoNo webhook endpoint (`?token=<token>`), with optional end-to-end (E2E) encryption.

## End-to-End Encryption & Keypair Isolation

- When an E2E public key is resolved (Base64-encoded 32-byte Curve25519 / X25519 public key), `NotifyTask` encrypts both `title` and `message` using an ephemeral X25519 key pair + `HKDF-SHA256` (`salt: "kokono-salt-v1"`, `info: "kokono-info-v1"`) + `AES-256-GCM`.
- Messages longer than 250 characters are truncated with `...`.
- **Per-URL Keypair Isolation**: If `-u, --url` is explicitly passed on the command line, `appitool kokono` will **not** fall back to `KOKONO_E2E_PUBLIC_KEY` from `.env`—you must also pass `-e, --e2e` explicitly if you want encryption for that custom URL.

## Synopsis

```bash
appitool kokono -m <message> [options]
```

## Options

| Option | Default / `.env` Fallback | Description |
|:---|:---|:---|
| `-t, --title <title>` | `appitool` | Notification title. |
| `-m, --message <message>` | **Required** | Notification message body. |
| `-u, --url <url>` | `KOKONO_URL` | KokoNo notification webhook URL (`https://kokono.me/notify?token=...`). |
| `-e, --e2e <public-key>` | `KOKONO_E2E_PUBLIC_KEY` (when `-u` is omitted) | Base64 X25519 public key for E2E encryption. |

## Examples

```bash
# Send plain notification using KOKONO_URL from .env
appitool kokono -m "Release v0.9.0 deployed to TestFlight."

# Send E2E encrypted notification with explicit title
appitool kokono -t "CI Alert" -m "Build #128 succeeded." -e "<base64_x25519_public_key>"
```
