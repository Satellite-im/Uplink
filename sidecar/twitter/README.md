# Uplink's X helper

A small program Uplink runs beside itself to reach the person's X (Twitter) direct messages: signed in with
the cookies of a browser signed in to their account and their X Chat passcode, then the inbox's chats, their history,
messages as they arrive, sending (words, replies, pictures, GIFs, videos and voice messages), reactions, taking a
message back, read marks, and the names and pictures of the people met.

**X does not support this, and does not allow it.** X has no API for other apps to read or send direct messages
this way, and its terms forbid programs that act as its website. It may ask the person to confirm it is them, sign
the session out, lock the account, or restrict or suspend it. Uplink says so, and asks the person to agree, before
signing in.

X's direct messages are now X Chat: encrypted end to end, with the keys guarded by a 4-digit passcode the person
chose on x.com (the website asks for it in Messages). So signing in takes the passcode as well as the cookies
(PROTOCOL.md). The passcode opens the keys once; the keys are kept in `session.json` and the passcode is not. X allows
only a few wrong passcodes before it locks X Chat, so the helper never tries one twice by itself, and says how many
tries are left.

It is built on `pkg/twittermeow` (and `pkg/juiceboxgo`, for the passcode) of
[mautrix-twitter](https://github.com/mautrix/twitter) (v0.2609.0) by Tulir Asokan and contributors, under the GNU
Affero General Public License 3.0, and this helper's own source is under the same licence (LICENSE). keys.go follows
that project's connector for opening the keys. The licence asks that whoever is given the program can have its
source: SOURCE_URL is where it is published. No cgo: the session is a JSON file, not a database.

Uplink itself is a separate program: it starts this one (`twitter-sidecar --dir <folder>`) and talks to it
over its standard input and output, one JSON object a line (../ACCOUNT_HELPERS.md, and PROTOCOL.md for what is X's
own). The folder holds `session.json` (the cookies and the X Chat keys, readable by the person alone), `twitter.log`
and cached pictures (`avatars/`). Nothing a message says is logged; nothing but the protocol is written to standard
output.

Build (Go 1.26 or later):

    CGO_ENABLED=0 go build -trimpath -ldflags=-s -o twitter-sidecar .

It builds so for macOS, Linux, Windows and Android alike.

Test: `go test ./...`

## Not tried against X

Everything here was written from the library's source and is covered by tests only: of its pure parts (requests,
cookies, the session file and key store, opening sealed messages and group names with a known key, turning X's chats
and events into the protocol's shapes), and of `chats`, `history`, `send` and the live events driven against a
stand-in for X's servers that answers as the library expects. No part of it has yet been run against an X account.
The least sure parts: the passcode (Juicebox) itself, the live connection and catching up after it drops, sending
files (`send_media`), unencrypted X Chat chats, message requests, and read marks.

## Not yet

- Signing in without the X Chat passcode, or setting one up for an account that has none: the person sets it up on
  x.com first. Signing in with a username and password: cookies only.
- Chats from before X Chat that X has not moved over, and older history X keeps only in its previous API: only what
  X Chat gives is listed.
- `disconnected`: the library says when its live connection is made but not when it drops, so `connected` is said
  each time it connects and `disconnected` only when the session ends here.
- `delete` in X Chat's unencrypted chats: there X's website can only hide a message from the person, so it is an
  error rather than taking it back for everyone.
- `send_media` for anything but pictures, GIFs, videos and voice messages (X sends no other files); voice messages
  need ffmpeg on the device, as X wants them as MP4 files with a picture track. Files over 100 MB.
- `unread` counts only the others' messages X lists with the chat (its newest few) after the person's own read mark,
  so a long unread run shows as a small number.
- `chat` events for a chat removed on the website (logged; the protocol has no event for it), group pictures, and
  muted or pinned chats.
- Edits made from here, typing marks, starting a new chat, renaming, adding to or leaving a group, accepting or
  declining a message request on its own (answering one accepts it), marking unread.
- Link cards, mentions and other rich text in what is sent: the words go plain. In what arrives, a link card's
  address and a shared post's address are written into the words.
- Repairing a gap in a chat's history noticed on the live connection: the app's next `history` fills it.
