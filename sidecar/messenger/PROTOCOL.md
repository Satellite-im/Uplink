# The Messenger helper's protocol

The helper speaks the protocol every account helper shares: [../ACCOUNT_HELPERS.md](../ACCOUNT_HELPERS.md). This
page is what is Messenger's own.

## Signing in

`{"id": 1, "op": "sign_in", "cookies": {"c_user": "…", "xs": "…", "datr": "…", …}}`

- Needed: `c_user`, `xs`, `datr`. Without one the answer names it ("These cookies are missing: datr, xs. …") and
  nothing is sent to Meta. Give every cookie the site has (`sb`, `fr`, `wd`, `presence`, …): they are sent as a
  browser sends them.
- From **messenger.com** or **facebook.com**, in a browser signed in to the account. The two sites' cookies have
  the same names and are not each other's, so which site a set is from cannot be told by looking. The optional field
  `site` (`"messenger"` or `"facebook"`) says it; without it messenger.com is tried first and facebook.com after it,
  only where the first says the session is not its own.
- Where Meta asks for a check, to agree to something, or says the session has ended, the answer says to finish it
  in the browser and copy the cookies again. The same words come later as an `unlinked` event (with `url`, where
  Meta named a page to open) if Meta ends a session that was working; the helper then forgets everything.
- `unlink` forgets everything here. It does not sign the browser out, and it does not remove this helper from the
  account's list of devices for encrypted chats.

## Ids

- A person: Meta's number for them, as a string (`"100004567890123"`). `me` in `status` is the person's own.
- A chat: Meta's thread key as a string. With one other person it is that person's number; a group's is the
  group's own. An end-to-end encrypted chat is known by its number on the encrypted side (for two people, again the
  other person's number).
- A message of an ordinary chat: Meta's id, `mid.$…`.
- A message of an end-to-end encrypted chat: `wa:<sender's number>:<the id its sender gave it>`. Meta has no id
  of its own for these. Ids are given back as they came (`quote.id`, `target`, `upto`, `before`).

## What differs from the shared page

- `read`: `{"id": 8, "op": "read", "to": "<chat>", "upto": "<message id>"}`. `upto` is optional; without it the chat
  is marked read up to now.
- `chat` events and `chats` carry two more fields: `encrypted` (bool) and `folder` (Messenger's own: `inbox`,
  `pending` for a message request, `archived`, `e2ee_cutover`, …). `unread` is exact only where Messenger gives a
  count, and 1 elsewhere for "something waits".
- `message`: `system: true` on Messenger's own lines ("Ada named the group"); `encrypted: true` in encrypted
  chats; `unsupported: true` where the words are the helper's ("This kind of message can't be shown here yet…").
  `quote.text` is there in ordinary chats only.
- `media[].pointer` is `{"url", "mime"}` in ordinary chats: an address on Meta's file servers that needs no
  sign-in and stops working after some days (`download` then says the address has expired; `history` gives a new
  one). In encrypted chats it is `{"e2ee": {…}}`, which only `download` can open. `download` fetches from Meta's
  servers and nowhere else.
- `receipt`: has `ts` (ms) beside `id`. In ordinary chats Messenger marks reading by time, so `id` is the newest
  message the helper has seen at or before `ts`, or empty. The person's own reading elsewhere comes as a
  `receipt` from `me` and, where it empties the chat, a `chat` with `unread: 0`.
- `edited`: `chat` is empty where the helper cannot tell which chat the message is in (Messenger does not say).
- `history`: one stretch a request (about twenty messages), oldest first; `before` is the oldest id of the
  stretch before. For an encrypted chat: `{"messages": [], "more": false, "encrypted": true}`.
- `avatar` is a file under `avatars/`. A picture is fetched behind: a `chat` or `name` first comes with
  `avatar: null` and is said again once the file is there. `who` waits a few seconds for it.
- `send_media` works in ordinary chats; in encrypted ones it answers "Files can't be sent in end-to-end encrypted
  Messenger chats from here yet".
- Messages that came while the helper was not running are not said as `message` events; `chat` (unread, last,
  snippet) and `history` have them.

What is not done yet is listed in README.md.
