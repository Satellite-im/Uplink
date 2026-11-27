# Uplink's X helper: the protocol

The protocol is the one all of Uplink's account helpers share: [../ACCOUNT_HELPERS.md](../ACCOUNT_HELPERS.md).
This file says only what is X's own.

Run: `twitter-sidecar --dir <folder>`. The folder holds `session.json` (mode 0600), `twitter.log` and `avatars/`.

## Signing in

`sign_in` needs, from a browser signed in at x.com, at least these cookies:

- `auth_token`: the sign-in itself.
- `ct0`: sent back to X with every request (its CSRF token).

`twid` (which account the cookies are for) is wanted too: X sets it again when its messages page loads, and where it
does not, the sign-in is an error asking for it. Any other x.com cookies given are passed along as the browser would
send them (`guest_id`, `kdt`, `personalization_id`…); giving them all makes the session look most like the
browser's. Quotes round a value are taken off. A missing one of the two is an error naming it.

It also needs one field the shared protocol does not have:

    {"id":2,"op":"sign_in","cookies":{"auth_token":"…","ct0":"…","twid":"…"},"passcode":"1234"}

`passcode` is the person's 4-digit X Chat passcode, which opens the keys of their encrypted chats. Without it the
sign-in is an error saying so, before anything is asked of X. A wrong one is an error saying how many tries X has
left before it locks X Chat; the helper never retries it. An account with no passcode yet is told to set one up at
x.com/messages. The passcode is not kept; the keys it opens are, in `session.json`.

`unlink` forgets the session and the keys here and does not sign out at X, which would sign the browser out too.

## Ids

All are X's own, as strings, passed back unchanged:

- a chat: `<user id>:<user id>` for two people (in the order X writes them), `g<number>` for a group. The older
  `<id>-<id>` form is taken too, and turned into the first.
- a message: X Chat's sequence id, a decimal number (it grows with time).
- a person: X's numeric user id. `me` is the person's own, so it equals the `from` of their own messages.
- `handle` is the username, without the `@`.

## Where X differs

- `history`: pages back from `before` (a message id); `before_ts` is taken and not needed. A page is up to 50 of X
  Chat's events, and reactions, edits and take-backs are events too, so it holds up to 50 messages. Reactions, edits
  and take-backs on the same page are already applied: `reactions` lists those still there, an edited message has
  its newest words, a message taken back is left out. `more` is false on the last page.
- `send`: `quote` may also carry `author` (the quoted message's `from`) and `text`, used where this run has not seen
  the quoted message. Sending into a message request accepts it. X's live connection says your own sent message back
  as a `message` event with the same id.
- `send_media`: pictures, GIFs, videos and voice messages only (X sends no other files). A voice message is made into
  an MP4 file with ffmpeg, which must be installed. `text` goes with the file as its caption.
- `read`: up to `upto`, or, without it, up to the newest message of the chat this run has seen.
- `react`: `emoji` is any emoji. `delete`: takes your own message back for everyone, in encrypted chats (all of X
  Chat's but a few); elsewhere an error.
- `chat`: `unread` is how many of the others' messages X lists with the chat come after the person's read mark (a
  message of their own counts as reading). Message requests are listed with the rest.
- `message`: `media[].pointer` is `{"conv","hash","key_version","kind"}` for X Chat's files (sealed with the chat's
  key: `download` opens them) or `{"url","kind"}` for older ones on X's own addresses (`kind`: image, gif, video,
  audio). `mime` comes from the file's name where X gives one, else the kind X's website makes. A link card's and a
  shared post's addresses are written into `text`.
- `edited`, `deleted`, `reaction`: as they happen. `receipt`: `kind` is always `read`, with `ts` where X says when.
- `who`: asks X for anyone by id.
- `avatar`: files under `avatars/`, named by a hash of the person and the picture's address; X's picture addresses
  need no cookies.
- `connected` is said each time the live connection is made; `disconnected` only when the session ends here (README.md).

## Not supported

Nothing in the shared protocol is refused outright except what README.md lists under "Not yet"; an op the helper does
not know is answered with an error.
