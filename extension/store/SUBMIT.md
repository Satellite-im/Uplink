# Submitting Uplink keys to the Chrome Web Store

What's prepared here, and the steps only you can do (they need the developer account and the one-time
fee). Everything in this folder is ready to upload.

## In this folder

- `LISTING.md` — all the listing copy: name, summary, description, single purpose, the three
  permission justifications, the data-use declarations, and the privacy-policy URL. Paste as-is.
- `promo/icon-128.png` — the 128×128 store icon.
- `promo/screenshot-1280x800.png` — the required screenshot.
- `promo/tile-440x280.png` — the optional small promo tile (worth including).
- `promo-src/` + `render.mjs` — the sources; `node store/render.mjs` re-renders the PNGs.

**Upload package:** `messaging/site/ghost-messaging-keys.zip` — the current hosted build (v0.1.2,
built against `wss://gogho.st/hub`), files at the zip root, which is what the store expects. To make a
fresh one: `cd messaging/extension && npm run build && (cd dist/chrome && zip -r -X ../../ghost-keys-upload.zip .)`.

## Steps (yours — needs the account)

1. **Register as a developer** (one-time, ~$5) at the Chrome Web Store Developer Dashboard with the
   Google account that should own the listing: https://chrome.google.com/webstore/devconsole/ . Use a
   Uplink/MattsSoftware account, not a personal one, if you want the team to manage it.
2. **New item → upload** `ghost-messaging-keys.zip`.
3. **Store listing tab:** paste the name, summary, description and category from `LISTING.md`; upload
   the icon, screenshot and promo tile from `promo/`.
4. **Privacy practices tab:** paste the single-purpose statement and the three permission
   justifications; tick the three data-use declarations; set the privacy-policy URL
   (`https://gogho.st/docs/privacy/`). This tab is what the review hinges on — `cookies` + host
   permissions always draw a closer look, so the justifications are written to answer it head-on.
5. **Distribution:** Public (or Unlisted if you'd rather hand out the link while it's in alpha).
6. **Submit for review.** First reviews commonly take a few days up to ~a week for an extension that
   reads cookies. They may email questions — the justifications in `LISTING.md` are the answers.

## After it's published

- Swap the homepage + `docs/browser-extension/` wording from "Not in the Chrome Web Store yet / Load
  unpacked" to the store link, and point the download button at it. (Keep the `.zip` for Firefox and
  for people who prefer loading it unpacked.)
- Later updates: bump `version` in `package.json`, `npm run build`, zip `dist/chrome`, upload a new
  package version. Published extensions auto-update for users, so this replaces the manual re-download.

## Notes / gotchas

- **Name & trademarks:** the item name carries no third-party brand (good — Apple rejected an earlier
  iOS listing for a brand word in metadata). The description names Messenger/Instagram/Google only
  functionally and carries a "not affiliated with…" line. Don't add their logos to the promo images.
- **Firefox:** `npm run build firefox` produces an AMO-ready build too (the manifest already includes
  the `browser_specific_settings` gecko id); Mozilla's listing is a separate submission if you want it.
- **minimum_chrome_version** is 120; the store will show that as the floor.
