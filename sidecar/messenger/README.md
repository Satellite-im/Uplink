# Uplink's Messenger helper

A small program Uplink runs beside itself (on the phone and on a computer) to reach the person's Facebook
Messenger chats: the chats Messenger lists, their history, new messages as they come, sending words and files,
replies, reactions, unsending, read marks, people's names and pictures. It signs in with the cookies of a browser
already signed in to the account and then behaves as messenger.com does.

**Meta does not support or allow this.** Messenger has no way in for other apps, and Meta's terms do not permit
them. Meta may ask the person to confirm it is them (a "checkpoint"), sign the session out, or restrict or disable the
account. Uplink says so, and asks the person to agree, before signing in.

It is built on [mautrix-meta](https://github.com/mautrix/meta)'s `messagix` library by Tulir Asokan and contributors
(GNU Affero General Public License 3.0), and on [whatsmeow](https://github.com/tulir/whatsmeow) (MPL-2.0) for
end-to-end encrypted chats, which Meta runs over WhatsApp's protocol. This helper's own source is under the AGPL
too (LICENSE), and is public at the address in SOURCE_URL. The encrypted chats' keys are kept in SQLite: through
[mattn/go-sqlite3](https://github.com/mattn/go-sqlite3) (MIT) where built with cgo (the phone), through
[modernc.org/sqlite](https://gitlab.com/cznic/sqlite) (BSD) where not (the computers).

Uplink itself is a separate program: it starts this one (`messenger-sidecar --dir <folder>`) and talks to it
over its standard input and output, one JSON object a line (PROTOCOL.md, ../ACCOUNT_HELPERS.md). The folder holds
`session.json` (the cookies, messagix's connection state, the kinds of chats met; readable by the person alone),
`e2ee.db` (this device's keys for encrypted chats, the same), `messenger.log` and `avatars/`. Nothing a message says is
logged at info level; nothing but the protocol is written to standard output.

Each start loads Messenger's page afresh with the cookies, as opening the site does, then holds one live connection
(and a second one for encrypted chats). The page is loaded again every 20 hours.

Build (Go 1.26 or later):

    go build -trimpath -ldflags=-s -o messenger-sidecar .                 # with cgo: mattn/go-sqlite3
    CGO_ENABLED=0 go build -trimpath -ldflags=-s -o messenger-sidecar .   # without: modernc.org/sqlite
    CGO_ENABLED=1 CC=<ndk>/aarch64-linux-android29-clang GOOS=android GOARCH=arm64 \
      go build -trimpath -ldflags=-s -o libmessengersidecar.so .          # the phone's

Test: `go test ./...` (nothing in the tests reaches Meta).

## Not yet

- **Nothing here has been run against a real account.** It is written from mautrix-meta's bridge, builds, and its
  pure parts are tested with rows made by hand; signing in, the live connection and encrypted chats are untried.
- History of end-to-end encrypted chats: `history` answers with nothing for them (`"encrypted": true`). The app has
  what arrived while the helper was running.
- Sending files in encrypted chats (`send_media` says so). Stickers, shared posts, contact cards and view-once
  pictures in encrypted chats arrive as a line saying to open Messenger. Encrypted pictures, videos, sounds and
  documents do arrive, with a pointer `download` opens.
- Messages that came while the helper was not running are not said as `message` events: they show in `chat`
  (unread, last, snippet) and in `history`.
- The chats beyond the ones Messenger lists first (about twenty): `chats` does not page further.
- `unread` is exact only where Messenger gives a count; elsewhere it is 1 for "something waits".
- Read marks in ordinary chats are times, not messages: `receipt.id` is the newest message the helper has seen at
  or before that time, and empty where it has seen none (`ts` is always there).
- The connection state kept in `session.json` is not used to connect faster yet.
- Editing a sent message, typing marks, polls, mentions, creating chats, accepting a message request other than by
  answering it, blocking, and Marketplace or community threads as anything more than chats.
- View-once pictures in ordinary chats are left to Messenger, on purpose.
