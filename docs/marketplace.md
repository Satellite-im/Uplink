# The Marketplace and plugins from other developers

Matt, 2026-11-20: "This is a lengthly feature request, I would like users to be able to develop and submit their own
plugins to our plugin marketplace and I'd like to be able to verify them for the store through a review process.
Please include documents on how users can develop plugins, please add a developer setting for users to be able to
manually upload plugins for development testing and a listing process. Move plugins out of settings into a marketplace
button on the navigation rail with a marketplace icon. Add a submission area with a form to accept an icon,
description, plugin tags, etc".

A plugin from another developer is a **pack**: one file of JSON in the format `ghost-plugin/1`, holding its manifest
and its rules and nothing that runs. The app compiles a pack into the extension points its built-in plugins already
use (tags, sections, rows, buttons, incoming rules, settings), and finds words with a phrase language of its own in
place of regular expressions. Packs are sent for review to a store on the relay (`/market`); Matt reviews them in the
app's admin page, and an approval is his device's signature over the exact file, which every build checks with the
keys pinned in its code when the pack is added and every time the app starts. Plugins left Settings for a
**Marketplace** ring on the rail; Settings › Developer gained **Plugins in development**. Not released; nothing of it is
deployed.

| Part | Where | What |
| --- | --- | --- |
| Packs | `lib/plugins/pack/` | The format and its checks (`format.dart`, `manifest.dart`, `canonical.dart`, `png.dart`), the phrase language (`phrases.dart`), a pack as a plugin (`pack_plugin.dart`) and the host its buttons run through (`gated_host.dart`), approvals, withdrawals and retirements (`review.dart`) and the keys this build trusts (`review_keys.dart`), what is installed and loaded (`installed.dart`), Try it and the lints (`trial.dart`) |
| The store | `relay/lib/market.dart`, `market_pack.dart`, `market_store.dart` | `/market` on the relay: the routes, signed requests and limits; the relay's own checks of a pack; the records, files and the daily sweep |
| The Marketplace and review | `lib/ui/market/`, `lib/market/`, `lib/ui/plugins_page/`, `lib/ui/admin_page.dart` | The ring's place and its sections, Discover, Added and Updates, Submit a plugin, My submissions, Plugins in development (`dev_plugins.dart`), the review queue, an item and reports; the client (`market_api.dart`) and the catalog's checked state (`market_state.dart`) |
| The docs | `docs-src/pages/build-a-plugin.html` and the eight pages after it, `plugins.html`; `examples/plugins/` | The "Build a plugin" section of gogho.st/docs, for developers; the two example packs, which `tool/build-docs.mjs` copies to `site/docs/examples/` |

## Why packs and not code

- **Apple.** App Review Guideline 2.5.2 and the Developer Program License Agreement's 3.3.1(B) limit apps that download
  code which adds or changes their features. A storefront of other developers' features, with Submit, listings, review
  marks and Add, reads against both however its plugins are made, and would also need what 4.7.4 asks of software
  offered from outside the binary (an index of it) and 4.7.5's age ratings. So iPhone has none of it (below).
- **Google Play** refuses apps that download executable code from anywhere but Play. A pack is data that configures
  features already in the binary, as a filter list is, so Play's rule doesn't reach it.
- **Regular expressions run away.** Dart's `RegExp` backtracks: one nested quantifier was measured at 17.8 s on a
  29-character text. A stranger's regular expression, run on every text, could stop a phone. So no developer writes
  one: a phrase is literal words and the app's own bounded tokens (below).
- **A reviewer must see everything.** No network access, no widgets, no code: a key the format doesn't have is an error
  at any depth (`unknown_field`), so what the reviewer reads is all the pack can do.

## The file

The developers' reference is the docs: [The plugin file](https://gogho.st/docs/plugin-format/),
[Tags, tabs and buttons](https://gogho.st/docs/plugin-rules/), [Phrases and tokens](https://gogho.st/docs/plugin-phrases/)
and [What a plugin may do](https://gogho.st/docs/plugin-permissions/). What the code relies on:

- **Ids don't collide.** A pack `bills` is `xbills` in the registry; no built-in id starts with `x` (a test holds it).
  Its switch is `plugin_xbills`, its settings `plugin_xbills_<key>` (neither part has a `_`), its sections
  `xbills0<key>` (keys are letters only, so the last `0` parses back; never `other`, the filter's own), its tags
  `xbills.<tag>`. A pack's conditions read only its own tags, so it can't test, give or fake `spam` or `code`. The
  reserved ids are one list in the app and the relay, plus any id containing `ghost` or `gogho`; the examples' ids,
  `bills` and `parcels`, are refused for a submission only (`id_example`).
- **Words are visible.** Every string keeps one rule (`packTextOk`, the relay's copy the same): no Cc but `\n` where
  newlines are allowed, no Cf, Co, Zl or Zp, none of the blank-looking letters, no tag characters, no lone surrogates, no
  leading or trailing space. Lengths are UTF-16 code units. A name or section label that folds (`packFold`) to a
  built-in's, or contains `ghost` or `gogho`, is `name_reserved`: Dart has no Unicode normaliser without a new package,
  so `packFold` is a fixed table of fullwidth forms, Cyrillic and Greek look-alikes and marked Latin letters.
- **One file, one hash.** `canonicalJson` writes every object's keys sorted by UTF-16 code units, `jsonEncode`'s string
  escapes and no whitespace; a package's SHA-256 is over those bytes, and the store takes only canonical bytes
  (`not_canonical`), so a file's hash and its content's are the same thing. The relay has its own copy; both are held to
  the same vectors (`test/pack_canonical_test.dart`, `relay/test/market_pack_test.dart`).
- **Nesting is counted before decoding.** `jsonDepthOk` counts `[` and `{` outside strings in one pass and refuses
  deeper than 8 (`too_deep`): `jsonDecode` doesn't recurse, but `canonicalJson`'s rebuild and `jsonEncode` do, and a
  262,144-byte file of nested arrays would overflow the stack in the app and on the relay. The format's deepest path
  is 6.
- A file is at most 262,144 bytes; no fractions; an icon is a square PNG of 64 to 512 px holding only `IHDR`, `PLTE`,
  `tRNS`, `sRGB`, `gAMA`, `pHYs`, `IDAT` and `IEND` (`pngProblem`, checked from its chunks alone).

## What a pack sees, and why only that

```dart
bool packSees(MessageFacts f) =>
    !f.contact && (!f.contactByName || MessageFacts.contactsReadable) && f.outgoing == false && !f.group &&
    !f.encrypted && f.thread >= 0 && (f.network == null || f.network == 'sms') && f.senders.length == 1 &&
    !f.senders.single.startsWith('@');
bool packMayAct(MessageFacts f) => packSees(f) && !f.codeWaiting && signInCode(f.text) == null && !packMayHoldCode(f.text);
```

Never a contact's texts; never words that may be the person's own (`outgoing` is `false` only where `heard`, the newest
words that came in, is set, so a conversation the person started with nothing back isn't seen); never a group, whose
last words may be anyone's and whose unknown sender reads as not a contact; never a text sealed with the app's own
encryption; never another network's chat, a space or a friend by username. Where `packSees` fails a pack gives no tags
and offers no buttons. **`packMayAct` adds the sign-in code rule**: whatever Codes' own switch says, a pack can tag a
bank's code but never take it into a section, draw its row, keep a filing of it or act on it as it comes. Codes'
`signInCode` is `Notifier.otp`'s rule to the letter (it decides the Copy button) and misses "G-482913 is your Google
verification code.", Facebook's "FB-48291", Steam's letters and digits, codes in other languages and any text past
400 characters, so packs are held to `packMayHoldCode` as well: a word that speaks of a code anywhere in the text,
inside a longer word too ("Bestätigungscode", "验证码"), and a run of 4 to 10 ASCII letters and digits with a digit in
it (or 123-456) standing on its own. It is wider than it need be on purpose ("Use code SAVE20" counts): a false
positive only leaves a text alone, and `SmsEffects.codeWaiting` uses it too. A
conversation filed by hand into a pack's section stays there only while `packMayAct` holds. **Without Android's
Contacts permission** (`MessageFacts.contactsReadable`, from `heardStatus`; on a computer, from a name on any
conversation) every number reads as a stranger's, so where the facts' "not a contact" comes from a name
(`contactByName`: the phone's conversations and messages) a pack sees nothing. **A code waiting under newer words**
(`codeWaiting`): `lib/plugins/list.dart` asks the phone (`PluginEffects.codeWaiting`, on a computer across the link)
whether an unread text with a sign-in code sits under the newest words of a conversation a pack would sort or act on;
until it answers, and while one does, a pack neither sorts it, draws its row, marks it read nor takes its notification
away. A failed ask counts as waiting, and is asked again with the next classification. **Other unread texts under
the newest**: Android's `markRead` marks the whole conversation read (`Store.markRead`, `read = 0` in the thread) and
`cancelChat` takes away its one notification, which lists every unread text, so before a pack's `markread` or `mute`
the list reads the conversation's unread texts (`PluginEffects.unreadIncoming`, the newest 20) and acts only where
the same pack would ask the same of each of them as it came; a bank's fraud alert under a receipt Bills marks read
holds it back, two receipts don't. Twenty unread, or an ask that failed, holds it back too. `filters.classify` (thread 0)
and Try it (thread 1) are seen, which makes them test harnesses; `filters.classify` asks only the plugins that are on.
On an iPhone or a computer on its own there are no texts, so a pack does nothing there; a computer paired with a phone
runs it on the phone's texts, but never its incoming rules.

## The phrase language, and why it can't run away

A phrase is literal words, separators and tokens (`{digits:4-8}`, `{amount}`, `{code}`, `{word}`, `{words:0-3}`,
`{url}`, `{email}`, `{phone}`, `{date}`, `{time}`, `{number}`), compiled by `Phrase.compile` into a `RegExp` from fixed
fragments. No developer writes a quantifier: every one is the app's and bounded, and each token is self-delimiting
(lookarounds pin it to the run it sits on, and its classes are disjoint from what may follow it), so backtracking at any
start is bounded by a small constant. Measured with the same fragments in V8 over 2,000-character adversarial texts, the
slowest search took 0.6 ms. What packs cost together is bounded too:

- a text is read to its first 2,000 UTF-16 code units;
- a pack holds at most 200 phrases, 8 of them anchorless; a device at most 16 packs and 1,600 phrases;
- a phrase's **anchor** (its longest ASCII letter-and-digit run of 3 or more) is a plain substring test before the
  expression runs, and is part of what matching means, so every implementation agrees;
- `ConversationPlugins` keeps each message's classification while its words and the switches stay, and `TagStore`
  classifies a conversation only when those change.

## Running a pack

- `PackPlugin` is a `GhostPlugin`: one `TunedClassifier` (a change to its settings bumps `plugins_tuned` and every
  conversation is classified again), its sections and rows, its slot fills, one incoming rule, its settings. Every list
  is built once, in the constructor, since the registry matches plugins with `identical()`. Off by default; device
  scope only.
- **The gated host.** Every press runs through `GatedHost`: `say` cut to 80 and at most once every 1.5 s; `copy` (needs
  `copy`) cut to 200 and at most ten a minute; `markRead` and `move` only for the thread the button was offered on, and
  `move` only to the pack's own tabs or back to Messages; `write` (needs `write`) cut to 300; `openLink` only the pack's
  one link; `open`, `present` and `deleteThread` refused. A refusal calls `onTrouble` and `onError`, which land in the
  dev pack's errors and the Developer log. The list's and a conversation's buttons go through `runPluginAction`.
- **One-shot mutes.** A pack's `MuteNotification` is `PluginEffects.cancelNotification(thread)`
  (`Sms.cancelNotification`, MainActivity's `cancelChat`, `Notifier.cancel`) and nothing else: never the conversation's
  lasting `muted` flag, which `Notifier.kt` obeys while the app is closed, and never `plugins_muted`. A built-in's mute
  is as it was. Incoming rules run where they always have: on the phone, while the app is open, after Android has
  notified (`ListPlugins._arrived` returns on a computer or a paired iPhone).
- **Strikes and pausing.** Each classification is timed with the injected clock. A run of 20 ms or more is run again at
  once on the same text and is a strike only if that is as slow; over 100 ms of classifying in one second is a strike
  where that second's runs took 1 ms or more each on average (`PackLimits.slowOnAverage`), since `TagStore.bind` asks
  every pack about every conversation at once whenever `switches` changes (a switch, a tuned setting, an install, a
  pause, Turn it back on), and a pack at 40 µs a text over 3,000 conversations was otherwise a strike at each. Over
  500 ms in one second (`PackLimits.slowInASecondAlways`) is a strike whatever the average, so a pack just under 1 ms a
  text can't spend 2.7 s on those 3,000 at every change and never be paused. The
  first classification after construction never is (it compiles the expressions). Five strikes in ten minutes pause
  the pack: it gives nothing until "Turn it back on" or a new version, and the pause is kept in `plugins_paused`.

## Installing, loading, checking at every load, the floor, withdrawing

```text
<root>/                                    Android: <the app's files>/plugins; a computer or an iPhone: <DeskStore's folder>/plugins
  store/<packId>/<version>/package.ghostplugin   the canonical bytes, as downloaded
  store/<packId>/<version>/approval.json         the approval, canonical
  store/<packId>/<version>/listing.json          name, tagline, hue, symbol, developer and dates, for its row where it no longer parses
  dev/<packId>/package.ghostplugin               the bytes as loaded
  dev/<packId>/source.json                       where it came from, when, and the lines agreed to
  revoked.json                                   verified withdrawals and retirements only
<root>/../market/                          MarketState's cache: checked packages, verified.json, mine.json, drafts/
```

The disk is what is installed; prefs hold small indexes, each starting `plugins_`:

| Pref | Holds |
| --- | --- |
| `plugins_store` | `{"<packId>": "<version>"}` of the store packs loaded |
| `plugins_dev` | the dev pack ids present |
| `plugins_floor` | `{"<packId>": {"version", "sha256"}}`: the highest version ever installed here, never lowered, kept after Remove |
| `plugins_paused` | `{"x<packId>": "<sha256 of the copy paused>"}` |

- **At startup** (`InstalledPlugins.load`, from `lib/main.dart` and `lib/desktop/main.dart`, at most three seconds before
  the rest carries on): `revoked.json` merged with the lists the build ships, each verified again; for each store pack,
  the highest version that passes the install checks 1 to 6 below, installed after the built-ins in the order they were
  added, within the device's caps; anything that fails is listed with its problem and drawn as stuck, not run. Dev packs
  only where Developer mode is on (and not in an App Store build).
- **Installing** (`installReviewed`), in order, stopping at the first that fails: not an iPhone; at most 262,144 bytes;
  the bytes' SHA-256 is the approval's; not revoked; it parses with an icon and is canonical; its id and version are the
  approval's and the approval verifies with a pinned key that isn't retired; no dev pack of that id; not lower than the
  floor, nor the floor's version with another hash (`not_newer`; the same copy is a reinstall); an update by the same
  developer (`developer_changed` otherwise: the copy here's developer is its pack's, else listing.json's, else its file's
  read as plain JSON, and one nothing says is taken as someone else's, so a stuck copy can't be "updated" to another
  developer's plugin with its switch on; `MarketState.updates` and `developerChanged` count it the same way); within 16
  packs and 1,600 phrases. An update replaces the old version in
  place and keeps its switch. **A switch an incoming rule waits for starts off wherever its job is new**: each switch's
  jobs are its incoming rules' sections and verbs, and one whose jobs aren't all among the copy before's (every one, for
  a pack new here or one whose copy couldn't be read) is written `''` as it is installed, updated or loaded in
  development. A switch the person turned on as an ordinary setting, or for marking one kind read, would otherwise mark
  texts read or silence them the moment the new copy was in.
- **Removing** writes `''` to `plugin_x<id>` (adding it again asks again) and to every switch an incoming rule names
  (adding it again starts with them off), keeps its other choices unless `forget`, and keeps the floor.
- **Withdrawing.** `takeRevocations` reads `/market/revoked` from the market's own address and, where that isn't Uplink's
  relay, from Uplink's relay too, so a self-hosted relay can't withhold a withdrawal. It verifies
  every entry by a pinned key (any other fails without a check), each once however often it is sent, on an isolate and
  outside the installer's queue, so a long list of them never holds up Add, Update or Remove; one that fails is
  remembered (`unverified.json`, its mark a SHA-256 of its fields) and never checked again, since a bad signature stays
  bad. Then, in the queue, it uninstalls each store pack whose hash is revoked or whose approval's key is retired (files
  kept, so its page says what happened) and toasts each.

## The store on the relay

`Market.handle` takes every request whose first segment is `market`, and never throws: its body catches `Object`, so a
stack overflow is caught too, and answers 500 `broken`; `relay.dart` adds a `catchError` besides, since an error
escaping a module would end the relay and every hub connection with it. `Relay._handle` itself decodes the path in a
`try` (a path whose escapes aren't UTF-8, `GET /market/%FF`, threw before anything was routed and ended the relay; it
is a 400 now), catches whatever its routes throw, and the listener drops nothing unhandled; `bin/relay.dart` runs in
`runZonedGuarded`, so an error nothing caught after the start is a line on stderr.

**Signed requests.** `x-ghost-key`, `x-ghost-time` and `x-ghost-sig`, and with a body `x-ghost-body-sha256` and
`x-ghost-body-length`; the signature is over `ghost-market v1\n<METHOD>\n<path>\n<time>\n<body sha256>`, and a signed
request has no query string. Everything is checked before a byte of the body is read, cheapest first: the route; the
headers, each at most once (one sent twice is a 400, not dart:io's throw); the key, signature and time shapes, the time within 5 minutes; `Content-Length` against the body limit; the
replay cache (10 minutes, 20,000 entries, the oldest dropped when full); the address's signed budget (60 a minute,
counted before any verification); the relay's signature budget (20 checks a second); bodies over 64 KiB in flight (3,
and 3 × the body limit in bytes, and one at a time from one address and from one key, `rate_limited` otherwise); then
the P-256 verification; then the key's own budget (300 an hour). A refused request is answered with `Connection: close`
and its body is never read. Only then is the body read, into a `BytesBuilder`, whole within 60 s with no gap over 30 s,
its length and hash checked as it comes; a body over 64 KiB, which holds one of the few slots while it is read and
until its route is done with it (a submission waits its turn at route 8 with its body in memory, and given back at the
read's end, any number of read bodies waited there), must bring 64 KiB (or the rest of it) every 10 s, so a trickle
can't keep a slot for its minute.

| # | Route | Who |
| --- | --- | --- |
| 1 | `GET /market` | anyone: what the market takes, and its limits |
| 2, 3 | `GET /market/catalog`, `GET /market/revoked` | anyone; built per change and served from memory, with ETags |
| 4 | `GET /market/packages/<sha>` | anyone: an approved package (410 once revoked) |
| 6 | `GET /market/shots/<sha>` | anyone: a listed version's screenshot (there is no icon route: the app draws icons from checked packages) |
| 7 | `POST /market/report` | signed |
| 8 | `POST /market/submissions` | a signed developer (`{package, check: true}` checks without storing) |
| 9 to 13 | `GET /market/mine`, `GET /market/submissions/<sid>` (and `/package`, `/shots/<n>`), `DELETE /market/submissions/<sid>` | the owner (an admin may read) |
| 14 to 16 | `GET /market/review`, `GET` and `POST /market/review/<sid>` | a signed admin; approving needs a fresh one |
| 17 | `POST /market/plugins/<id>/listing` | a fresh admin, or the owner (who can't list again what an admin unlisted) |
| 18 | `POST /market/plugins/<id>/revoke` | a fresh admin |
| 19, 20 | `GET /market/reports`, `POST /market/reports/<rid>` | a signed admin |
| 21 | `POST /market/developers/<devId>/block` | a fresh admin |
| 22 | `POST /market/retire` | anyone, unsigned: a retirement, for a key that has signed something the market holds |

A submission is checked in order (C.7 of the spec): open; signed; one route-8 request at a time from here on, so two
first submissions of one id from two keys give one `201` and one `409 id_taken`; not blocked, verified where
`GHOST_MARKET_NEED_VERIFIED` is 1, a username at least a week old; a well-formed body that agrees to the guidelines; the
package canonical, not too deep, and its top level checked (the reviewer's app runs the whole of the format on it); the
developer is the key's own username and no one else's, that is no name another live developer's plugins were sent
under, first or later (`name_used`); the id new or the key's; the version newer than the one listed;
the screenshots PNG only, 64 to 2,400 px, at most 1 MB, and hashing to exactly the package's `shots`; then the quotas.
The top level's check keeps its first hundred issues (`too_many_issues` says how many more) and reads a list only as far
as its cap, as the app's does, so a stranger's package of thousands of problems costs an answer of a few KB. A
submission refused after its files are written (a version approved meanwhile, or a write that failed) deletes what it
wrote, gives back the day's counts it took, and takes back the plugin record it made. A record is made held for 30
days (`openUntil`) until its submission is recorded, so one left by a crash between the two is let go by the sweep.

**Storage** is `<data>/market/` (`/var/lib/ghost-relay/market` on the box): `state.json` (and `state.json.bak`),
`packages/<sha256>`, `shots/<sha256>` and `audit.jsonl`, a line per change. Saves are made in `Isolate.run`, changes
within a second written as one, each through one chained future; `stop()` answers anything new busy, lets route 8's
queue finish (10 s at most), saves synchronously, and writes any change or audit line that comes after its last save
as it comes. A `state.json` that
doesn't parse falls back to the `.bak`; if neither does, both are moved aside, the market starts empty, and each plugin's
owner is rebuilt from `audit.jsonl` before any submission is taken, so an empty start can't hand an id to whoever asks
first. **The daily sweep** deletes the files of closed submissions over 30 days old that nothing uses, and any file
nothing names at all, and releases an id with no approved version 30 days after its last open submission. Nothing
records which address read what. **The withdrawals list** (route 3) is never longer than every app reads whole: 8 MiB
as served, 25,000 withdrawals and 100 retired keys (`Market.withdrawalsMost`, `revocationsMost`, `retirementsMost`;
the app's `MarketReads` and `InstalledPlugins.revocationsTaken`, which a relay test reads to hold them the same). One
more is refused, 507 `withdrawals_full`, where review sees it: an app refused a longer list whole and took nothing, so
withdrawals had silently stopped reaching devices. Making room means shipping the old ones in a release
(`shippedRevocations`) and taking them out of `state.json` by hand.

**Limits**, each with its environment name (`relay/lib/market.dart`'s `MarketConfig.names`, and `KNOWN` in
`tool/deploy-relay.mjs`): `GHOST_MARKET_ON` (1), `GHOST_MARKET_MAX_PACKAGE` (262144), `GHOST_MARKET_MAX_SHOT` (1048576),
`GHOST_MARKET_MAX_SHOTS` (4), `GHOST_MARKET_MAX_BODY` (6291456, under Caddy's 10 MiB), `GHOST_MARKET_TOTAL` (1 GiB),
`GHOST_MARKET_SUBMISSIONS_A_DAY` (5 per someone), `GHOST_MARKET_SUBMISSIONS_PER_ADDRESS` (3),
`GHOST_MARKET_OPEN_PER_DEVELOPER` (3), `GHOST_MARKET_OPEN_PER_ADDRESS` (3), `GHOST_MARKET_OPEN_TOTAL` (200),
`GHOST_MARKET_OPEN_UNVERIFIED` (20 of those), `GHOST_MARKET_NAME_AGE_DAYS` (7), `GHOST_MARKET_PLUGINS_PER_DEVELOPER`
(20), `GHOST_MARKET_MAX_PLUGINS` (1000), `GHOST_MARKET_BYTES_PER_DEVELOPER` (24 MiB), `GHOST_MARKET_SIGNED_AN_HOUR`
(300), `GHOST_MARKET_SIGNED_PER_ADDRESS` (60 a minute), `GHOST_MARKET_VERIFY_A_SECOND` (20),
`GHOST_MARKET_BODIES_IN_FLIGHT` (3), `GHOST_MARKET_READS_PER_MINUTE` (240), `GHOST_MARKET_REPORTS_A_DAY` (500),
`GHOST_MARKET_NEED_VERIFIED` (0) and `GHOST_MARKET_REVIEW_KEYS` (empty: the signed-in admin's own key alone). A value
that doesn't read keeps its default. Caddy sends `/market` and `/market/*` to the relay beside `/files` and
`/feedback`, in both the gogho.st and the ghost-sms.com blocks (`tool/deploy-site.mjs`).

**Serving.** Packages are `application/octet-stream` attachments named `<id>-<version>.ghostplugin`; screenshots are
always PNG; both with `nosniff` and a sandboxing CSP, since gogho.st is also the site's and the docs' origin. Nothing
uploaded is ever served as HTML or SVG.

## Review

- **Where.** Settings › Admin (Developer mode, @matt, the admin password over the hub) has a **Plugin review** section:
  the review queue, **This device's review key** and **Make a retirement for this key**; the Marketplace has the same
  queue under Review queue. The admin session is the connection's own, with its time (`Handles.adminSignedIn`): reading
  needs a sign-in within 8 hours, approving, listing, withdrawing and blocking one within 30 minutes, and a relay restart
  signs everyone out. The review screens sign in where they are and send a refused decision again with its note.
- **What the reviewer sees**: what the pack can do (made from it, the same lines people see), "Look closely" (every
  `from`, every incoming rule and its switch, every `write` and `copy` text, the link, every anchorless phrase, and what
  changed among these since the last version), the checks, Try it with the samples, the whole file pretty-printed with
  every non-ASCII character in a phrase shown as `\u{…}`, diffs against the previous version and against the version
  changes were asked of, and the screenshots, decoded in Dart and never by the platform's codecs. What it can do is
  said as on a phone wherever the review is, since an approval covers every phone. The screenshots are the package's
  own `shots`, each fetched by its place and held to its hash, and the developer in its head the package's: those are
  what every user's page draws. Approve is held back where the store's row names other screenshots or another
  developer, where one can't be fetched as the package names it, until each has loaded, and where one can't be shown
  here (it can't be checked). Notes, a report's words and the reviewer's notes are checked as the relay holds them (a
  plugin's rule for words, their length in UTF-16 code units) before they are sent, and line ends are made one kind.
- **The words.** An approval is a P-256 signature by the reviewer's hub key over
  `ghost-market approve v1\n<id>\n<version>\n<sha256>`; it travels in the catalog entry, and the relay takes one only
  from the signed-in admin's own key, not retired, and in `GHOST_MARKET_REVIEW_KEYS` where that is set. A withdrawal
  signs `ghost-market revoke v1\n<id>\n<sha256>\n<at>\n<why>`, so the reason shown is the reviewer's own; the relay takes
  one only from a key in `GHOST_MARKET_REVIEW_KEYS` where that is set (a retired one's too), keeps one per package and
  key, and the review screen offers Withdraw only where this build pins the device's key, since every app drops a
  withdrawal by any other. A retirement signs `ghost-market retire v1\n<key>` with the key it retires.
- **The pinned keys** are `marketReviewKeys` in `lib/plugins/pack/review_keys.dart`, empty until Matt gives his: copied
  from Settings › Admin › Plugin review › This device's review key on the device he reviews from and read back to him in
  full, never from a `whois`, the hub or anything else the relay answers, which would make the relay the source of the
  trust. Changing the list is an app release. With it empty, a build trusts no reviewer: Discover says "This version of
  Uplink can't check plugins from other developers." and Approve is disabled.
- **The review key's other lives.** It is the hub key of the device he reviews from: on his phone, the key its texting
  encryption has (`Net.kt`); with an Uplink account, the account's, from the twelve recovery words, sealed on the relay
  under his password and on every device signed in to it, a Mac's or a PC's key file included. Whoever gets any of
  these can approve plugins every build trusts. The other way is to review from an identity used for nothing else,
  which needs a second name in `GHOST_ADMIN_NAMES` and `adminNames`.
- **Retiring a key.** Make the retirement as soon as the key is pinned (Make a retirement for this key copies it) and
  keep it offline. If the key is ever lost or taken, send it:

  ```sh
  curl -X POST https://gogho.st/market/retire -H 'content-type: application/json' --data @retirement.json
  ```

  and ship it in `shippedRetirements` in the next release. From then on that key's approvals fail at install and at
  every load; its withdrawals still count, since a withdrawal only takes trust away. Withdrawals ship the same way, in
  `shippedRevocations`, so a relay that withholds them can't keep a withdrawn plugin running on a new build.
- **The words test.** `test/pack_words_test.dart` fails if any file under `lib/` or `relay/lib/`, other than
  `lib/plugins/pack/review.dart` and `relay/lib/market*.dart`, holds the approve, revoke or retire words, so no later
  feature can become a way to have the review key sign them.
- **Reports** come from a plugin's page (route 7): a reason, words, and the username only where the person chose. Each
  address and each someone may send five a day, counted in memory; who sent one is never kept (no hub id in
  `state.json`, and `reporter` as the audit line's `by`), so with the username off the relay's files can't say whose it
  was; the newest 200 per plugin are kept; Settings › Admin's reports page marks them done. **Blocking** a developer (route 21) stops their submissions and may unlist their plugins.

## The app

- **The Marketplace place.** A ring in `_appRings` (`lib/ui/shell.dart`) between Archive and Settings,
  `Lucide.store`, so it is on the rail, the dock and classic pills, and Dial-Up's taskbar as "Market"; its count is the
  updates waiting. `AppShell.marketplace({section, plugin, seek, arg})` opens it: its list in the list's place, a
  section's page beside it on a wide window and over it on a phone (Discover, Added, Updates, Submit a plugin, My
  submissions, In development, Review queue).
- **What left Settings.** The `plugins` section is unlisted with no entry or screen; its page stays, so Settings'
  search still finds every plugin and setting, and a hit opens Discover at that plugin with the setting lit.
  `ui.openSettings('plugins')`, `settings('plugin-<id>')` and old links land there too. Circle settings › Plugins
  (built-ins only), Settings › Developer, API and Admin stay.
- **Plugins in development** (`lib/ui/market/dev_plugins.dart`): from a file (Android and a Mac), pasted (everywhere),
  from a link (https, or plain http to the device itself, which `adb reverse` makes the developer's computer on
  Android), with Reload; each pack's page has its problems, its recent errors, Try it, its settings, Open in the
  Marketplace, Submit it and Remove. A dev pack's first switch-on, and any reload whose lines grow, shows the consent
  sheet ("Not reviewed by anyone: switch this on only if you made it."); the list says while one is on. The API's
  `plugins.devInstall` and `plugins.devRemove` never switch a pack on without consent given on the phone, and the
  phone toasts every load.
- **The submission form** (`lib/ui/market/submit_screen.dart`) loads a pack, checks it with the market at once
  (route 8, `check: true`), and sends a deep copy with the form's fields (`developer` the tidied username, `shots` the
  screenshots' hashes) as canonical bytes. Its draft is kept per pack id in `<cache>/drafts/<packId>/` with its
  screenshots, so leaving the Marketplace loses nothing; a new version keeps the previous screenshots as `keep`s.
- **Listings are drawn from checked packages only.** The catalog carries no display field at all; `MarketState` fetches
  each listed package, checks its hash, its approval with a pinned key that isn't retired, that it isn't revoked and
  that it parses as that id and version, and only then shows it, everything on its card, page and consent sheet made
  from the package. Signature checks run in `Isolate.run`, the good ones kept in `verified.json`.

## iPhone and the App Store

No plugins from other developers on iPhone at all (App Review 2.5.2, DPLA 3.3.1(B), and what 4.7.4 and 4.7.5 would
ask): `InstalledPlugins.storeAllowed` is false there, so nothing installs or loads, `MarketState` never starts,
Discover lists the built-ins with "Plugins from other developers aren't on iPhone.", and Make your own isn't there. A
developer's own pack still loads on an iPhone in Developer mode, to try with Try it. An App Store build
(`--dart-define=GHOST_STORE=appstore`, `packAppStoreBuild`) compiles out plugins in development and their API methods
too.

## Not yet

- Text masks: rules that change the words a bubble shows, as Translate does. If ever, only as masks that hide matched
  phrases, the original a tap away and the card naming the plugin.
- Other networks' chats (Telegram, Signal, spaces) for packs.
- Circle-wide packs, with each member's consent and the version and hash in the manifest's `pl`.
- Kotlin applying a pack's incoming rules while the app is closed.
- Automatic updates.
- Moving a plugin to another developer.
- A web page listing every plugin, with links into the app (Apple 4.7.4).
- Age ratings (Apple 4.7.5).
- A Notion board for new submissions.
- Sandboxed code, later, behind the same contract.

## Matt has not said

- The review key or keys for `marketReviewKeys` and `GHOST_MARKET_REVIEW_KEYS`, and whether to review from his everyday
  identity or one of its own; the retirement made at once and kept offline.
- Every deploy and release: the relay with the market, any `GHOST_MARKET_*` value, Caddy's `/market` route, the site
  with the new docs and the examples, and the app. `GHOST_MARKET_NEED_VERIFIED=1` when the Marketplace opens is
  recommended, since a username and a key cost nothing.
- Packs see texts from numbers not in the contacts, one to one, not encrypted, and nothing else, and never act on a
  text with a sign-in code.
- Packs' tabs come after the built-in kinds: with Kinds of text on, Payment reminders and Deliveries & tracking take
  most bill and parcel texts first. The other order would let packs take texts from Kinds, never from Codes or Spam.
- No plugins from other developers on iPhone and no Submit there; no plugins in development in an App Store build.
- "Reviewed", not "Verified".
- One link per pack; no hidden kinds; no row titles; a pack's mute takes each notification away rather than muting the
  conversation.
- Approving an update doesn't withdraw the version before it unless the reviewer switches that on.
- No rules that change a message's words; Submit a plugin offered to everyone but iPhone, not only in Developer mode; a
  username a week old to submit; screenshots PNG only, made again by the app.
- The sixteen labels; on a phone the Marketplace opens on its list, not on Discover; new submissions counted in
  Settings › Admin and the queue, with no Notion board or notification; updates pressed, not automatic; nothing counted
  about installs.
- How soon reports are looked at: the guidelines page says as soon as we can, harmful ones first.
