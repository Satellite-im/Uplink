# Uplink — keys

A browser extension that captures the sign-in cookies ("cURL entries") for every chat network the app signs in to with browser cookies — today **Messenger, Instagram, Discord, X, Slack and Google Messages** (Discord's and Slack's token read from their own requests with webRequest) (LinkedIn was dropped with the app's LinkedIn plugin, 2026-11-21; a new one is a line in `src/ghost/services.ts`) — and syncs them, **sealed**, across every device signed into your Uplink account. Sign in to Instagram once, in your browser, and all your devices sign in too — no copying a cURL command onto each one.

It replaces the manual flow in the app (open the site in a private window, copy a request as cURL, paste it into Uplink) with: sign in normally in your browser, and the extension does the rest.

## How it works

1. You **sign into your Uplink account** in the extension with your username and password (and a texted code where the account has a verified number); the recovery words aren't offered (Matt, 2026-11-21: "only allow logging in with the standard method"). The popup is drawn with the Glacier kit and the app's ink palette, so it looks like the app (`src/popup/popup.tsx`, `vendor/@glacier`). The extension reimplements Uplink's account cryptography (BIP-39 seed → secp256k1 account key and P-256 identity; Argon2id for the password), opens your account backup to learn the shared identity and seed, and connects to the relay's hub as a device of your account. See `src/ghost/crypto.ts` — every constant is copied from the app's Dart (`messaging/lib/account/account_crypto.dart`, `messaging/lib/net/crypto.dart`).
2. For each service you're **signed in to in the browser**, the extension reads its cookies with `chrome.cookies` (which can see the `httpOnly` cookies — `xs`, `sessionid`, `li_at` — that page scripts cannot), and builds an entry.
3. The entries are **sealed with a key derived from your account's BIP-39 seed** (`HKDF`, label `ghost curl v1` — identical to the app's `me.dart` `_curlKey`) and kept on the relay under `curl-keep`. The relay holds one sealed blob per account and **cannot read it**.
4. **Every device** of your account reads the blob back when it reaches the relay (`messaging/lib/inbox/curl_sync.dart`), and for each service it isn't already signed in to, switches that plugin on and signs in with the cookies — the same path a pasted sign-in takes.

Re-capture is automatic: a few seconds after a service's cookies change in the browser (you signed in, or they rotated), the extension re-seals and re-syncs, so a fresh login reaches your other devices without another click.

## What it can and can't see

- The relay sees only **sealed blobs**. The seal key never leaves your devices and the extension; it's derived from your account seed, which the relay never holds.
- The extension holds your account's **identity key** and the **cURL-seal key** while signed in. By default these live in `chrome.storage.session` — in memory, wiped when the browser closes. Tick **"Stay signed in"** to keep them in `chrome.storage.local` (on disk, in the extension's own area; no page or page-script can read it). Neither ever holds your password — those are used the moment they're typed and discarded.
- These are the same session cookies the app already accepts; they are **your** logins to those services, as unofficial-client access that each service may restrict. Nothing new is exposed to the services that a normal browser sign-in doesn't.

## Build

```
npm install
npm run build            # -> dist/chrome, pointed at the live hub (wss://gogho.st/hub)
npm run build:chrome -- --hub=wss://127.0.0.1:8787/hub --out=.verify/ext   # a local relay
```

Then in Chrome: **Extensions → Developer mode → Load unpacked → `dist/chrome`**.

The hub is fixed at build time (`__GHOST_HUB__`, read by `src/ghost/relay.ts`); only `wss://`, or a relay on this computer, is accepted. Icons are generated placeholders (`node scripts/make-icons.mjs`) — swap in real art in `icons/`.

## Develop

```
npm run typecheck        # tsc, strict
npm run test             # vitest: crypto round-trips, the canonical BIP-39 address vector, HKDF, sealing
```

The crypto is also validated end-to-end against the live relay during development: the hub accepts the P-256 identity handshake and recovers the right address from the signed `acct-seed` envelope, which proves the port matches the Dart.

## Adding a service

The services are listed in `src/ghost/services.ts` (id, name, cookie domains, the cookies a sign-in needs). Add one there **and** in the app's `messaging/lib/inbox/account_helper.dart`, and both the extension and the app pick it up — the rest of the extension iterates the list.

## Layout

- `src/ghost/crypto.ts` — the account/seal cryptography, ported from the app's Dart.
- `src/ghost/relay.ts` — the hub connection (handshake, `acct-*`, `curl-keep`/`curl-kept`).
- `src/ghost/account.ts` — sign-in (words / password) and the capture-merge-seal-keep sync.
- `src/ghost/services.ts`, `src/ghost/cookies.ts` — the services and reading their cookies.
- `src/ghost/keeper.ts` — where the signed-in session is kept (session vs local).
- `src/background.ts` — the worker: holds the account, captures, syncs, auto-syncs on cookie changes.
- `src/popup/` — the popup UI.
- `src/manifest.ts`, `build.mjs` — the MV3 manifest and the esbuild build.
