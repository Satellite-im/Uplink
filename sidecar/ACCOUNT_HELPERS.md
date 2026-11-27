# Uplink's account helpers: the protocol they share

Matt, 2026-11-20: "Let's do the feasible ones but skip X and google voice": Facebook Messenger (`sidecar/messenger`,
on mautrix-meta's messagix), Instagram (`sidecar/instagram`, on mautrix-meta's instameow: that project moved
Instagram off messagix in 2026) and LinkedIn (`sidecar/linkedin`, on mautrix-linkedin's linkedingo). Each is a helper
process the app runs beside itself and speaks to in JSON lines over stdin and stdout, in the shape of the WhatsApp
helper (sidecar/whatsapp/PROTOCOL.md). They speak the **same** protocol, written here, so one class in the app drives
all three (lib/inbox/account_helper.dart).

None of these services supports or allows other apps. Each helper signs in as the person, **with the cookies of a
browser signed in to their account**, and behaves as the website does. The service may ask the person to confirm it
is them, sign the session out, or restrict the account; the app says so before signing in.

Run: `<helper> --dir <folder>`. The folder holds what
the helper keeps (`session.json`: the cookies and what it needs to connect again, readable by the person alone, mode
0600; `<name>.log`; `avatars/`). Logs go to stderr too. Nothing a message says is logged at info level.

Everything is named by the service's own ids, as strings: a chat `id`, a person `id`, a message `id`.

## Requests (stdin), one JSON object a line

Every request has `id` (a number the app picks) and `op`. No other field of a request is called `id`. Each is answered by one line
`{"id": <same>, "ok": true, "result": <...>}` or `{"id": <same>, "ok": false, "error": "<words for a person>"}`.

| op | fields | result |
| --- | --- | --- |
| `status` | | `{"linked": bool, "connected": bool, "me": "<own id>", "name": "<shown name>", "handle": "<username or empty>"}` |
| `sign_in` | `cookies` (an object, cookie name → value; Discord's and Slack's session token rides in it as `token`), and for X `passcode` (the 4-digit X Chat passcode, never kept) | `{"me", "name", "handle"}` once the service has taken them (also a `linked` event); an error in words where it has not (a cookie missing: say which; the service asks for a check: say to finish it in the browser and copy again) |
| `unlink` | | `null`: signed out here and everything kept forgotten (the browser's own session is not signed out) |
| `chats` | | `[<chat>]`: the chats the service lists first (about the newest 20), each as a `chat` event gives it |
| `history` | `chat`, optional `before` (a message id: older than it) with `before_ts` (that message's time, ms: for a service that pages by time) | `{"messages": [<message>], "more": bool}`: oldest first; also kept nowhere by the helper |
| `send` | `to` (a chat id), `text`, optional `quote` (`{"id", "text", "author", "ts"}`: the message answered, and what the app knows of it) | `{"id": "<message id>", "ts": <ms>}` |
| `send_media` | `to`, `path`, `mime`, `name`, optional `text` | `{"id", "ts"}`; an error saying so where the helper cannot send files yet |
| `read` | `to`, optional `upto` (the id of the newest message read; never `id`, which is the request's own) | `null` |
| `react` | `to`, `target` (message id), `emoji`, `remove` (bool) | `null`; an error where not supported |
| `delete` | `to`, `target` | `null`: your own message unsent; an error where not supported |
| `download` | `pointer` (as a message's `media` gave it), `path` | `null` once written to `path` |
| `who` | `who` (a person's id) | `{"id", "name", "handle", "avatar"}` (`avatar`: a file in `avatars/`, or null) |
| `people` | optional `query` (part of a name or handle) | `[{"id", "name", "handle", "avatar"}]`: the service's people it finds, to start a chat with (GMFB-61). Only where the service lists them cheaply: Slack's workspace members. An error elsewhere, and the app then offers only people there is a chat with |
| `open` | `who` (a person's id) | `{"id": "<chat id>"}`: the chat between the account and them, made where there is none; nothing is sent. Only where `people` is |

## Events (stdout), one JSON object a line, each with `ev`

| ev | fields |
| --- | --- |
| `ready` | `linked` (bool): the helper is up, and whether it holds a session |
| `linked` | `me`, `name`, `handle` |
| `unlinked` | `error`: the service ended the session (signed out, a check asked for); the app shows it and asks to sign in again |
| `connected` / `disconnected` | the live connection |
| `chat` | a chat: `id`, `title` (a group's name, the other person's for two; never empty where anything names it), `group` (bool), `members` (`[{"id", "name"}]`, the others), `avatar` (a file, or null), `unread` (a count), `last` (ms), optional `snippet` (the last message's words) and `snippet_mine` (bool) |
| `message` | `chat`, `group` (bool), `id`, `from` (sender's id), `name` (sender's name where known), `mine` (bool), `ts` (ms), `text`, `media` (a list of `{"pointer": {…}, "mime", "name", "size", "width", "height"}`; `pointer` is the helper's own, given back to `download`), optional `quote` (`{"id", "text"}`, and where the service says: `from` and `name`, who wrote the message answered, and `mime`, its first file's type where it has no words), optional `reactions` (`[{"from", "emoji"}]`: those it already has, in `history`) |
| `edited` | `chat`, `target`, `text` |
| `deleted` | `chat`, `target` |
| `reaction` | `chat`, `from`, `target`, `emoji`, `remove` |
| `receipt` | `chat`, `from`, `id` (read up to this message; empty where the service gives only a time), optional `ts` (that time, ms), `kind` (`read` or `delivered`). From the person's own id: they read the chat in the service's own app |
| `name` | `id`, `name`, `handle`, `avatar`: someone met in a message |

A helper says only what it knows: a field it has nothing for is left out or empty, never guessed. What a helper does
not do yet is an error from that op, in words, and is listed in its own README.
