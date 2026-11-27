# Vendored Glacier (web)

The Glacier UI kit the popup is drawn with, so it looks like the app (Matt, 2026-11-21: "Rebuild the chrome extension
UI ... to use glacier UI kit so it matches the app").

- `react/`: `@glacier/react` 0.1.0, the compiled kit (`dist/index.js` and the `dist/styles.css` its class names match),
  copied from Ghost.md's `tauri/vendor/@glacier/react`. Copy both files together, never one: a stylesheet whose hashes
  don't match the JS unstyles every component.
- `tokens/tokens.css`: the kit's design tokens, the same file as `messaging/packages/glacier/assets/css/tokens.css`.

The app's own ink palette is laid over them from `messaging/assets/css/ink.css` at build time (build.mjs). Edit the kit
upstream in Ghost.md and copy it back here, rather than diverging.
