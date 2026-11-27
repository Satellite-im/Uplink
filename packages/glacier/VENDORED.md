# Vendored Glacier (Flutter)

A copy of `packages/glacier` from InfamousVague/glyph (Ghost.md), taken from Ghost Keyboard's vendored copy (itself
Ghost.md at commit c10a10b, 2026-11-05), tests left out. Edit the kit upstream in Ghost.md and copy it back here,
rather than diverging.

Local addition (2026-11-18), optional and off unless an app sets it: `GlacierOverrides.segmentedSegment` with
`GlacierSegmentLook`, which lets an app draw each segment of a `GlacierSegmentedControl` itself in place of the track
and sliding thumb (Uplink's Dial-Up look draws them as push buttons). Copy it upstream with the next sync.

Local addition (2026-11-20), optional and off unless an app sets it: `GlacierTheme.resizeSettle`, a moment the
window's size must stand still before the tokens are worked out for it (Uplink's desktop app: the tokens,
and everything drawn from them, were made anew at every frame of a window being dragged larger or smaller;
docs/performance-audit.md, finding 8). Copy it upstream with the next sync.

Local addition (2026-11-23), in a browser only: the field core's semantics take the focus action as they take a tap
(`onFocus`, under `kIsWeb`). Flutter's engine gives a field the keyboard in a page with its tree for screen readers on
by focusing the field's element and saying so as the focus action; without it, a field the app had not focused itself
took what was typed into its element and the app heard nothing (Uplink's browser build). Copy it upstream
with the next sync.

Local addition (2026-11-27), optional and off unless a sheet sets it: `--glacier-text-shadow`, a `text-shadow` as CSS
writes one, which `Tokens.textAt` (and so `Tokens.text`) draws every word over (`Tokens.textShadows`). No sheet of the
kit's sets it, so nothing changes without one (Uplink's Runestone look: an old game's letters, each on a hard
black shadow one pixel down and right). Dark words (a luminance under 0.18) are drawn without it, since a dark shadow
only smudges them. A scope can take it off again with `none`. Copy it upstream with the next sync.
