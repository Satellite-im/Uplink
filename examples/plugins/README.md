# Example plugins

Two complete plugins in the `ghost-plugin/1` format, to load in Uplink's Developer mode, try, and make your
own from. How plugins work, field by field: [Build a plugin](https://gogho.st/docs/build-a-plugin/) on gogho.st/docs.

| File | What it shows |
| --- | --- |
| `bills.ghostplugin` | Bills: an amount found in a text (`amount due {amount}`) and shown large on the row with a button to copy it; a tab (Bills) and a kind in the list's filter (Receipts); a `words` setting whose words join a rule (`wordsFrom`); marking receipts read as they come, behind a switch that starts off. |
| `parcels.ghostplugin` | Parcels: words between words (`your {words:0-3} has shipped`); tracking codes (`{code:8-24}`) on the row, in the list's menu and in the conversation's header; a `choice` setting that makes it stricter or looser; a reply written for you to send (`write`); a link to its help page (`link`); "Not a parcel" moving a conversation back to Messages (`move`); silencing parcel texts as they come (`mute`), behind a switch. |

## Loading one

Turn on Developer mode first: tap Settings › About › Version twelve times. Then, in Settings › Developer › Plugins in
development:

- **Load a plugin from a link**: `https://gogho.st/docs/examples/bills.ghostplugin` (or `parcels.ghostplugin`), on any
  platform.
- **Paste a plugin**: copy a file's words and paste them.
- **Load a plugin from a file**, on Android or a Mac.
- **A link from your computer**, to change one and reload it. On an Android phone plugged in by USB:

  ```sh
  python3 -m http.server 8080       # in this folder
  adb reverse tcp:8080 tcp:8080     # then load http://127.0.0.1:8080/bills.ghostplugin
  ```

  On a Mac or Windows PC, serve the folder the same way and load `http://localhost:8080/bills.ghostplugin`.
- **The API**, with Settings › API › Serve the API on and `adb forward tcp:8765 tcp:8765`:

  ```sh
  printf '{"pack": %s}' "$(cat bills.ghostplugin)" | curl -s http://localhost:8765/api/plugins.devInstall \
    -H 'Authorization: Bearer <token>' --data-binary @-
  ```

Open it and use **Try it** with `Your bill is ready. Amount due: $45.20 by 3 Dec.` (or, for Parcels,
`Your parcel has shipped! Tracking number: 1Z999AA10123456784`): no text has to come, and it works on every platform.
**Try the samples** runs it on sixteen texts.

## Good to know

- On an Android phone, Kinds of text sorts bills and parcels first, into its Payment reminders and Deliveries &
  tracking: built-in plugins sort before plugins from other developers. To see the Bills or Parcels tab, switch that
  kind off in Marketplace › Kinds of text. Both plugins still tag those texts either way.
- The app calls them `xbills` and `xparcels` (a plugin's id with an `x` before it, so it can't be mixed up with a
  built-in plugin's): that's what `plugins.list` and `filters.classify` show, and their tabs are `xbills0bills` and
  `xparcels0parcels`.
- Their ids, `bills` and `parcels`, load in Developer mode but can't be submitted to the Marketplace. Give yours an id
  (and a name) of its own.
- Both say `"developer": "yourname"` and `example.com` addresses: the submission form puts your username in, and the
  help address must be yours.
- Their SHA-256s, of each file's canonical form (keys sorted, no spaces), which is how the Marketplace names a
  package:

  | File | Canonical bytes | SHA-256 |
  | --- | --- | --- |
  | `bills.ghostplugin` | 2,193 | `5c07c72f99f594ea3538046d4144515ed99756e9816b614a77a513c6afd562e7` |
  | `parcels.ghostplugin` | 2,943 | `81ca3c8f307f3c6a4f12d4bfd5030ebe9002fd1acc3c6df0e1319995ff0c70a2` |

- These files are copied as they are to gogho.st/docs/examples/ by `tool/build-docs.mjs`, and
  `test/fixtures/packs/` holds the same bytes for the app's tests.
