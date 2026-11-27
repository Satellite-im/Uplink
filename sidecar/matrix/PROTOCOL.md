# Uplink's Matrix helper: the protocol

Matt, 2026-11-17: "Let's add support for matrix, microsoft teams and google chat". A helper process, `matrix-sidecar`,
built on mautrix-go (MPL-2.0) with its pure-Go Olm/Megolm (`goolm`), signed in to the person's Matrix account as a
device of its own. The app (lib/inbox/matrix.dart) runs it as a child process on the phone and on a computer and speaks
JSON lines over its stdin and stdout, as it does with the Signal helper (sidecar/signal).

Run: `matrix-sidecar --dir <folder>`. The folder holds `session.json`, `matrix.db`, `rooms.json` and `avatars/`
(README.md). Logs go to stderr.

## Requests (stdin), one JSON object a line

Every request has `id` (a number the app picks) and `op`. Each is answered by one line
`{"id": <same>, "ok": true, "result": <...>}` or `{"id": <same>, "ok": false, "error": "<words>"}`.

| op | fields | result |
| --- | --- | --- |
| `status` | | `{"logged_in": bool, "user_id": "@me:server", "device_id", "homeserver": "<client API address>", "name": "<display name>", "verified": bool}`; while a kept session waits for the network, `{"logged_in": false, "resuming": true, "user_id"}` |
| `login_password` | `homeserver` (a server name, an address with its scheme, or a user id; empty is matrix.org), `user` (a name or a full `@name:server`), `password` | the status, signed in. The server is found by `.well-known/matrix/client` |
| `sso_url` | `homeserver`, `redirect` (the address the browser comes back to: the app listens on `http://127.0.0.1:<port>/`) | `{"url": "<homeserver>/_matrix/client/v3/login/sso/redirect?redirectUrl=…", "homeserver", "password": bool (the server also takes passwords)}`; refused where the server offers no SSO |
| `login_token` | `token` (the `loginToken` the redirect brought), optional `homeserver` (else the one `sso_url` was asked for) | the status, signed in |
| `logout` | | `null`; this device signed out on the server, and everything here forgotten |
| `verify_recovery_key` | `key` (the recovery key, Element's Security Key: "EsT… …") | `{"verified": true, "backup_version": "<version>" or null, "backup_error": "<words>" (where the backup could not be had)}`. Unlocks secret storage, signs this device with the account's cross-signing keys, and restores the server-side key backup |
| `rooms` | | `[room, …]`, the newest first (a room is below) |
| `messages` | `room`, optional `from` (the `end` an earlier answer gave, for older ones), `limit` (default 30, at most 100) | `{"messages": [message, …] (newest first), "reactions": [reaction, …], "end": "<token for older>"}`; each encrypted one decrypted where this device has its key |
| `send` | `room`, `text`, optional `reply_to` (an event id) | `{"id": "$event"}` |
| `send_media` | `room`, `path`, `mime`, `name`, optional `text` (the caption) | `{"id": "$event", "media": media}`; encrypted before upload in an encrypted room |
| `read` | `room`, `event` (the last event read) | `null`: the read receipt and read marker sent, and the room's unread count cleared |
| `react` | `room`, `event`, `emoji` | `{"id": "$reaction"}`. Taking a reaction off is `redact` on that id |
| `redact` | `room`, `event` | `null`: deleted for everyone (your own message, or your reaction) |
| `download` | `mxc`, optional `file` (a media's `file` object as a message gave it, or that object as a string: its key), `path`, optional `thumb` (a small copy, for an unencrypted picture) | `null` once written to `path`, decrypted where it had a key |
| `join` | `room` | `null`: an invite accepted (a direct chat's kept in `m.direct`, as Element does) |
| `leave` | `room` | `null`: left, or an invite declined |

A **room**: `{"id": "!room:server", "title": "…", "avatar": "<file here>" or null, "avatar_mxc": "mxc://…" (where it
has one), "members": ["@user:server", …] (everyone else in it), "is_direct": bool, "with": "@user:server" (a direct
chat's other person) or null, "invite": bool, "inviter": "@user:server" or null, "encrypted": bool, "unread": n,
"last": {"id", "from", "text", "ts", "mine", "media": bool, "undecryptable": bool} or null, "ts": <ms of the last
message>}`. The title is the room's name, else its alias, else the other person's (or people's) display names.

A **message**: `{"room", "id": "$event", "from": "@user:server", "name": "<their display name in the room>", "mine":
bool, "ts": <ms>, "text": "…", "kind": "m.text" | "m.emote" | "m.notice" | "m.image" | …, "media": [media, …],
"reply_to": "$event" (optional), "replaces": "$event" (optional: an edit, whose `text` is the message's new words),
"undecryptable": true (optional: encrypted, and no key here yet)}`. Reply fallbacks ("> <@who> …") are taken out.

A **media**: `{"mxc": "mxc://…", "file": {…} or null (the key, in an encrypted room), "mime", "name", "size",
"width", "height", "duration"}`.

A **reaction**: `{"room", "id": "$reaction", "target": "$event", "from", "emoji", "ts"}`.

## Events (stdout), one JSON object a line, each with `ev`

| ev | fields |
| --- | --- |
| `ready` | `logged_in` (bool), `resuming` (bool: a kept session waiting for the network) |
| `synced` | `initial` (bool): the first sync of this run is through; the app asks for `rooms` |
| `message` | a message, as above (from any of the person's devices: `mine` says which are theirs) |
| `receipt` | `room`, `id` (the event read up to), `from` (who read it; never the person) |
| `reaction` | a reaction, as above |
| `redacted` | `room`, `target` (the event taken away: a message or a reaction), `from` |
| `room` | a room, as above: a room changed (name, picture, people, unread count, last message) or appeared, invites too |
| `room_gone` | `room`: left, or kicked |
| `logged_out` | `error` (why): the server signed this device out; everything here is forgotten |

The server keeps history: `messages` brings what came before this device, encrypted ones decrypting where a key is
here (from the key backup after `verify_recovery_key`, or shared by another device).
