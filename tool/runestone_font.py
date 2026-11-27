#!/usr/bin/env python3
"""The look Runestone's face (lib/looks.dart): assets/fonts/Runestone-Regular.ttf and Runestone-Bold.ttf.

Matt, 2026-11-27: "make a theme in Ghost that fits this with the runescape font and everything" (of the Dark Vanilla
resource pack for Old School RuneScape's interface). The game's letters are small bitmaps. RuneStar/fonts
(github.com/RuneStar/fonts) traces each one, pixel for pixel, into an ordinary font and gives its work to the public
domain (CC0 1.0; each file's own copyright line says "Public Domain"). This takes two of that release's files, Plain 12
(the game's everyday letters) and Bold 12, and makes one family of them, a regular and a bold:

    python3 -m venv /tmp/fonts && /tmp/fonts/bin/pip install fonttools
    /tmp/fonts/bin/python tool/runestone_font.py            # fetches the release, checks it, writes the two files
    /tmp/fonts/bin/python tool/runestone_font.py <folder>   # or reads RuneScape-Plain-12.ttf and -Bold-12.ttf there

What it changes, and why:

- The family is named Runestone, as the look is: the app's own names, no one else's mark, in what it ships (the
  licence beside the fonts, assets/fonts/CC0-Runestone.txt, says where they came from).
- The game's letters stop at Western Europe's (Windows-1252 without its curly quotes). The app's own words use "…"
  and "›" hundreds of times, and a phone's keyboard writes ’ and “ ” for ' and ": each would be drawn by the next
  face in the list, a smooth letter among square ones. So the marks below are added, each made of the font's own
  pixels (its apostrophe turned over for ‘, three of its full stops for …), or drawn on the same grid.
- A pixel is 1/16 of the size: the font's own measure (16 units to the em), kept, so at 16 logical pixels a pixel of
  a letter is one logical pixel, as in the game.
- Its line is the size and no more (12 up, 4 down), which the game spaces by hand. A page's `line-height: normal` is
  the face's own, so every row of the app would be a sixth shorter than in its other faces and wrapped lines would
  touch. The line is made 14 up and 5 down (1.19, about Inter's), which also sits the capitals in a button's middle.

The release is read as data: nothing in it is run.
"""
import hashlib
import io
import os
import sys
import urllib.request
import zipfile

from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'assets', 'fonts')
RELEASE = 'https://github.com/RuneStar/fonts/releases/download/1.103-0/RuneScape-Fonts.zip'
SHA256 = 'aebff4ab4633aad9552e6ba7df5f85466707be673760613daa7a2463f3981c5d'
FAMILY = 'Runestone'
ASCENT, DESCENT = 14, 5
# (the release's file, our style, its weight, whether it is the bold)
FACES = [('RuneScape-Plain-12.ttf', 'Regular', 400, False), ('RuneScape-Bold-12.ttf', 'Bold', 700, True)]


def source(name, folder):
    """The bytes of one of the release's fonts: from [folder], or from the release itself, checked against SHA256."""
    if folder:
        with open(os.path.join(folder, name), 'rb') as f:
            return f.read()
    if not hasattr(source, 'zip'):
        data = urllib.request.urlopen(RELEASE).read()
        got = hashlib.sha256(data).hexdigest()
        if got != SHA256:
            sys.exit(f'{RELEASE} is not the file this was written for (sha256 {got})')
        source.zip = zipfile.ZipFile(io.BytesIO(data))
    return source.zip.read('ttf/' + name)


def pixels_of(font, glyph):
    """The pixels a glyph fills, as a set of (x, y), y up from the baseline: asked at each pixel's middle."""
    g = font['glyf'][glyph]
    if g.numberOfContours <= 0:
        return set()
    coords, ends, _ = g.getCoordinates(font['glyf'])
    shapes, start = [], 0
    for end in ends:
        shapes.append(list(coords[start:end + 1]))
        start = end + 1

    def inside(x, y):
        winding = 0
        for shape in shapes:
            for i, (x1, y1) in enumerate(shape):
                x2, y2 = shape[(i + 1) % len(shape)]
                if (y1 <= y) != (y2 <= y) and x1 + (y - y1) / (y2 - y1) * (x2 - x1) > x:
                    winding += 1 if y2 > y1 else -1
        return winding != 0

    return {(x, y) for x in range(g.xMin, g.xMax) for y in range(g.yMin, g.yMax) if inside(x + 0.5, y + 0.5)}


def glyph_of(pixels):
    """A glyph filling [pixels]: one rectangle for each run along a row, wound as TrueType's outer contours are."""
    pen = TTGlyphPen(None)
    for y in sorted({y for _, y in pixels}):
        row = sorted(x for x, yy in pixels if yy == y)
        i = 0
        while i < len(row):
            j = i
            while j + 1 < len(row) and row[j + 1] == row[j] + 1:
                j += 1
            x1, x2 = row[i], row[j] + 1
            pen.moveTo((x1, y))
            pen.lineTo((x1, y + 1))
            pen.lineTo((x2, y + 1))
            pen.lineTo((x2, y))
            pen.closePath()
            i = j + 1
    return pen.glyph()


def moved(pixels, dx=0, dy=0):
    return {(x + dx, y + dy) for x, y in pixels}


def turned(pixels):
    """[pixels] turned half round within their own box: an apostrophe into an opening quote."""
    xs, ys = [x for x, _ in pixels], [y for _, y in pixels]
    return {(min(xs) + max(xs) - x, min(ys) + max(ys) - y) for x, y in pixels}


def drawn(rows, left, bottom):
    """Pixels from a picture of them, its rows top to bottom, '#' for a filled one."""
    return {(left + x, bottom + len(rows) - 1 - r) for r, row in enumerate(rows) for x, ch in enumerate(row) if ch == '#'}


def build(data, style, weight, bold):
    font = TTFont(io.BytesIO(data))
    cmap = font.getBestCmap()
    advance = lambda name: font['hmtx'][name][0]
    px = lambda ch: pixels_of(font, cmap[ord(ch)])
    adv = lambda ch: advance(cmap[ord(ch)])
    added = {}  # code point -> (glyph name, pixels, advance)

    quote, comma, stop, hyphen, dash = px("'"), px(','), px('.'), px('-'), px('—')
    opening = turned(quote)
    width = max(x for x, _ in quote) - min(x for x, _ in quote) + 1
    added[0x2019] = ('quoteright', quote, adv("'"))
    added[0x2018] = ('quoteleft', opening, adv("'"))
    added[0x201A] = ('quotesinglbase', comma, adv(','))
    added[0x201D] = ('quotedblright', quote | moved(quote, width + 1), adv("'") + width + 1)
    added[0x201C] = ('quotedblleft', opening | moved(opening, width + 1), adv("'") + width + 1)
    added[0x201F] = ('quotereversed', opening | moved(opening, width + 1), adv("'") + width + 1)
    cw = max(x for x, _ in comma) - min(x for x, _ in comma) + 1
    added[0x201E] = ('quotedblbase', comma | moved(comma, cw + 1), adv(',') + cw + 1)
    added[0x2026] = ('ellipsis', stop | moved(stop, adv('.')) | moved(stop, 2 * adv('.')), 3 * adv('.'))
    # An en dash between the hyphen's length and the em dash's, on the hyphen's line and as thick.
    left = min(x for x, _ in hyphen)
    length = (len({x for x, _ in hyphen}) + len({x for x, _ in dash}) + 1) // 2
    en = {(left + i, y) for i in range(length) for y in {y for _, y in hyphen}}
    added[0x2013] = ('endash', en, left + length + 1)
    added[0x2212] = ('minus', en, left + length + 1)
    # A bullet: a square on the line the small letters' middle runs along.
    side = 4 if bold else 3
    added[0x2022] = ('bullet', {(1 + x, 2 + y) for x in range(side) for y in range(side)}, side + 2)
    # Single angle quotes ("Settings › Appearance"): one stroke, the bold's a pixel thicker.
    chevron = ['##...', '.##..', '..##.', '.##..', '##...'] if bold else ['#..', '.#.', '..#', '.#.', '#..']
    right = drawn(chevron, 1, 2)
    wide = len(chevron[0])
    added[0x203A] = ('guilsinglright', right, wide + 2)
    added[0x2039] = ('guilsinglleft', {(1 + wide - 1 - (x - 1), y) for x, y in right}, wide + 2)
    # The shade invisible ink stands as until it is tapped (lib/ui/message_line.dart): every other pixel of a letter's box.
    added[0x2592] = ('shade', {(x, y) for x in range(0, 6) for y in range(0, 10) if (x + y) % 2 == 0}, 7)

    glyf, hmtx, order = font['glyf'], font['hmtx'], font.getGlyphOrder()
    for code, (name, pixels, width) in added.items():
        if code in cmap:
            continue
        if name not in order:
            order.append(name)
            glyf[name] = glyph_of(pixels)
            hmtx[name] = (width, min(x for x, _ in pixels))
        cmap_add(font, code, name)
    # Marks that are another's shape: every hyphen, the primes, and the spaces a clock's "7:15 PM" is written with.
    for code, like in [(0x2010, '-'), (0x2011, '-'), (0x2032, "'"), (0x2033, '"'), (0x2002, ' '), (0x2003, ' '), (0x2009, ' '), (0x200A, ' '), (0x202F, ' '), (0x205F, ' ')]:
        if code not in cmap:
            cmap_add(font, code, cmap[ord(like)])
    font.setGlyphOrder(order)
    font['maxp'].numGlyphs = len(order)
    font['post'].formatType = 3.0  # no glyph names kept: nothing reads them, and the table need not list the new ones

    # The line a page reads as `normal`: 14 up and 5 down, in every table an engine may ask.
    font['hhea'].ascent, font['hhea'].descent, font['hhea'].lineGap = ASCENT, -DESCENT, 0
    font['OS/2'].sTypoAscender, font['OS/2'].sTypoDescender, font['OS/2'].sTypoLineGap = ASCENT, -DESCENT, 0
    font['OS/2'].usWinAscent, font['OS/2'].usWinDescent = ASCENT, DESCENT

    # One family, a regular and a bold, under the look's own name.
    font['OS/2'].usWeightClass = weight
    font['OS/2'].fsSelection = (font['OS/2'].fsSelection & ~0x61) | (0x20 if bold else 0x40)
    font['head'].macStyle = 1 if bold else 0
    names = {
        0: 'Public Domain (CC0 1.0). The letters as RuneStar/fonts 1.103-0 traced them; see CC0-Runestone.txt.',
        1: FAMILY, 2: style, 3: f'{FAMILY} {style} 1.103-0', 4: f'{FAMILY} {style}', 5: 'Version 1.103',
        6: f'{FAMILY}-{style}', 13: 'Public Domain (CC0 1.0)', 14: 'https://creativecommons.org/publicdomain/zero/1.0/',
    }
    font['name'].names = []
    for i, text in names.items():
        font['name'].setName(text, i, 3, 1, 0x409)
        font['name'].setName(text, i, 1, 0, 0)
    if 'FFTM' in font:
        del font['FFTM']  # FontForge's timestamp: nothing reads it, and without it the same input gives the same file

    out = os.path.join(OUT, f'{FAMILY}-{style}.ttf')
    font.save(out)
    check = TTFont(out)
    have = check.getBestCmap()
    missing = [hex(c) for c in list(range(0x20, 0x7F)) + list(range(0xA1, 0x100)) + list(added) if c not in have]
    if missing:
        sys.exit(f'{out} lacks {missing}')
    print(f'{os.path.relpath(out, ROOT)}: {len(check.getGlyphOrder())} glyphs, {len(have)} characters, {os.path.getsize(out)} bytes')


def cmap_add(font, code, name):
    for table in font['cmap'].tables:
        if table.isUnicode():
            table.cmap[code] = name


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else None
    for name, style, weight, bold in FACES:
        build(source(name, folder), style, weight, bold)


if __name__ == '__main__':
    main()
