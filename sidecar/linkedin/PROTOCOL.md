# Uplink's LinkedIn helper: the protocol

The protocol is the one all of Uplink's account helpers share: [../ACCOUNT_HELPERS.md](../ACCOUNT_HELPERS.md).
This file says only what is LinkedIn's own.

Run: `linkedin-sidecar --dir <folder>`. The folder holds `session.json` (mode 0600), `linkedin.log` and `avatars/`.

## Cookies

`sign_in` needs, from a browser signed in at linkedin.com, at least:

- `li_at`: the sign-in itself.
- `JSESSIONID`: sent back to LinkedIn with every request. With or without the quotes the browser shows round it.

Any other linkedin.com cookies given are passed along as the browser would send them (`bcookie`, `lidc`, `liap`…);
giving them all makes the session look most like the browser's. A missing one of the two is an error naming it.
`unlink` forgets the session here and does not sign out at LinkedIn, which would sign the browser out too.

## Ids

All are LinkedIn's URNs, as strings, passed back unchanged:

- a chat: `urn:li:msg_conversation:(urn:li:fsd_profile:<own profile>,<thread>)`
- a message: `urn:li:msg_message:(urn:li:fsd_profile:<own profile>,<message>)`
- a person: `urn:li:msg_messagingParticipant:urn:li:fsd_profile:<profile>` (a company page or one of LinkedIn's own
  senders has another word in place of `fsd_profile`). `me` is written the same way, so it equals the `from` of
  the person's own messages.
- `handle` is the name in `linkedin.com/in/<name>`, empty where LinkedIn gives none.

## Where LinkedIn differs

- `history`: LinkedIn pages by time, not by message. `before` (a message id) works for any message this run has
  passed on; for an older one the helper reads back from the newest (up to 300 messages) to find it. Sending the
  optional `before_ts` (that message's `ts`) beside `before` saves that. Pages are of 20; `more` is true whenever
  the page had anything in it, so the last page is an empty one.
- `send`: `quote` may also carry `author` (the quoted message's `from`), `ts` and `text`, used where this run has
  not seen the quoted message (LinkedIn wants all three). Without them such a message is sent without its quote.
  Sending into a message request accepts it. LinkedIn's live stream says your own sent message back as a `message`
  event with the same id.
- `read`: marks the whole conversation read; `upto` is taken and not needed.
- `chat`: `unread` is 0 or 1 (LinkedIn says read or not). Only the inbox is listed: not spam, archived or "other".
- `message`: `media[].pointer` is `{"url", "kind", "expires"}` (`kind`: image, gif, file, audio, video). The
  addresses are signed and run out; a `download` after that is an error saying so, and `history` gives fresh ones.
  A picture's and a voice message's `mime` is asked of LinkedIn as the message is passed on; where it does not
  answer, `image/jpeg` and `audio/mp4` (what its website makes) are given.
- `edited`: said when a message's words change. `deleted`: the sender took it back. `receipt`: `kind` is always
  `read` (LinkedIn says nothing of delivery to others).
- `who`: answers only for people already met in a chat or a message of this run (README.md, Not yet).
- `avatar`: files under `avatars/`, named by a hash of the person and the picture; LinkedIn's picture addresses
  need no cookies.

## Not supported

Nothing in the shared protocol is refused outright. What is partial is listed in README.md under "Not yet"; an op
the helper does not know is answered with an error.
