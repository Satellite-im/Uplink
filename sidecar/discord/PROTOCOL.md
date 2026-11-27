# Uplink's Discord helper: the protocol

The protocol is the one all of Uplink's account helpers share: [../ACCOUNT_HELPERS.md](../ACCOUNT_HELPERS.md).
This file says only what is Discord's own.

Run: `discord-sidecar --dir <folder>`. The folder holds `session.json` (mode 0600), `discord.log` and `avatars/`.

## Signing in

`sign_in`'s `cookies` must carry `token`: the account's token, from discord.com in a browser signed in to the
account, with or without the quotes the browser's storage shows round it. Real cookies beside it are taken and not
used. The helper connects to Discord's gateway with it; Discord's answer (READY) says whose it is. A missing token,
a bot's token (`Bot …`) or one Discord refuses is an error saying so. `session.json` keeps the token, who it is, and
the "heartbeat session" Discord's website keeps between runs.

## Ids

All are Discord's own ids (numbers, as strings), passed back unchanged:

- a direct message or a group: its channel id, e.g. `1153138320998400000`.
- a server's channel: `guild:<server id>:<channel id>`. Only these have the `guild:` prefix.
- a message: its id. A person: their user id. `me` is the person's own user id, so it equals the `from` of their
  own messages.
- `handle` is the username (`name`, or `name#1234` for an account not moved to Discord's new usernames).
- `name` is the display name, or the username where there is none; in a server, the person's nickname there.

## Where Discord differs

- `chats`: the newest 20 direct messages and groups (READY's list, sorted by their last message). When the gateway
  connects, the newest 50 are said as `chat` events. Server channels are not listed (README.md, Server channels).
  `snippet` is never given: Discord's list does not carry the last message.
- `chat`: `unread` is how many unread messages Discord counts for a direct message or a group; for a server channel
  1 means "something new" (Discord counts only mentions there). Where Discord has said nothing of a chat's read mark,
  `unread` is 0. A group's `avatar` is its icon, a server channel's the server's.
- `history`: pages of 50 by message id; `before_ts` is not needed and is ignored. `more` is true when the page was
  full. Discord's own notes in a channel (someone added, a call, a pin) are left out.
- `send`: at most 2000 characters. `quote` needs only `id`. Discord's live stream says your own sent message back as
  a `message` event with the same id and `mine` true.
- `send_media`: one file, attached as the website does (Discord gives an upload address, the file is put there, the
  message names it), with `text` as its words.
- `read`: marks the chat read up to `upto`; without it, up to its newest message.
- `react`: a unicode emoji (fully qualified on the way, so ❤ goes as ❤️), or a server's own as `name:id` or
  `<:name:id>`. `remove` takes back the person's own.
- `delete`: your own message (in a server, others' too where the account may manage messages), deleted for everyone.
- `message`: `media[].pointer` is `{"url", "chat", "message", "attachment"}`. Discord signs attachment addresses and
  they run out after about a day; `download` then asks Discord for the message again and fetches the fresh address.
  Mentions are written `@name`, a server's own emoji `:name:`. A forwarded message's words follow its own, quoted
  with `> `. `quote` is `{"id", "text", "from", "name"}` for a reply (`mime` in place of `text` where the message answered is a file with no words; the id alone where Discord sent nothing of it). `reactions` (in `history`) are the person's own only.
- `edited`: said when a message's words change (not when Discord adds a link's preview). `deleted`: a message was
  deleted. `reaction`: anyone's, with a server's own emoji as `:name:`. `receipt`: only from the person themselves
  (they read the chat in Discord's own app), `kind` `read`.
- `unlinked`: Discord refused the token (the gateway closed with 4004, or a request answered 401).
- `who`: someone met in this run, else asked of Discord by id.
- `avatar`: files under `avatars/`, named by a hash of whose picture it is and which; Discord's picture addresses
  need no token.

## Not supported

Nothing in the shared protocol is refused outright. What is partial is listed in README.md under "Not yet"; an op
the helper does not know is answered with an error.
