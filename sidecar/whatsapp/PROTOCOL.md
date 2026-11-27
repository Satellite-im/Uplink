# Uplink's WhatsApp helper: the protocol

Matt, 2026-11-17: "enable whatsapp but warn the user that it's unsupported by whatsapp". A helper process,
`whatsapp-sidecar`, built on [whatsmeow](https://github.com/tulir/whatsmeow) (MPL-2.0, the library mautrix-whatsapp is
built on), linked to the person's WhatsApp account as a linked device (as WhatsApp Web is). The app
(lib/inbox/whatsapp.dart) runs it as a child process on the phone and on a computer and speaks JSON lines over its
stdin and stdout, in the same shape as the Signal helper (sidecar/signal/PROTOCOL.md).

WhatsApp does not support or allow other apps. WhatsApp may suspend or ban accounts it finds using unofficial ones; the
app says so before linking (lib/ui/inbox_signin_whatsapp.dart).

Run: `whatsapp-sidecar --dir <folder>`. The folder holds its SQLite store (`whatsapp.db`), `whatsapp.log` and cached
avatars. Logs go to stderr too.

Chats and people are named by JID: a person `15550100@s.whatsapp.net` (their phone number; `…@lid` where WhatsApp gives
none), a group `1203630…@g.us`. Messages are named by WhatsApp's message id (a string), not by time.

## Requests (stdin), one JSON object a line

Every request has `id` (a number the app picks) and `op`. Each is answered by one line
`{"id": <same>, "ok": true, "result": <...>}` or `{"id": <same>, "ok": false, "error": "<words>"}`.

| op | fields | result |
| --- | --- | --- |
| `status` | | `{"linked": bool, "connected": bool, "jid": "…@s.whatsapp.net", "number": "+1…", "name": "<push name>"}` |
| `link` | | `null` at once; then `qr` events and `linked` / `link_failed` |
| `pair_phone` | `phone` (any form, digits taken) | `{"code": "ABCD-EFGH"}` (also a `pair_code` event): typed on the phone in Linked devices › Link a device › Link with phone number instead. Starts linking if none is under way |
| `unlink` | | `null`; logs out of WhatsApp and forgets everything |
| `contacts` | | `[{"jid", "name", "number", "avatar": null}]`: the phone's address book as WhatsApp synced it |
| `groups` | | `[{"id", "title", "members": ["<jid>"], "avatar": null}]`: every group the account is in |
| `send` | `to` (a JID or a phone number), `text`, optional `quote` (`{"id", "author": "<jid>", "text"}`) | `{"id": "<message id>", "ts": <ms>}` |
| `send_media` | `to`, `path`, `mime`, `name`, optional `text` (the caption) | `{"id", "ts", "pointer": {…}}` |
| `read` | `to`, `author` (the sender's JID; in a group needed), `ids` (message ids) | `null`: read receipts sent |
| `react` | `to`, `author` (the target's sender; empty for your own), `target` (message id), `emoji`, `remove` | `null` |
| `delete` | `to`, `target` | `null`: your own message deleted for everyone |
| `download` | `pointer` (as a `message` gave it: the object, or that object as a string), `path` | `null` once written to `path` |
| `who` | `jid` | `{"jid", "name", "number", "avatar"}` (avatar: a cached file of their profile picture, or null) |
| `block` | `jid`, `on` (true blocks, false unblocks) | `null`: on WhatsApp itself |
| `blocked` | | `[{"jid", "name", "number", "avatar"}]`: WhatsApp's block list |
| `group_info` | `to` (a group JID) | `groups`' fields with the picture, and `description`, `timer` (seconds, 0 off), `people` (`[{"jid", "name", "number", "admin", "owner", "me"}]`), `admin` (you are), `edit_info` and `add_members` (`"members"` or `"admins"`), `announcements_only` |

## Events (stdout), one JSON object a line, each with `ev`

| ev | fields |
| --- | --- |
| `ready` | `linked` (bool) |
| `qr` | `url` (the text to draw as a QR code for WhatsApp › Settings › Linked devices › Link a device), `timeout` (seconds it lasts: 60 the first, 20 after); about six to a round, and up to four rounds |
| `pair_code` | `code` |
| `linked` | `jid`, `number`, `name` |
| `link_failed` | `error` |
| `banned` | `error`: WhatsApp temporarily banned the account (its reason and how long) |
| `connected` / `disconnected` | |
| `message` | `chat`, `group` (bool), `id`, `from` (sender JID; yours for your own), `name` (sender's name where known), `mine` (bool), `ts` (ms), `text`, `media` (list of `{"pointer": {"kind", "msg"}, "mime", "name", "size", "width", "height"}`), `quote` (optional `{"id", "author", "text"}`) |
| `history` | one chat from WhatsApp's history sync (what WhatsApp gives a newly linked device, and later more): `chat`, `group`, `name`, `unread`, `last` (ms), `messages` (`message` events' fields, oldest first, each with `history: true` and optional `reactions`, who → emoji). The same chat can come again in a later sync |
| `edited` | `chat`, `target_id`, `text` |
| `receipt` | `chat`, `from`, `ids`, `kind` (`delivered` or `read`) |
| `reaction` | `chat`, `from`, `target_id`, `target_mine`, `emoji`, `remove` |
| `deleted` | `chat`, `target_id` (deleted for everyone by its author) |
| `contacts` | `list`: contacts as WhatsApp's sync changes them |
| `name` | `jid`, `name`, `number`, `avatar`: a push name met in a message or a history sync |
| `group` | a group as `groups` gives it, when joined, changed or first written in this run |
| `unlinked` | WhatsApp removed this device |
