#!/usr/bin/env python3
"""
Cuts the effects' animated characters into the strips of frames the app plays (lib/effects.dart).

Matt, 2026-11-13: "i'm going to include 6 frame animations for each asset in a sprite sheet it will be a lot of
assets in a folder", then "Push an update and release after you've sliced all the animated pictures sprites and the
sticker pack from the desktop".

    python3 tool/effect_anims.py ~/Desktop/Animated

A file there is one of an effect's characters drawn six times, three across and two down, read as a page is, and
named for the effect and the character's place on the effect's own sheet: `bye_r1c2 · wave right hand.png` is the
second character of `bye`, the one cut as assets/effects/bye-h2.webp by tool/effect_sprites.py. Each drawing is
found by its shape (effect_sprites.cut_grid), and the six are laid side by side as they stood in their places, so
a ghost that leans or lifts between drawings does so on the screen and one that keeps still keeps still.

Written to assets/effects/<effect>-a<N>.webp: the six frames in a row, each [FRAME] pixels on its longer side. The
app plays the strip where there is one and shows the still (-h<N>) where there is not. And to build/effect-anims/,
a picture of each strip to look over. The drawings themselves (2048 pixels square, a quarter of a gigabyte in all)
are not kept in the repository: they are Matt's, in the folder they came from.
"""

import os
import re
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import effect_sprites  # noqa: E402

ROOT = effect_sprites.ROOT
OUT = os.path.join(ROOT, 'assets', 'effects')
LOOK = os.path.join(ROOT, 'build', 'effect-anims')
COLS, ROWS = 3, 2
FRAME = 300         # pixels: a frame's longer side as kept, the same as a still character's
LANCZOS = Image.Resampling.LANCZOS
NAME = re.compile(r'^([A-Za-z]+)_r1c(\d+)\b')


def strip(path):
    """The six drawings of [path] as one row of frames of one size, or None where six were not found."""
    found = effect_sprites.cut_grid(path, COLS, ROWS)
    if any(f is None for f in found):
        return None
    # One frame's size: what holds every drawing where it stood in its own place.
    left = min(at[0] for _, at in found)
    top = min(at[1] for _, at in found)
    right = max(at[0] + piece.width for piece, at in found)
    bottom = max(at[1] + piece.height for piece, at in found)
    width, height = round(right - left), round(bottom - top)
    scale = min(1.0, FRAME / max(width, height))
    fw, fh = max(1, round(width * scale)), max(1, round(height * scale))
    row = Image.new('RGBA', (fw * len(found), fh), (0, 0, 0, 0))
    for i, (piece, at) in enumerate(found):
        frame = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        frame.paste(piece, (round(at[0] - left), round(at[1] - top)))
        if scale < 1:
            frame = frame.resize((fw, fh), LANCZOS)
        row.paste(frame, (i * fw, 0))
    return row


def main():
    if len(sys.argv) < 2:
        sys.exit('Which folder holds the animated drawings? python3 tool/effect_anims.py ~/Desktop/Animated')
    source = os.path.expanduser(sys.argv[1])
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(LOOK, exist_ok=True)
    for f in os.listdir(OUT):
        if re.search(r'-a\d+\.webp$', f):
            os.remove(os.path.join(OUT, f))
    made, failed, total = 0, [], 0
    for f in sorted(os.listdir(source)):
        m = NAME.match(f)
        if not m or not f.lower().endswith('.png'):
            continue
        effect, number = m.group(1), int(m.group(2))
        row = strip(os.path.join(source, f))
        if row is None:
            failed.append(f)
            continue
        out = os.path.join(OUT, '%s-a%d.webp' % (effect, number))
        row.save(out, 'WEBP', quality=80, method=5)
        total += os.path.getsize(out)
        page = Image.new('RGB', row.size, (120, 124, 130))
        page.paste(row, (0, 0), row)
        page.save(os.path.join(LOOK, '%s-a%d.png' % (effect, number)))
        made += 1
    print('%d characters animated, %.1f MB, in %s; to look over: %s' % (made, total / 1e6, os.path.relpath(OUT, ROOT), os.path.relpath(LOOK, ROOT)))
    if failed:
        print('six drawings were not found in: ' + '; '.join(failed))


if __name__ == '__main__':
    main()
