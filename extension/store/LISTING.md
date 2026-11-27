# Chrome Web Store listing — Uplink keys

Everything the Developer Dashboard asks for, ready to paste. The extension name, version and icon
come from the manifest (`src/manifest.ts`); the copy below is for the store listing and the
"Privacy practices" tab. Keep it in step with the manifest and `site/docs/browser-extension/`.

Upload artifact: **`messaging/site/ghost-messaging-keys.zip`** — the current hosted build (v0.1.2,
built against the live hub `wss://gogho.st/hub`). It is exactly `dist/chrome/`'s contents at the zip
root, which is what the store wants. To rebuild it: `npm run build && (cd dist/chrome && zip -r -X ../../store/upload.zip .)`.

---

## Product details

**Item name** (manifest `name`, ≤ 75 chars)
> Uplink — keys

**Summary / short description** (≤ 132 chars)
> Sign in to Messenger and Instagram once in your browser — every device on your Uplink account signs in too.

**Category**
> Social & Communication

**Language**
> English (United States)

**Detailed description**
> Uplink brings your chats — texts, Messenger, Instagram and more — into one app on every
> device you own. The catch with Messenger and Instagram is that they have no real API: the app signs
> in with the session from a browser you're already logged into. Doing that by hand on every phone and
> computer (open a private window, copy a request as cURL, paste it in) is the tedious part.
>
> This extension removes it. Sign in to your Uplink account in the extension, then sign in to Messenger
> or Instagram normally in your browser. The extension reads that browser's own sign-in, seals it with
> a key only your devices hold, and syncs it to every device on your Uplink account — so they all sign
> in too, with nothing to copy or paste. When a login changes, it re-syncs within seconds. It can also
> hand your Google sign-in to your devices to set up RCS through Google Messages.
>
> • Works with Messenger and Instagram, plus Google Messages (RCS) when you set it up.
> • End-to-end sealed: the session is encrypted with a key derived from your Uplink account. Uplink's
>   relay only ever stores an unreadable blob — it never sees your logins.
> • Nothing else is touched. The extension reads cookies only for those services' domains, injects no
>   content scripts, and reads no page content. No analytics, no tracking, no third-party servers.
> • Open source. Every line is published with each release at github.com/InfamousVague/ghost-messaging.
>
> You need the Uplink app (gogho.st) and an Uplink account to use it.
>
> Uplink is an independent app and is not affiliated with, endorsed by, or sponsored by Meta,
> Messenger, Instagram, Facebook, or Google.

---

## Single purpose

> Capture the sign-in cookies that the browser already holds for the chat services Uplink
> supports (Messenger, Instagram, and — when the user sets it up — Google Messages), and sync them,
> end-to-end encrypted, to the user's own devices through the Uplink relay, so the user signs in once
> instead of on every device.

## Permission justifications

Paste each into the matching box on the "Privacy practices" tab.

**`cookies`**
> Reads the session cookies of the chat services you are signed in to — Messenger (messenger.com /
> facebook.com), Instagram, and, only if you set it up, Google — including the httpOnly sign-in cookies
> that page scripts cannot read. These are what Uplink uses to sign in on your behalf, so they
> are sealed and synced to your other devices. No other site's cookies are read.

**Host permissions** (`https://*.messenger.com/*`, `https://*.facebook.com/*`, `https://*.instagram.com/*`, `https://*.google.com/*`)
> Scoped to exactly the domains of the services the extension syncs. They are required for the cookies
> permission to read those sites' sign-in cookies. The extension runs no content scripts on these pages
> and reads none of their content — only their cookies.

**`storage`**
> Holds your Uplink account's sealing key and session locally so the extension can seal and sync without
> asking you to sign in each time. By default this is `chrome.storage.session` (in memory, cleared when
> the browser closes); it moves to `chrome.storage.local` only if you tick "Stay signed in on this
> computer". Your recovery words and password are never stored — they are used the moment you type them
> and discarded.

**Remote code**
> No. All code is bundled in the package (esbuild, un-minified so a reviewer can read it). The only
> network connection is a WebSocket to the Uplink relay (wss://gogho.st/hub) carrying sealed blobs.

## Data use declarations

- **Data collected:** Authentication information — the session cookies for the user's own accounts on
  the services above. Nothing else (no browsing history, no page content, no analytics, no personal
  identifiers beyond those cookies).
- **How it's handled:** sealed on the user's device with a key derived from their Uplink account seed,
  then relayed only to the user's own devices. The relay stores one unreadable blob per account and
  cannot decrypt it.
- **Checkboxes:**
  - ☑ The item does not sell or transfer user data to third parties outside the approved use cases.
  - ☑ The item does not use or transfer user data for purposes unrelated to the item's single purpose.
  - ☑ The item does not use or transfer user data to determine creditworthiness or for lending.

**Privacy policy URL**
> https://gogho.st/docs/privacy/
>
> (Extension specifics — what it can and can't see — are at https://gogho.st/docs/browser-extension/.)

---

## Graphic assets (in `store/promo/`)

| Asset | Size | File | Required |
|---|---|---|---|
| Store icon | 128×128 | `icon-128.png` | yes |
| Screenshot | 1280×800 | `screenshot-1280x800.png` | yes (≥ 1) |
| Small promo tile | 440×280 | `tile-440x280.png` | optional, recommended |

Sources for the rendered images are in `store/promo-src/` (`screenshot.html`, `tile.html`); re-render
with `node store/render.mjs`. See `SUBMIT.md` for the step-by-step.
