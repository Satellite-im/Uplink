# Other apps' direct messages in Uplink

Matt, 2026-11-15: "pick up the other sessions question about proxying direct messages from other apps like discord,
slack, telegram through our app and being able to reply via an API, i'm not sure which services allow this so look
into it and do some research". Read on 2026-11-15; anything marked
**unverified** wants a look at the source before building on it. Telegram and Bluesky are now built (below).

## Built: Telegram and Bluesky (2026-11-15)

Matt: "Let's build in telegram and bluesky for now, since we can't send outbound messages anything without the
ability to back and forth is useless". Both read and send.

| Part | Where |
| --- | --- |
| The model: a network, its chats, a chat's messages, sending | `lib/inbox/inbox.dart` |
| Bluesky: handle + app password (DMs allowed) → the account's PDS → `chat.bsky.convo.*` through the chat proxy; asked every 20 s, the open chat every 4 s | `lib/inbox/bluesky.dart` (`test/inbox_bluesky_test.dart`) |
| Telegram: TDLib signed in by number, code and two-step password; private chats and groups (not channels) in Telegram's order; history, sending, read | `lib/inbox/telegram.dart` (`test/inbox_telegram_test.dart`) |
| TDLib's four C functions, one receiving isolate for the whole app (TDLib aborts if `td_receive` runs on two threads) | `lib/inbox/td_json.dart` |
| TDLib itself, from github.com/tdlib/td at a pinned commit (and OpenSSL from its source for Android), not a prebuilt package | `tool/build-tdlib.sh mac` / `android`, run by the release scripts; `build/tdlib/` |
| A tab per signed-in network beside Messages and Voice (Telegram's paper plane, Bluesky's cloud), the chat page, sign-in pages, Settings › Telegram / Bluesky | `lib/ui/inbox_ui.dart`, `lib/ui/conversations.dart` (`test/inbox_screens_test.dart`, `test/shots/16-inbox-*`) |

**Bluesky is "Coming soon" for now** (Matt, 2026-11-15: "I don't have bluesky setup yet, set that to \"coming soon\""):
built and tested, but `Bluesky(soon: true)` in `Inbox.instance` keeps it from starting, from the list's tabs and from
signing in; Settings › Bluesky says Coming soon. Taking out `soon: true` turns it on.

Every network runs on the device (phone and computer each sign in for themselves, as Telegram's and Bluesky's own
apps do); nothing goes through ghost-sms.com.

**Telegram needs Matt's app id before it works in a release** (Telegram's terms: one per developer, never the
sample ones): my.telegram.org › API development tools › create an app, then put the two values in
`~/.config/ghostmessaging/telegram.env` (`chmod 600`), one a line:

    TELEGRAM_API_ID=1234567
    TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef

`tool/release.mjs` and `tool/release-mac.mjs` pass them as `--dart-define`s (`tool/telegram-defines.mjs`; never
printed, never committed). Without the file Telegram shows "isn't in this build" and Bluesky works regardless.

Not yet: pictures and other media (shown as "Photo", "Voice message"…), avatars (initials), Windows and Intel Macs for
Telegram (TDLib is built for Android arm64 and Apple silicon), notifications when the app is closed, the computer
using the phone's sign-in.

## Built: Messenger, Instagram and LinkedIn (2026-11-20)

Matt, asked which other popular platforms could be added and told these three were feasible "the same way as
WhatsApp (unofficial, needs a warning)": "Let's do the feasible ones but skip X and google voice".

None of the three has an API a personal account's own app may use. Each is reached as its website is: a helper
process signs in **with the cookies of a browser signed in to the account** and speaks the service's own web
protocol, through the open-source bridges' client libraries (AGPL-3.0, as this app is):

| Service | Helper | Library | Cookies needed |
| --- | --- | --- | --- |
| Messenger | `sidecar/messenger` | mautrix-meta `pkg/messagix` | `xs`, `c_user`, `datr` (messenger.com or facebook.com) |
| Instagram | `sidecar/instagram` | mautrix-meta `pkg/instameow` (that project moved Instagram off messagix in 2026) | `sessionid`, `csrftoken`, `ds_user_id` |
| LinkedIn | `sidecar/linkedin` | mautrix-linkedin `pkg/linkedingo` | `li_at`, `JSESSIONID` |

| Part | Where |
| --- | --- |
| The protocol the three helpers share (JSON lines, as WhatsApp's) | `sidecar/ACCOUNT_HELPERS.md`; each helper's own `PROTOCOL.md` and `README.md` say what is particular to it and what it does not do yet |
| One class in the app for all three: the helper run as a child process, sign-in, chats, messages, history asked for as a chat is scrolled, sending, reactions, read, files | `lib/inbox/account_helper.dart` (`test/inbox_account_helper_test.dart`, against a stand-in helper) |
| What is pasted read as cookies (a copied request, a header, pairs, JSON) | `lib/inbox/cookie_paste.dart` |
| Signing in: the warning, agreed to first; then a private window, Copy as cURL, paste | `lib/ui/inbox_signin_helper.dart` (`test/inbox_helper_screens_test.dart`, `test/shots/helper-*`) |
| Their marks, Settings › Connections rows and pages | `lib/ui/me.dart` (`NetworkMark`), `lib/ui/inbox_ui.dart` |
| Building a helper for a Mac, Linux, Windows or the phone | `tool/build-accountsidecar.sh <name> <mac\|linux\|windows\|android>`; the Mac's and the phone's releases carry them (`tool/release-mac.mjs`, `tool/release.mjs`) |

**The warning.** Before anything is asked of the service the person is told, and must agree, that it does not
support or allow other apps, that Uplink signs in as them with a browser's session, and that the service may ask them
to confirm it is them, sign that session out, or restrict the account. The same stands on each one's page of
Settings. This is the same footing as WhatsApp.

**Messenger's encrypted chats.** Most one-to-one Messenger chats are end-to-end encrypted. The helper reads and
writes them as mautrix-meta does: it registers as another device of the account (kept in `e2ee.db`), which
Messenger lists among the person's devices, and the warning says so. Encrypted messages from before signing in are
not fetched, and encrypted files cannot be sent yet.

**What is kept where.** The cookies are given to the helper on the device and kept by it alone (`session.json` in
the app's own folder, readable by the person only); the app keeps the chats and the newest 400 messages of each
(`chats.json`). Nothing goes through Uplink's servers.

**Not tried against real accounts.** Everything here was built and tested against stand-ins and the libraries' own
types: no sign-in was made to any of the three. The first real sign-in on each is the test of it, as it was for
every network before. Known limits are each helper's README "Not yet" list.

**Where it runs.** A Mac and the phone carry the helpers from the next release. Windows and Linux builds do not
carry them yet (they say "Not in this build" there): the helpers cross-build for both
(`tool/build-accountsidecar.sh <name> windows|linux`), and their workflows are to be taught to.

## The short answer

There are two ways in, and they cover different apps:

1. **The phone's own notifications (any app, no API).** Android lets an app with *notification access* read the
   notifications other apps post and press their **Reply** action (the same `RemoteInput` that Wear OS, Android Auto
   and the shade's inline reply use). Discord, Slack, WhatsApp, Instagram, Messenger, Signal, Teams and Telegram
   all post a message notification with a Reply action. Uplink would show those messages and send replies through
   the other app itself, signed in as you, with no keys, no servers and nothing against those apps' terms (no token
   is taken, no client is faked). Limits below.
2. **Real APIs, where a service allows a third-party client.** Telegram, Mastodon, Bluesky and Matrix do, fully.
   Slack does, awkwardly. X does, for money. Discord, WhatsApp, Instagram/Messenger, Signal and iMessage do not.

**Recommendation:** build (1) first: one feature that brings most apps at once, and the only lawful way to Discord,
WhatsApp and Instagram. Then add (2) for **Telegram** (full history, media, works with the phone away) and
**Mastodon/Bluesky** (small, open APIs, and already in Settings › Me). Leave Slack, X and the rest out unless asked.

## Service by service

| Service | Read and reply to *your* DMs via an API? | How | Catch |
| --- | --- | --- | --- |
| **Telegram** | **Yes, fully** | TDLib (Telegram's own client library) with our own `api_id` from my.telegram.org; it is a complete client: history, media, groups, live updates | Must follow the API Terms; accounts on unofficial clients are "put under observation"; one `api_id` per phone number; the sample id is refused for releases |
| **Mastodon** | **Yes** | REST API: direct messages are statuses with `visibility: direct`; `/api/v1/conversations`; streaming for live | Per instance OAuth app (registered on the fly); fine |
| **Bluesky** | **Yes** | `chat.bsky.convo.*` (listConvos, getMessages, sendMessage) through the chat service proxy; OAuth, or an app password made **with DM access ticked** | Text only (images not in DMs); the `bluesky` Dart package already has `BlueskyChat` |
| **Matrix** | **Yes** | Client-server API; any homeserver | Few people Matt knows are on it, except via bridges |
| **Slack** | **Yes, but** | A Slack app with *user* token scopes (`im:history`, `im:read`, `chat:write`); Events API `message.im` for live messages | Each workspace must allow the app (many admins block it); since 2025 a non-Marketplace app gets `conversations.history` at about **1 request a minute, 15 messages a time** (existing installs from 3 March 2026), so history is crippled unless the app is approved for the Marketplace; live events are not throttled the same way |
| **X** | Yes, **paid** | DM endpoints need the top permission level; pay-per-use since February 2026 | About $0.005 a DM call reported (**unverified**); the free tier is gone for new developers |
| **Discord** | **No** | Bots see only DMs sent *to the bot*; using a person's account ("self-bot", user token) is forbidden and gets accounts banned | Notifications (1) are the only way |
| **WhatsApp** | **No** (for us) | No personal-account API (the Business API is for business numbers). EU interoperability under the DMA exists since November 2025, but only for services Meta signs as partners (BirdyChat, Haiket), in the EU, with their encryption requirements | Unofficial libraries (whatsmeow etc.) break the terms and get numbers banned. Notifications (1) |
| **Instagram / Messenger** | **No** | Messenger Platform and the Instagram API are for business pages and accounts | Notifications (1) |
| **Signal** | **No** | No API. `signal-cli` can link as a device using Signal's own protocol, unofficially | Notifications (1) is cleaner |
| **iMessage** | **No** | Nothing official | n/a on Android anyway |
| **Google Chat / Teams** | Yes, in work accounts | Google Chat API / Microsoft Graph with delegated scopes | The organisation's admin must consent; not a personal-chat thing |

## How (1), notifications, would work

- A `NotificationListenerService` in the Android app; the person turns on notification access once (Android's own
  switch, not a runtime permission), and chooses which apps Uplink may read.
- A posted notification with `MessagingStyle` gives the sender, the conversation, the recent messages and whether
  it is a group. Each conversation becomes a row in Uplink marked with the app it came from.
- **Reply**: the notification's action with a `RemoteInput` is filled in and sent (`RemoteInput.addResultsToIntent`
  and the action's `PendingIntent`). **Mark read** is the action too, where the app gives one. The other app sends
  it, as you.
- The Mac gets these through the existing desk link, as it gets texts.

What it cannot do, and must say plainly:

- **Only what arrives as a notification**: no history before Uplink was set up, nothing from a muted chat, nothing
  while the other app's notifications are off or it is open on screen.
- **Reply only while the notification is there**: once it is dismissed (or read elsewhere) there is no Reply action
  until the next message. Uplink can still show the conversation; replying then means opening the other app.
- **Pictures and voice** mostly do not come through; some apps put a picture in the notification, most only "Photo".
- **Phone only**: the phone must be on and have the other apps installed and signed in.
- **Google Play**: notification access is a sensitive capability, and a Play listing must justify it as a core
  feature (**unverified** which declaration it needs today; check Play Console's permissions declaration before a
  Play build). The sideloaded and Mac builds are not affected.
- Uplink already reads its own SMS; this reads *other* apps' messages, so it should be off by default, per app, with
  a clear page saying what is read and that nothing leaves the phone except to the paired Mac.

## How (2) would fit

- Run each client **on the phone, not on the relay server**: TDLib, Mastodon and Bluesky all work from the device,
  so tokens and messages never touch ghost-sms.com, matching how Settings › Me keeps nothing on the server. The
  relay only matters if the Mac is to work with the phone away, which can come later.
- Telegram: TDLib has to be built for Android (and macOS) and wrapped (there are Dart bindings, e.g. `tdlib`
  packages, **unverified** which is maintained). Our `api_id` is Matt's to register (my.telegram.org, his number);
  it is not the bot token that Settings › Me's Telegram sign-in uses.
- Mastodon and Bluesky can reuse the accounts already linked in Settings › Me, asking for more scope (DMs) when
  the person turns the inbox on.

## Questions for Matt

1. Notifications first (most apps, today's messages only), or Telegram first (one app, done properly)?
2. Should other apps' conversations mix into the main list, or sit in their own section (as Codes and the plugins
   do), marked with each app's logo?
3. Is a Play-store build in scope for this (it decides how careful the notification-access page must be)?

## Sources

- Slack rate limits for non-Marketplace apps: https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps
  and https://api.slack.com/changelog/2025-05-terms-rate-limit-update-and-faq
- Slack user-token scopes (im:history): https://dev.to/sapotacorp/slack-bot-token-vs-user-token-scopes-least-privilege-in-practice-gj4
- X pay-per-use: https://opentermsarchive.org/en/memos/x-replaces-its-dollar200-entry-level-api-plan-with-a-pay-per-use-model/
  and https://postproxy.dev/blog/x-api-pricing-2026
- WhatsApp interoperability: https://about.fb.com/news/2025/11/messaging-interoperability-whatsapp-enables-third-party-chats-for-users-in-europe/
- Discord on self-bots: https://support.discord.com/hc/articles/115002192352
- Bluesky DMs: https://atp.readthedocs.io/en/latest/dm.html and https://pub.dev/documentation/bluesky/2.15.5/
- Telegram API terms and api_id: https://core.telegram.org/api/terms and https://core.telegram.org/api/obtaining_api_id
- Android notification listener and direct reply: https://developer.android.com/reference/android/service/notification/NotificationListenerService
  and https://android-developers.googleblog.com/2016/06/notifications-in-android-n.html
