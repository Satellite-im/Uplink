# Uplink's Instagram helper: the protocol

The protocol is the one all of Uplink's account helpers share: **../ACCOUNT_HELPERS.md** (requests, answers, events,
field names). This file says only what is particular to Instagram. Run: `instagram-sidecar --dir <folder>`.

## Signing in: the cookies

`sign_in` takes `cookies`, an object of cookie name → value from a browser signed in to **instagram.com**.

- Needed: `sessionid`, `csrftoken`, `ds_user_id`. One missing is an error naming it, before anything is asked of
  Instagram.
- Taken where present, and worth sending (they make the session look like the browser it came from): `mid`, `ig_did`,
  `rur`, `shbid`, `shbts`. Any other cookie sent is kept and sent back to Instagram too.

The cookies are checked by loading Instagram's inbox page with them. Where Instagram asks for a check, the error says
to finish it in the browser and copy the cookies again. `unlink` forgets the session here and leaves the browser's
alone. A later `unlinked` event carries, in `error`, words to show: signed out, a check to finish, something to agree
to, a suspended or limited account.

Start with a session held: `ready` `{linked: true}` at once, then `chat` and `name` events for the inbox and
`connected` once Instagram has answered, or `unlinked`. Until then every other request but `status`, `sign_in`,
`unlink` and `download` answers "Instagram is still connecting: try again in a moment".

## Ids

All are Instagram's own, as strings.

- **A chat `id`** is Instagram's thread id as its website's requests name it (the `id` of a thread, the `thread_fbid`
  of an event): digits. For a group it is the group's number; for two people it is usually the other person's id.
- **A person `id`** (`from`, `me`, a member's `id`, `who`) is the number Instagram's messages name their sender by
  (`interop_messaging_user_fbid`), digits. It is **not** the profile id in `ds_user_id`, nor the username; `handle`
  is the username.
- **A message `id`** is Instagram's message id, an opaque string (`mid.$…`). `quote.id`, `target`, `before` and
  `upto` take it as given.

## Requests

- `chats`: the inbox's **first page** only, as the website lists it first (about twenty threads), asked of Instagram
  each time. The same threads are said as `chat` events after `sign_in` and at each start.
- `history`: `chat`, optional `before` (a message id). Without `before`, the newest twenty; with it, the twenty older
  than that message. Oldest first. `more` says whether older ones remain: page by passing the oldest message's `id`
  as the next `before`. Instagram's own lines about a thread ("X named the group") are left out. Each message may
  also carry `reactions`: `[{"from", "emoji", "mine"}]`, the reactions it already has (not in the shared protocol;
  safe to ignore).
- `send`: `to`, `text`, optional `quote: {"id"}`. The message is also said back as a `message` event with
  `mine: true` when Instagram tells the connection of it: match by `id`.
- `send_media`: `to`, `path`, `mime`, `name`, optional `text`. A file on Instagram carries no words, so `text` is
  sent as a message after it; the answer is the file's `{"id", "ts"}`. 100 MB at most.
- `read`: `to`, optional `upto` (the id of the newest message read; without it, the newest the helper has met in the
  thread).
- `react`: one reaction a person a message; a new one replaces the old. `remove: true` takes it off.
- `delete`: unsends the person's own message for everyone.
- `download`: `pointer` as a message's `media` gave it (`{"url", "mime"}`), `path`. Works without a session.
- `who`: `who`, a person id.

## Events

- `message`: `text` is never empty together with an empty `media`. A shared post, reel, story or profile is
  "Shared a post: <link>" (its picture, where there is one, in `media`); a picture or video Instagram gave no
  address for, a seen-once one, and anything the helper cannot show are a line of words saying to open Instagram.
- `receipt`: Instagram says only the **time** someone has read up to. `id` is the newest message the helper has met
  in that thread at or before that time, and is `""` where it has met none (nothing listed or fetched yet in this
  run); `ts` (ms) is the time itself and is always there. `kind` is always `read`. A receipt `from` the person's own
  id means they read the thread elsewhere.
- `reaction` with `remove: true` may come with an empty `emoji`.
- `chat` and `name` are said again, with `avatar` set, once a picture has been fetched; first with `avatar: null`.

## Files

Media and avatar addresses are signed links on Instagram's content servers. They need **no cookies** (none are sent),
but they **run out** after a while: a `download` of an old pointer fails in words, and a fresh `history` gives a new
one. `size` is left out (not known before fetching). `mime` is read from the address's ending, and where it has none
is the usual one for the kind (`image/jpeg`, `video/mp4`, `audio/mp4`). `width` and `height` are there where
Instagram gives them. Avatars are fetched by the helper into `avatars/`; an `avatar` is a file path there, or null.

## Not supported

See README.md, "Not yet". Each is an error in words from its op, or simply not said: the inbox beyond its first
page, message requests, starting a chat, editing, typing notices, group changes, `delivered` receipts, seen-once
media.
