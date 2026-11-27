# Uplink's Slack helper: the protocol

The protocol is the one all of Uplink's account helpers share: [../ACCOUNT_HELPERS.md](../ACCOUNT_HELPERS.md).
This file says only what is Slack's own.

Run: `slack-sidecar --dir <folder>`. The folder holds `session.json` (mode 0600), `slack.log` and `avatars/`.

## Signing in

`sign_in`'s `cookies` needs, from a browser with the workspace open at app.slack.com:

- `d`: the cookie that is the browser's sign-in to Slack (`xoxd-…`). As the browser shows it (escaped, `%2F`) or not.
- `token`: not a cookie. The token the website's page holds for the workspace (`xoxc-…`), sent with every request
  Slack's website makes (it is in the `token` field of its requests to `/api/`, and in the page's local storage under
  `localConfig_v2`). Given beside the cookies under this name.

Any other slack.com cookies given (`d-s`, `b`, `lc`…) are passed along as the browser would send them. A missing one
of the two is an error naming it, as is a token that is not a browser session's (`xoxc-`) or a `d` that is not Slack's
sign-in (`xoxd-`). The session is the one workspace the token is for; a token copied with another workspace open is
that workspace. `unlink` forgets the session here and does not sign out at Slack, which would sign the browser out too.

## Ids

All strings:

- a chat: `<team>-<channel>`, the workspace's id and Slack's id of the channel, DM or group DM: `T0123ABCD-C0456EFGH`,
  `T0123ABCD-D0789IJKL`. A bare channel id is taken in requests too.
- a message: Slack's own id for it in its channel, its time: `1700000000.000100`.
- a person: Slack's user id (`U…` or `W…`), or for an app that posts without a user its bot id (`B…`). `me` is the
  person's own user id, so it equals the `from` of their own messages.
- `handle` is the member's Slack username, `name` the display name they chose (else their full name).

## Where Slack differs

- `chats`: the 20 with the newest messages, newest first. A channel's `title` is `#name`; a DM's is the other person's
  name; a group DM's the others' names. `group` is false only for a DM between two (a DM with yourself included).
- `history`: `before` is a message id; `before_ts` is taken and not needed (the id is the time). Pages are of 20, and
  `more` is Slack's own. The replies of threads begun on the page come with it (README.md, Threads).
- `send`: `quote` posts into the quoted message's thread; only its `id` is needed. Slack's live stream says your own
  sent message back as a `message` event with the same id. Words are sent as written (`<`, `>`, `&` are not markup).
- `send_media`: `text` is the words shared with the file; a `quote` puts it in that thread too.
- `read`: marks the chat read up to `upto`, or up to its newest message without one.
- `react`: `emoji` is an emoji, or a workspace emoji's `:name:`. Reactions come as emoji, or `:name:` for a workspace's
  own.
- `delete`: your own message, for everyone (Slack lets an admin delete others').
- `message`: `media[].pointer` is `{"file", "url", "kind"}` (`kind`: image, video, audio, file); `download` fetches it
  with the session, and asks Slack for a fresh address where the given one no longer works. A file kept outside Slack
  (a linked document) is its address in the words instead. `reactions` are given in `history`.
- `edited`: said when a message's words change (Slack also changes messages for a reply's count or a link's preview;
  those are not said). `deleted`: taken back, or a thread's first message deleted.
- `receipt`: only the person's own (`from` is `me`), read in Slack's own app; `id` is the message read up to.
- `name`: said for people met in messages and when someone changes their profile.
- `who`: answers for anyone in the workspace by id, asked of Slack.
- `people`: the workspace's members whose name or username has `query` in it (all for none), by name, 50 at most; no
  apps, nobody removed, not the person. Listed by users.list once every ten minutes (the first 1000 members), not at
  every asking. `avatar` is null: `who` gives one person's. `open`: the DM with `who` (conversations.open), made where
  there is none; nothing is sent. Neither has been tried against Slack itself.
- `avatar`: files under `avatars/`, named by a hash of the person and the picture's address; Slack's picture addresses
  need no session.

## Not supported

Nothing in the shared protocol is refused outright. What is partial is listed in README.md under "Not yet"; an op the
helper does not know is answered with an error.
