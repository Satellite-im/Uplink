# Uplink's Instagram helper

A small program Uplink runs beside itself (on the phone and on a computer) to reach the person's Instagram
direct messages: the inbox, a thread's history, new messages as they arrive, pictures, videos and voice messages,
shared posts, reels and stories (as a line of words with their link), replies, reactions, edits, unsends and seen marks.

**Instagram does not support or allow this.** Instagram has no way in for other apps to a person's messages. This
helper signs in as the person, with the cookies of a browser signed in to instagram.com, and behaves as the website
does. Instagram may ask the person to confirm it is them, sign the session out (the browser's too), or restrict the
account. Uplink says so, and asks the person to agree, before signing in.

It is built on `pkg/instameow` of [mautrix-meta](https://github.com/mautrix/meta) (v0.2611.0) by Tulir Asokan and
contributors, the library that project's own Instagram bridge uses since 2026, under the GNU Affero General Public
License 3.0. This helper's own source is under the same licence (LICENSE); where it is published is in SOURCE_URL.
The bridge itself (`pkg/igconnector`, Matrix, its database) is not used; instameow brings a few of mautrix-go's
packages along as its own dependencies. The helper is pure Go: no C, no SQLite.

Uplink itself is a separate program: it starts this one (`instagram-sidecar --dir <folder>`) and talks to it
over its standard input and output, one JSON object a line: the protocol all of Uplink's account helpers share
(../ACCOUNT_HELPERS.md), with Instagram's particulars in PROTOCOL.md. The folder holds `session.json` (the cookies,
which are the sign-in: readable by the person alone, mode 0600), `instagram.log` and `avatars/`. Nothing a message
says is logged.

Only the cookie sign-in is here. Signing in with a password, and Instagram's phone-app sign-in, are in the library
and deliberately not used.

Build (Go 1.26 or later; no cgo needed):

    CGO_ENABLED=0 go build -trimpath -ldflags=-s -o instagram-sidecar .

The phone's: `GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC=<NDK>/aarch64-linux-android29-clang go build …` (Go links
Android programs through the NDK's clang even with no C in them).

Test: `go test ./...` (the pure parts; nothing in the tests reaches Instagram).

## Not yet

- **Never run against a real account.** It builds, and its shapes are tested against hand-built values and the
  library's own JSON types, but no request of it has yet been answered by Instagram.
- Sending files (`send_media`) is written as the bridge does it (the website's upload, then a media message) and is
  the least certain part. Videos that some accounts cannot upload from the website are refused in words: the bridge
  falls back to Instagram's phone-app upload there, which this helper does not do.
- The inbox beyond its first page (about twenty threads). An older thread appears when a message arrives in it.
- Message requests and the hidden folder; starting a chat with someone new; searching for people.
- Editing a sent message; typing notices; marking a thread unread; muting, pinning, deleting or leaving a thread;
  naming a group, its picture and its people.
- Seen-once pictures and videos: said in words, never fetched (seeing one is an act Instagram counts).
- Mentions are plain words; a reply's quoted words are there only where Instagram sends them with the message.
- `delivered` receipts: Instagram tells only of `read`.
- What happened while the helper was not running is not replayed as events; the inbox and `history` show it.
- A file's size is not known before it is fetched, and its type is read from its address (PROTOCOL.md).
