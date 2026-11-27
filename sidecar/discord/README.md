# Uplink's Discord helper

A small program Uplink runs beside itself to reach the person's Discord direct messages and groups: signed
in with the token of a browser signed in to their account, then their chats, the history of each, messages as they
arrive, sending (words, replies, pictures and files), reactions, deleting your own message, read marks, and the
names and pictures of the people met.

**Discord does not allow this, and may disable the account.** Discord's terms forbid automating a user account
(it calls these "self-bots"): a program signed in as a person rather than as a bot. Discord may ask the person to
verify the account, sign the session out, or disable the account for good. Uplink says so, and asks the person to
agree, before signing in.

It is built the way [mautrix-discord](https://github.com/mautrix/discord) (v0.7.7) by Tulir Asokan and contributors
signs in as a person: on beeper's fork of [discordgo](https://github.com/bwmarrin/discordgo) (BSD licence), which
identifies to Discord's gateway as its website does in Chrome, with Chrome's TLS handshake through beeper's fork of
`req`. The Chrome transport (`compileTransport` in client.go) is mautrix-discord's own code, under the GNU Affero
General Public License 3.0, and this helper's own source is under the same licence (LICENSE). The licence asks that
whoever is given the program can have its source: SOURCE_URL is where it is published. Matrix and mautrix-discord's
bridge are not used. No cgo: the session is a JSON file, not a database.

Uplink itself is a separate program: it starts this one (`discord-sidecar --dir <folder>`) and talks to it
over its standard input and output, one JSON object a line (../ACCOUNT_HELPERS.md, and PROTOCOL.md for what is
Discord's own). The folder holds `session.json` (the token, readable by the person alone), `discord.log` and cached
pictures (`avatars/`). Nothing a message says is logged; nothing but the protocol is written to standard output.

Build (Go 1.26 or later):

    CGO_ENABLED=0 go build -trimpath -ldflags=-s -o discord-sidecar .

Test: `go test ./...`

## Signing in

`sign_in` is given `cookies`, as for the other helpers, with one entry named `token`: the account's token, from
discord.com in a browser signed in to the account (the website keeps it in its own storage, not in a cookie). Any
real cookies given beside it are taken and not used. A token missing, a bot's token, or one Discord refuses is an
error saying so. `unlink` forgets the token here and does not sign out at Discord, which would sign the browser out
too; changing the account's password ends every token.

## Server channels

A person in a few servers can read hundreds of channels, so `chats` lists direct messages and groups only. A
server's text channel becomes a chat (`guild:<server id>:<channel id>`, `group` true, titled `Server › #channel`):

- when a message in it mentions the person or answers one of theirs (that message's `chat` event comes first), or
- when the app asks for its `history` by that id.

From then on, for the rest of the run, its new messages, edits, deletions and reactions are passed on as for any
chat. Everything else in servers is passed over.

## Not tried against Discord

Everything here was written from the library's source and mautrix-discord's, and is covered by tests that drive the
protocol against a stand-in for Discord (main_test.go): signing in, chats, history, sending, files, reactions,
deleting, read marks, downloads with an address that has run out, `who`, and the live events. Against Discord
itself only a refused sign-in has been run (a made-up token: the website's page, Chrome's handshake and the gateway
answered as expected, and the helper said "Discord did not take that token"). Nothing has yet been run signed in to
a real account. The least sure parts: sending files (`send_media`, Discord's upload-then-attach flow), which server
messages Discord sends a person's session without the website's own subscriptions to a server (see below), the
unread counts, and whether Discord asks for a captcha when sending to someone new from here.

## Not yet

- Edits made from here: the protocol has no op for it. Edits made elsewhere are said (`edited`).
- Server channels listed in `chats`, and following a server's channels as the website does (it subscribes to each
  server it shows; this helper does not, so in large servers Discord may send nothing until a message mentions the
  person, and some such messages may not arrive at all).
- Threads and forum posts: their messages are passed over.
- Reactions by others already on the messages of `history`: Discord says only how many there are, so only the
  person's own are given. Reactions made while connected are said (`reaction`), others' included.
- `receipt` from others: Discord does not tell anyone when others have read a message. Only the person's own reads
  in Discord's own app are said.
- A server's own emoji as a reaction is sent only given as `name:id` or `<:name:id>`; `:name:` alone is refused.
- Starting a new direct message, typing marks, calls, voice messages as such (they arrive as audio files),
  stickers drawn as Discord's own animations (Lottie), embeds and link previews, polls, pins.
- Bold, links, spoilers and other Markdown in a message: the words are given as written, with mentions turned into
  names and a server's own emoji into `:name:`.
- Signing in with an email and a password, or with the website's QR code: the token only.
