#!/usr/bin/env python3
"""
Cuts the effects' sprite sheets (docs/effect-sprites-prompt.md) into the sprites the app moves (lib/effects.dart).

Matt, 2026-11-13: "the ghost messages assets are on the desktop, please wire them all and slice them up".

    python3 tool/effect_sprites.py ~/Desktop/ghost_messages_assets      keeps the sheets in art/effects/, then cuts
    python3 tool/effect_sprites.py                                      cuts the sheets already in art/effects/

A sheet is kept as a WebP that loses nothing of what is drawn (art/effects/balloons.webp), with the remover's halo
already cleared: that halo is two thirds of a sheet's weight as a PNG, and it is the first thing cut away here anyway.

A sheet is a square picture, named for its effect (balloons.png), of about twelve separate sprites on a clear
background: ghost characters in the top row, small props under them. Each sprite is found by its shape, not by a
grid: what is solid is gathered into pieces that touch, pieces a short way apart are one sprite (a ghost and the
little dashes drawn round it), and a speck on its own is dropped. The faint halo a background remover leaves round a
sprite (nearly clear pixels of any colour) is cut away first.

Written to assets/effects/: <effect>-h1.webp… for the top row's characters and <effect>-p1.webp… for the props,
which is how the app tells them apart; and to build/effect-sprites/, one picture of each sheet's cuts to look over.
"""

import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEETS = os.path.join(ROOT, 'art', 'effects')
OUT = os.path.join(ROOT, 'assets', 'effects')
LOOK = os.path.join(ROOT, 'build', 'effect-sprites')
CELL = 4            # the sheet is looked over at a quarter of its size
SOLID = 96          # of 255: what counts as part of a sprite
CLEAR = 64          # of 255: under this a pixel is the remover's halo, and is made clear
NEAR = 9            # cells: pieces this close are one sprite
SPECK = 40          # cells: a piece on its own smaller than this is dropped
TOP = 0.36          # of the sheet's height: sprites centred above this are the characters
HERO, PROP = 300, 200   # pixels: a character's and a prop's longer side as kept
LANCZOS = Image.Resampling.LANCZOS


def pieces(mask):
    """The pieces of [mask] that touch (corners count): each with its size and box, and a map of which cell is whose."""
    h, w = mask.shape
    owner = np.zeros(mask.shape, dtype=np.int32)
    out = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if owner[y0, x0]:
            continue
        label = len(out) + 1
        stack = [(y0, x0)]
        owner[y0, x0] = label
        n, left, top, right, bottom = 0, x0, y0, x0, y0
        while stack:
            y, x = stack.pop()
            n += 1
            left, right, top, bottom = min(left, x), max(right, x), min(top, y), max(bottom, y)
            for yy in (y - 1, y, y + 1):
                for xx in (x - 1, x, x + 1):
                    if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not owner[yy, xx]:
                        owner[yy, xx] = label
                        stack.append((yy, xx))
        out.append({'n': n, 'box': [left, top, right + 1, bottom + 1], 'labels': {label}})
    return out, owner


def gap(a, b):
    """How far apart two boxes are, in cells: 0 where they touch or overlap."""
    dx = max(a[0] - b[2], b[0] - a[2], 0)
    dy = max(a[1] - b[3], b[1] - a[3], 0)
    return max(dx, dy)


# Folds piece b into piece a: their pixel counts added, one box round both, their labels together.
def join(a, b):
    a['n'] += b['n']
    a['box'] = [min(a['box'][0], b['box'][0]), min(a['box'][1], b['box'][1]), max(a['box'][2], b['box'][2]), max(a['box'][3], b['box'][3])]
    a['labels'] |= b['labels']


def gather(found, shape):
    """Pieces a short way apart become one sprite; a speck left on its own is dropped."""
    groups = [dict(p, labels=set(p['labels'])) for p in sorted(found, key=lambda p: -p['n'])]
    merged = True
    while merged:
        merged = False
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                a, b = groups[i], groups[j]
                # Two whole sprites stay two however close they stand: only the small is drawn into the large.
                small = min(a['n'], b['n'])
                if gap(a['box'], b['box']) <= NEAR and small < 0.25 * max(a['n'], b['n']):
                    join(a, b)
                    del groups[j]
                    merged = True
                    break
            if merged:
                break
    groups = [g for g in groups if g['n'] >= SPECK]
    # A sheet is four across and three down. Where more than twelve are left, a sprite was drawn in several parts of
    # a like size (three sound waves, three sleep marks): the parts in one place of the twelve are one sprite.
    if len(groups) > 12:
        h, w = shape
        places = {}
        for g in groups:
            place = (min(2, int((g['box'][1] + g['box'][3]) / 2 * 3 / h)), min(3, int((g['box'][0] + g['box'][2]) / 2 * 4 / w)))
            if place in places:
                join(places[place], g)
            else:
                places[place] = g
        groups = list(places.values())
    return groups


def spread(mask, by):
    """[mask] grown by [by] cells every way."""
    out = mask.copy()
    for _ in range(by):
        grown = out.copy()
        grown[1:, :] |= out[:-1, :]
        grown[:-1, :] |= out[1:, :]
        grown[:, 1:] |= out[:, :-1]
        grown[:, :-1] |= out[:, 1:]
        out = grown
    return out


def sheet_path(name):
    """Where the sheet called [name] is kept."""
    for kind in ('.webp', '.png'):
        if os.path.exists(os.path.join(SHEETS, name + kind)):
            return os.path.join(SHEETS, name + kind)
    raise FileNotFoundError('no sheet called %s in %s' % (name, SHEETS))


def keep(source):
    """Keeps the sheet at [source] in art/effects/: every pixel as drawn, less the halo, in a file a quarter the size."""
    name = os.path.splitext(os.path.basename(source))[0]
    px = np.array(Image.open(source).convert('RGBA'))
    px[px[..., 3] < CLEAR] = 0
    Image.fromarray(px).save(os.path.join(SHEETS, name + '.webp'), 'WEBP', lossless=True, quality=90, method=6)


def sprites_of(path):
    """A sheet's sprites, each at the sheet's own size and cut to its own shape: its name, how many characters and
    props, and (kind, number, picture) for each, kind 'h' for a character and 'p' for a prop."""
    name = os.path.splitext(os.path.basename(path))[0]
    sheet = Image.open(path).convert('RGBA')
    px = np.array(sheet)
    alpha = px[..., 3].astype(np.float32)
    # The halo goes, and what is left is as solid as the sprite's body (which a remover leaves a shade short of whole).
    body = max(np.percentile(alpha[alpha >= SOLID], 50), 200.0) if (alpha >= SOLID).any() else 255.0
    alpha = np.where(alpha < CLEAR, 0, np.minimum(255, alpha * 255.0 / body))
    px[..., 3] = alpha.astype(np.uint8)
    h, w = alpha.shape
    solid = alpha >= SOLID
    small = solid[: h - h % CELL, : w - w % CELL].reshape(h // CELL, CELL, w // CELL, CELL).any(axis=(1, 3))
    found, owner = pieces(small)
    sprites = gather(found, small.shape)
    # Read as a page is: row by row, left to right.
    rows = sorted(sprites, key=lambda s: (s['box'][1] + s['box'][3]) / 2)
    for s in rows:
        s['cy'] = (s['box'][1] + s['box'][3]) / 2 * CELL / h
        s['cx'] = (s['box'][0] + s['box'][2]) / 2 * CELL / w
    heroes = sorted([s for s in rows if s['cy'] < TOP], key=lambda s: s['cx'])
    props = sorted([s for s in rows if s['cy'] >= TOP], key=lambda s: (round(s['cy'] * 3), s['cx']))
    out = []
    for kind, group in (('h', heroes), ('p', props)):
        for i, s in enumerate(group, 1):
            # Only this sprite's own pieces, with their soft edges: a neighbour's corner inside its box is not it.
            gh, gw = owner.shape
            cx0, cy0 = max(0, s['box'][0] - 2), max(0, s['box'][1] - 2)
            cx1, cy1 = min(gw, s['box'][2] + 2), min(gh, s['box'][3] + 2)
            near = owner[cy0:cy1, cx0:cx1]
            mine = np.isin(near, list(s['labels']))
            keep = spread(mine, 2) & ~((near > 0) & ~mine)
            keep = np.repeat(np.repeat(keep, CELL, axis=0), CELL, axis=1)
            own = px[cy0 * CELL:cy1 * CELL, cx0 * CELL:cx1 * CELL].copy()
            own[..., 3] = np.where(keep, own[..., 3], 0)
            piece = Image.fromarray(own)
            out.append((kind, i, piece.crop(piece.getchannel('A').point(lambda v: 255 if v >= CLEAR else 0).getbbox())))
    return name, len(heroes), len(props), out


def cut_grid(path, cols, rows):
    """A sheet drawn as [cols] by [rows] of one thing each (a pack of stickers, the frames of one animation), cut
    into those: for each place, read as a page is, its picture cut to its own shape, and where that picture's
    top-left corner stood in its place of the grid (so that frames keep how they stood to one another). A place
    with nothing in it gives None.

    What is in a place is found by shape and not by ruling lines: the pieces that touch are gathered, and each
    piece goes to the place its middle is in, whole, even where it leans over the line into the next."""
    sheet = Image.open(path).convert('RGBA')
    px = np.array(sheet)
    alpha = px[..., 3].astype(np.float32)
    body = max(np.percentile(alpha[alpha >= SOLID], 50), 200.0) if (alpha >= SOLID).any() else 255.0
    alpha = np.where(alpha < CLEAR, 0, np.minimum(255, alpha * 255.0 / body))
    px[..., 3] = alpha.astype(np.uint8)
    h, w = alpha.shape
    solid = alpha >= SOLID
    small = solid[: h - h % CELL, : w - w % CELL].reshape(h // CELL, CELL, w // CELL, CELL).any(axis=(1, 3))
    found, owner = pieces(small)
    gh, gw = small.shape
    places = {}
    for p in found:
        if p['n'] < 3:      # a speck the background remover left
            continue
        cx, cy = (p['box'][0] + p['box'][2]) / 2, (p['box'][1] + p['box'][3]) / 2
        place = (min(rows - 1, int(cy * rows / gh)), min(cols - 1, int(cx * cols / gw)))
        if place in places:
            join(places[place], p)
        else:
            places[place] = dict(p, labels=set(p['labels']))
    out = []
    for r in range(rows):
        for c in range(cols):
            s = places.get((r, c))
            if s is None or s['n'] < SPECK:
                out.append(None)
                continue
            x0, y0 = max(0, s['box'][0] - 2), max(0, s['box'][1] - 2)
            x1, y1 = min(gw, s['box'][2] + 2), min(gh, s['box'][3] + 2)
            near = owner[y0:y1, x0:x1]
            mine = np.isin(near, list(s['labels']))
            keep = spread(mine, 2) & ~((near > 0) & ~mine)
            keep = np.repeat(np.repeat(keep, CELL, axis=0), CELL, axis=1)
            own = px[y0 * CELL:y1 * CELL, x0 * CELL:x1 * CELL].copy()
            own[..., 3] = np.where(keep, own[..., 3], 0)
            piece = Image.fromarray(own)
            box = piece.getchannel('A').point(lambda v: 255 if v >= CLEAR else 0).getbbox()
            if box is None:
                out.append(None)
                continue
            # Where it stood in its own place of the grid: from that place's corner.
            out.append((piece.crop(box), (x0 * CELL + box[0] - c * w / cols, y0 * CELL + box[1] - r * h / rows)))
    return out


# Cuts one sheet into its sprites and writes each as a WebP, a character no larger than HERO a side and a prop no
# larger than PROP: the sheet's name, how many of each, and what was written.
def cut(path):
    name, heroes, props, found = sprites_of(path)
    written = []
    for kind, i, piece in found:
        side = HERO if kind == 'h' else PROP
        scale = side / max(piece.size)
        if scale < 1:
            piece = piece.resize((max(1, round(piece.width * scale)), max(1, round(piece.height * scale))), LANCZOS)
        out = os.path.join(OUT, '%s-%s%d.webp' % (name, kind, i))
        piece.save(out, 'WEBP', quality=84, method=4)
        written.append((out, piece))
    return name, heroes, props, written


def look(name, written):
    """One picture of a sheet's cuts, on grey, each with its name: to check nothing was joined or lost."""
    from PIL import ImageDraw
    cols = 6
    cell = 220
    rows = (len(written) + cols - 1) // cols
    page = Image.new('RGB', (cols * cell, rows * cell), (120, 124, 130))
    draw = ImageDraw.Draw(page)
    for i, (path, piece) in enumerate(written):
        x, y = (i % cols) * cell, (i // cols) * cell
        thumb = piece.copy()
        thumb.thumbnail((cell - 30, cell - 40), LANCZOS)
        page.paste(thumb, (x + (cell - thumb.width) // 2, y + 8), thumb)
        draw.text((x + 6, y + cell - 18), os.path.basename(path).replace(name + '-', '').replace('.webp', ''), fill=(255, 255, 255))
    page.save(os.path.join(LOOK, name + '.png'))


# Keeps the sheets in the folder given (if one is), then cuts every kept sheet again and writes a picture of each
# sheet's cuts to look over.
def main():
    os.makedirs(SHEETS, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(LOOK, exist_ok=True)
    if len(sys.argv) > 1:
        source = os.path.expanduser(sys.argv[1])
        for f in sorted(os.listdir(source)):
            if f.lower().endswith(('.png', '.webp')):
                keep(os.path.join(source, f))
    # What was cut before goes: a sheet drawn again may have fewer sprites than it had.
    for f in os.listdir(OUT):
        if f.endswith('.webp') and '-' in f and f.rsplit('-', 1)[1][0] in 'hp':
            os.remove(os.path.join(OUT, f))
    total = 0
    for f in sorted(os.listdir(SHEETS)):
        if not f.lower().endswith(('.png', '.webp')):
            continue
        name, heroes, props, written = cut(os.path.join(SHEETS, f))
        look(name, written)
        size = sum(os.path.getsize(p) for p, _ in written)
        total += size
        print('%-12s %d characters, %d props, %d KB' % (name, heroes, props, size // 1024))
    print('in all %.1f MB, in %s; to look over: %s' % (total / 1e6, os.path.relpath(OUT, ROOT), os.path.relpath(LOOK, ROOT)))


if __name__ == '__main__':
    main()
