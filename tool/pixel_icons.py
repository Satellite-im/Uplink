#!/usr/bin/env python3
"""The look Runestone's icons (lib/art/pixel_icons.g.dart): every icon of the app's, drawn in square pixels.

Matt, 2026-11-27: "find a pixelated icon pack to go with this theme". The pack is Pixelarticons (Gerrit Halfmann,
github.com/halfmage/pixelarticons; MIT, lib/art/PIXELARTICONS_LICENSE), as Iconify packages it: one file of every
icon, each a few filled paths on a 24 by 24 grid, which is the grid the app's own names come from.

    python3 tool/pixel_icons.py            # fetches the two packages into build/ first, if missing
    python3 tool/pixel_icons.py --sheet    # and writes build/pixel-icons.png, every icon in a grid, for looking over

The code calls each icon by its Lucide name (lib/art/app_icon.dart). An icon is drawn here by the Pixelarticons icon
of the same name where there is one, else by the one tool/pixel-map.json names for it. Where the pack has nothing
like it (the map says null), it is made from the icon the app draws everywhere else: Phosphor's, in its bold weight
(tool/phosphor-map.json), drawn 24 across and each pixel kept or dropped, so it is square pixels too and nothing in
the look is smooth. ImageMagick (`magick`) does that drawing.

The packages are read as data: nothing in them is run.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIXEL = os.path.join(ROOT, 'build', 'pixelarticons')
PIXEL_VERSION = '1.2.10'  # @iconify-json/pixelarticons, which is Pixelarticons 2.4.2
PHOSPHOR = os.path.join(ROOT, 'build', 'phosphor')
PHOSPHOR_VERSION = '2.1.1'
OUT = os.path.join(ROOT, 'lib', 'art', 'pixel_icons.g.dart')
GRID = 24


def fetch(folder, package):
    """An npm package's files under build/, fetched once."""
    if not os.path.isdir(os.path.join(folder, 'package')):
        os.makedirs(folder, exist_ok=True)
        tgz = subprocess.run(['npm', 'pack', '-q', package], cwd=folder, check=True, capture_output=True, text=True).stdout.strip().split('\n')[-1]
        subprocess.run(['tar', 'xzf', tgz], cwd=folder, check=True)
    return os.path.join(folder, 'package')


def of_pack(icons, name):
    """A Pixelarticons icon as one path: every path of its body, end to end."""
    body = icons[name]['body']
    paths = re.findall(r'<path[^>]*\sd="([^"]+)"', body)
    if not paths or re.search(r'<(circle|rect|ellipse|polygon|line|use)\b', body):
        sys.exit(f'{name}: more than paths in it')
    return ' '.join(paths)


def of_phosphor(package, name):
    """Phosphor's bold [name] as square pixels: drawn 24 across, each pixel on where the drawing covers 45% of it."""
    svg = os.path.join(package, 'assets', 'bold', f'{name}-bold.svg')
    if not os.path.exists(svg):
        sys.exit(f'No Phosphor icon "{name}"')
    # In black: the drawing's own `currentColor` is no colour to a tool that draws it alone.
    drawing = open(svg).read().replace('currentColor', '#000000')
    text = subprocess.run(
        ['magick', '-background', 'none', '-density', '288', 'svg:-', '-resize', f'{GRID}x{GRID}', '-alpha', 'extract', '-threshold', '45%', 'txt:-'],
        check=True, capture_output=True, text=True, input=drawing,
    ).stdout
    on = set()
    for line in text.splitlines():
        m = re.match(r'(\d+),(\d+):.*#([0-9A-Fa-f]{2})', line)
        if m and int(m.group(3), 16) > 127:
            on.add((int(m.group(1)), int(m.group(2))))
    if not on:
        sys.exit(f'{name}: nothing drawn')
    # One rectangle for each run along a row.
    parts = []
    for y in range(GRID):
        x = 0
        while x < GRID:
            if (x, y) in on:
                end = x
                while (end + 1, y) in on:
                    end += 1
                parts.append(f'M{x} {y}h{end - x + 1}v1h-{end - x + 1}z')
                x = end + 1
            else:
                x += 1
    return ''.join(parts)


def main():
    icons = json.load(open(os.path.join(fetch(PIXEL, f'@iconify-json/pixelarticons@{PIXEL_VERSION}'), 'icons.json')))['icons']
    phosphor = fetch(PHOSPHOR, f'@phosphor-icons/core@{PHOSPHOR_VERSION}')
    names = json.load(open(os.path.join(ROOT, 'tool', 'phosphor-map.json')))
    chosen = json.load(open(os.path.join(ROOT, 'tool', 'pixel-map.json')))
    drawn, made = {}, []
    for name in sorted(names):
        if name in chosen:
            pack = chosen[name]
            if pack is not None and pack not in icons:
                sys.exit(f'tool/pixel-map.json: no Pixelarticons icon "{pack}" (for {name})')
        else:
            pack = name if name in icons else None
            if pack is None:
                sys.exit(f'{name}: not in Pixelarticons under that name; say which draws it, or null, in tool/pixel-map.json')
        if pack is None:
            drawn[name] = of_phosphor(phosphor, names[name])
            made.append(name)
        else:
            drawn[name] = of_pack(icons, pack)
    lines = [
        '// Every icon of the app\'s in square pixels, by its Lucide name, on a 24 grid: Pixelarticons\' (MIT,',
        '// lib/art/PIXELARTICONS_LICENSE) where it has the icon, and the app\'s own Phosphor icon drawn in pixels where it',
        f'// has not ({len(made)} of {len(drawn)}). Made by `python3 tool/pixel_icons.py` from tool/pixel-map.json; drawn by',
        '// lib/art/app_icon.dart under a look that asks for them (`--app-icons: pixel`, Runestone).',
        '// coverage:ignore-file',
        '',
        '/// Each icon\'s filled path.',
        'const pixelIcons = <String, String>{',
    ]
    for name in sorted(drawn):
        lines.append(f"  '{name}': '{drawn[name]}',")
    lines.append('};')
    lines.append('')
    with open(OUT, 'w') as f:
        f.write('\n'.join(lines))
    print(f'{os.path.relpath(OUT, ROOT)}: {len(drawn)} icons, {len(drawn) - len(made)} of the pack\'s, {len(made)} made from Phosphor\'s: {" ".join(made)}')
    if '--sheet' in sys.argv:
        sheet(drawn)


def sheet(drawn):
    """Every icon in a grid, 16 across, white on dark, for looking over."""
    cell, across = 48, 16
    rows = (len(drawn) + across - 1) // across
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{across * cell}" height="{rows * cell}"><rect width="100%" height="100%" fill="#2a2428"/>']
    for i, name in enumerate(sorted(drawn)):
        x, y = (i % across) * cell + 12, (i // across) * cell + 12
        parts.append(f'<path transform="translate({x} {y})" fill="#ffffff" d="{drawn[name]}"/>')
    parts.append('</svg>')
    svg = os.path.join(ROOT, 'build', 'pixel-icons.svg')
    with open(svg, 'w') as f:
        f.write(''.join(parts))
    subprocess.run(['magick', '-density', '192', svg, '-filter', 'point', os.path.join(ROOT, 'build', 'pixel-icons.png')], check=True)
    print('build/pixel-icons.png: ' + ' '.join(f'{i}:{n}' for i, n in enumerate(sorted(drawn))))


if __name__ == '__main__':
    main()
