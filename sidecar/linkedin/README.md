# Uplink's LinkedIn helper

A small program Uplink runs beside itself to reach the person's LinkedIn messages: signed in with the
cookies of a browser signed in to their account, then the inbox's conversations, their history, messages as they
arrive, sending (words, replies, pictures and files), reactions, taking a message back, read marks, and the names
and pictures of the people met.

**LinkedIn does not support this, and does not allow it.** LinkedIn has no API for other apps to read or send
messages, and its terms forbid programs that act as its website. It may ask the person to confirm it is them, sign
the session out, or restrict the account. Uplink says so, and asks the person to agree, before signing in.

It is built on `pkg/linkedingo` of [mautrix-linkedin](https://github.com/mautrix/linkedin) (v0.2611.0) by Sumner
Evans and contributors, under the GNU Affero General Public License 3.0, and this helper's own source is under the
same licence (LICENSE). The licence asks that whoever is given the program can have its source: SOURCE_URL is where
it is published. No cgo: the session is a JSON file, not a database.

Uplink itself is a separate program: it starts this one (`linkedin-sidecar --dir <folder>`) and talks to it
over its standard input and output, one JSON object a line (../ACCOUNT_HELPERS.md, and PROTOCOL.md for what is
LinkedIn's own). The folder holds `session.json` (the cookies, readable by the person alone), `linkedin.log` and
cached pictures (`avatars/`). Nothing a message says is logged; nothing but the protocol is written to standard
output.

Build (Go 1.26 or later):

    CGO_ENABLED=0 go build -trimpath -ldflags=-s -o linkedin-sidecar .

Test: `go test ./...`

## Not tried against LinkedIn

Everything here was written from the library's source and is covered by tests of its pure parts only (requests,
cookies, the session file, turning LinkedIn's conversations and messages into the protocol's shapes). No part of it
has yet been run against a LinkedIn account. The least sure parts: sending files (`send_media`), the chat of a
reaction or a read mark on a message this run has not seen, and replies quoting such a message.

## Not yet

- `who` for someone not yet met: LinkedIn's messaging has no lookup by id here, so a person is known only once a
  chat or a message of theirs has been listed in this run; before that `who` is an error.
- `send_media` for voice messages and videos as such: every file that is not a picture goes as a file attachment.
- `read` up to a message, and marking unread: LinkedIn marks a whole conversation read.
- `unread` as a count: LinkedIn says only read or not, so it is 0 or 1.
- Reactions already on the messages of `history` (only those made while connected are said, as `reaction` events).
- Edits made from here, typing marks, starting a new chat, renaming or leaving a group, deleting a conversation
  (a conversation deleted on the website is logged and the app not told: the protocol has no event for it).
- Bold, links and mentions in a message: the words are given plain.
- Signing in with an email and a password: cookies only.
