# Uplink's Slack helper

A small program Uplink runs beside itself to reach the person's Slack messages in one workspace: signed in
with the session of a browser signed in to it, then the chats with the newest messages (channels, private channels,
direct messages and group DMs), their history, messages as they arrive, sending (words, replies in threads, files),
reactions, taking a message back, read marks, and the names and pictures of the people met.

**This is not an official Slack app.** It signs in with the token and cookie of the person's own browser session and
behaves as Slack's website does. Slack does not support other programs doing so. A workspace admin can see the session
and sign it out, and Slack may sign it out on its own; the person then signs in again. Uplink says so, and asks the
person to agree, before signing in.

It is built on [mautrix-slack](https://github.com/mautrix/slack) (v0.2611.0) by Tulir Asokan and contributors: its
Slack client, Beeper's fork of [slack-go](https://github.com/slack-go/slack) (which speaks to Slack with a browser
session and opens the website's live RTM stream), and its emoji table. The Matrix bridge itself is not used. Both are
under the GNU Affero General Public License 3.0, and this helper's own source is under the same licence (LICENSE). The
licence asks that whoever is given the program can have its source: SOURCE_URL is where it is published. No cgo: the
session is a JSON file, not a database.

Uplink itself is a separate program: it starts this one (`slack-sidecar --dir <folder>`) and talks to it over
its standard input and output, one JSON object a line (../ACCOUNT_HELPERS.md, and PROTOCOL.md for what is Slack's
own). The folder holds `session.json` (the token and cookies, readable by the person alone), `slack.log` and cached
pictures (`avatars/`). Nothing a message says is logged at info level; nothing but the protocol is written to standard
output.

Build (Go 1.26 or later):

    CGO_ENABLED=0 go build -trimpath -ldflags=-s -o slack-sidecar .

The go.mod replaces `github.com/slack-go/slack` with Beeper's fork, as mautrix-slack's own go.mod does; without it the
build fails.

Test: `go test ./...` (the protocol is driven against a stand-in for Slack's API, file host and live stream, on this
computer; nothing reaches Slack).

## Threads

Slack keeps a thread's replies apart from its channel; the protocol has no threads. So a reply in a thread is put in
the chat like any message, with a `quote` of the thread's first message (its id, and its words where the helper has
seen it). Sending with a `quote` posts into the quoted message's thread: the thread it is in, or a new one under it.

- `history` gives a page of the channel's own messages and, beside them, the replies of up to 10 threads begun on that
  page (the first 100 replies of each), all oldest first. A reply can be newer than the page it came with.
- Live, a reply arrives as a `message` with its quote. A reply also sent to the channel ("Also send to #channel") is
  one message, quoting its thread's first message too.
- `read` up to a reply marks its thread read, and the chat read up to the newest of the channel's own messages at that
  time.

## Not tried against Slack

Everything here was written from the library's source and is covered by tests against a stand-in for Slack that
answers as the library expects (requests, the token and cookie, the session file, every op, the live stream's
messages, edits, deletions, reactions and read marks, and a session Slack signs out). No part of it has yet been run
against a real Slack workspace. The least sure parts: that Slack takes a session copied from a browser without the
website's other headers, the live stream's connection and reconnection, Enterprise Grid workspaces and channels
shared with other organisations, sending files (`send_media`), and how unread counts read in channels.

## Not yet

- `chats` gives the 20 chats with the newest messages, in the order of Slack's sidebar; any other chat is said as a
  `chat` when a message comes in it, and `history` works for any chat id.
- A channel's `members` are not listed (there can be thousands); a DM's and a group DM's are.
- `unread` is a count in DMs and group DMs (Slack counts each of their messages as a mention); in a channel it is 1
  when anything is unread, or the number of mentions where that is more.
- `receipt` is only the person's own reads in Slack's own apps: Slack tells no one else's, and nothing of delivery.
- `send_media`: Slack decides what kind of file it is (`mime` is taken and not used). Where Slack has not shared the
  file into the chat within a few seconds, the answer's `id` is empty and the message arrives from the live stream.
- A workspace's own emoji (pictures) are given as `:name:`, in words and in reactions; the same `:name:` reacts with one.
- Bold, italics, code and quotes are given as Slack writes them (`*bold*`, `_italic_`); a message made only of rich
  blocks or attachments is given by the words Slack keeps beside them.
- Edits made from here, typing marks, starting a new chat, joining, leaving or renaming a channel, and huddles. A chat
  left on Slack is logged and the app not told (the protocol has no event for it).
- More than one workspace in a session: a session is the workspace the token is for. Another workspace is another
  sign-in, with that workspace's token.
- Signing in with an email, a password, or a Slack app's token: a browser session only.
