#!/usr/bin/env python3
"""Cuts the app's own screenshots into the pictures gogho.st uses (site/shots/).

Matt, 2026-11-15: "the phone isn't using a real screenshot from the app, i'd like it to be composed of an "exploded"
view of the app". The screen tests draw the app pixel for pixel (test/shots/*-light.png, at twice size), so the site
shows the real thing: whole screens, and the pieces of one conversation lifted apart for the hero's exploded view.
The site is mostly white (Matt: "a white green so a mostly white with a hint of teal / bluegreen"), so the light
screens are used. Each piece is cut from the app's near-white background (253, 253, 253), which is made see-through
from the crop's edges inwards, so a bubble floats on its own.

  python3 tool/site-layers.py      (after the screen tests redraw: flutter test --update-goldens test/screens_test.dart)
"""
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "test" / "shots"
OUT = ROOT / "site" / "shots"

# Each theme's background in the app, and how near a pixel must be to count as it (a bubble's grey is not). The site
# is dark by default (Matt: "want to have a dark mode that's used by default"), light as a choice: both are cut, the
# dark ones as name-dark.webp.
THEMES = {"light": (253, 4), "dark": (4, 7)}
BG, NEAR = THEMES["light"]


def cut(image, box):
    """The crop with the background around its edges made see-through (a flood from every edge pixel)."""
    piece = image.crop(box).convert("RGBA")
    w, h = piece.size
    px = piece.load()
    seen = bytearray(w * h)
    todo = deque()

    def bg(x, y):
        r, g, b, _ = px[x, y]
        return max(abs(r - BG), abs(g - BG), abs(b - BG)) <= NEAR

    for x in range(w):
        todo.append((x, 0))
        todo.append((x, h - 1))
    for y in range(h):
        todo.append((0, y))
        todo.append((w - 1, y))
    while todo:
        x, y = todo.popleft()
        i = y * w + x
        if seen[i] or not bg(x, y):
            continue
        seen[i] = 1
        px[x, y] = (0, 0, 0, 0)
        if x > 0: todo.append((x - 1, y))
        if x < w - 1: todo.append((x + 1, y))
        if y > 0: todo.append((x, y - 1))
        if y < h - 1: todo.append((x, y + 1))
    # The edge of what is left is softened by a pixel, so it does not show a dark fringe on the page.
    alpha = piece.getchannel("A")
    for y in range(h):
        for x in range(w):
            if alpha.getpixel((x, y)) and any(
                0 <= x + dx < w and 0 <= y + dy < h and not alpha.getpixel((x + dx, y + dy))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
            ):
                r, g, b, _ = px[x, y]
                px[x, y] = (r, g, b, 150)
    return piece


def pill(image, box, radius):
    """A crop kept to a rounded rectangle: for what floats over other things in the app (the dock, the call banner)."""
    piece = image.crop(box).convert("RGBA")
    mask = Image.new("L", piece.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, piece.size[0] - 1, piece.size[1] - 1), radius=radius, fill=255)
    piece.putalpha(mask)
    return piece


# Writes a piece to site/shots as a WebP: under `name` in the light theme, `name`-dark in the dark.
def save(piece, name, theme="light"):
    name = name if theme == "light" else f"{name}-dark"
    OUT.mkdir(parents=True, exist_ok=True)
    piece.save(OUT / f"{name}.webp", "WEBP", quality=88, method=6)
    print(f"ok site/shots/{name}.webp {piece.size[0]}x{piece.size[1]}")


# Where each piece of the conversation sits in each theme (dark draws the top bubbles a few pixels lower).
PIECES = {
    "light": {
        "x-header": (0, 44, 824, 160), "x-link": (20, 174, 664, 316), "x-place": (46, 344, 656, 478),
        "x-out1": (164, 574, 806, 709), "x-out2": (420, 709, 806, 800), "x-heart": (440, 796, 500, 848),
        "x-ticks": (520, 846, 800, 912), "x-in": (20, 920, 664, 1058), "x-laugh": (582, 1058, 644, 1106),
        "x-emoji": (34, 1222, 232, 1326), "x-chips": (20, 1382, 516, 1464), "x-compose": (20, 1636, 806, 1744),
    },
    "dark": {
        "x-header": (0, 44, 824, 160), "x-link": (20, 182, 664, 326), "x-place": (46, 352, 656, 486),
        "x-out1": (164, 580, 806, 711), "x-out2": (424, 714, 806, 800), "x-heart": (444, 794, 504, 848),
        "x-ticks": (520, 846, 800, 912), "x-in": (20, 922, 664, 1058), "x-laugh": (582, 1058, 644, 1106),
        "x-emoji": (34, 1222, 232, 1326), "x-chips": (20, 1382, 516, 1464), "x-compose": (20, 1636, 806, 1744),
    },
}


# How the exploded view lifts the conversation (Matt: "everything seems a bit jumbled and some text bubbles are
# duplicated"). Seen tipped back, a piece lifted higher slides up the screen; so the lift grows toward the top (the bar
# highest, the composer lowest) and every row slides away from the one under it, never onto it: the screen fans open
# like a staircase. A reaction sits a hair over its own bubble, so it stays on its corner.
PLANE = {
    "x-header": 2.1,
    "x-link": 1.9, "x-place": 1.75,
    "x-out1": 1.5, "x-out2": 1.5, "x-heart": 1.55, "x-ticks": 1.35,
    "x-in": 1.2, "x-laugh": 1.25,
    "x-emoji": 1.0, "x-chips": 0.85,
    "x-compose": 0.65,
}
SCREEN = (824, 1784)


def stack_markup():
    """The hero's layers as HTML, each placed where its piece sits on the screen, in both themes (data-light,
    data-dark: left, top and width in percent), for site/index.html between its STACK markers."""
    lines = []
    for name, plane in PLANE.items():
        spots = {}
        for theme in THEMES:
            l, t, r, _ = PIECES[theme][name]
            spots[theme] = f"{100 * l / SCREEN[0]:.2f},{100 * t / SCREEN[1]:.2f},{100 * (r - l) / SCREEN[0]:.2f}"
        l, t, w = spots["dark"].split(",")
        lines.append(
            f'          <div class="layer" style="--z:{plane};left:{l}%;top:{t}%;width:{w}%" data-light="{spots["light"]}" data-dark="{spots["dark"]}">'
            f'<img src="/shots/{name}-dark.webp" data-shot="{name}" alt=""></div>'
        )
    return "\n".join(lines)


# Puts stack_markup() between the STACK markers of site/index.html; nothing where the page has no markers.
def write_stack():
    page = ROOT / "site" / "index.html"
    html = page.read_text()
    a, b = "<!-- STACK -->", "<!-- /STACK -->"
    if a in html and b in html:
        head, rest = html.split(a, 1)
        _, tail = rest.split(b, 1)
        page.write_text(f"{head}{a}\n{stack_markup()}\n          {b}{tail}")
        print("ok site/index.html: the exploded view's layers")


def main():
    global BG, NEAR
    for theme, (bg, near) in THEMES.items():
        BG, NEAR = bg, near
        thread = Image.open(SHOTS / f"2-thread-{theme}.png")
        tabs = Image.open(SHOTS / f"20-layout-tabs-{theme}.png")
        hangout = Image.open(SHOTS / f"21-hangout-{theme}.png")

        # The hero's exploded conversation (2-thread): each piece where it sits on the 824 x 1784 screen.
        for name, box in PIECES[theme].items():
            save(cut(thread, box), name, theme)
        # Floating pieces from other screens.
        save(pill(tabs, (28, 1597, 669, 1716), 60), "x-callbar", theme)
        save(pill(tabs, (689, 1210, 807, 1696), 59), "x-dock", theme)
        save(cut(hangout, (20, 300, 804, 790)), "x-people", theme)
        save(cut(hangout, (160, 1590, 664, 1724)), "x-calldock", theme)

        # Settings › Voice and video from its Volume section down: the boost, Music mode, noise suppression.
        save(Image.open(SHOTS / f"19-voice-settings-{theme}.png").convert("RGB").crop((0, 590, 824, 2200)), "voice-settings", theme)

        # Other networks among the texts (Telegram's chats with their badge), and a Telegram chat from its top down to
        # before its picture, which the screen test leaves loading.
        save(Image.open(SHOTS / f"16-inbox-list-{theme}.png").convert("RGB").crop((0, 0, 824, 1170)), "inbox-list", theme)
        save(Image.open(SHOTS / f"16-inbox-chat-{theme}.png").convert("RGB").crop((0, 0, 824, 925)), "inbox-chat", theme)

        # Whole screens, for the sections below the hero.
        for src, name in (("2-thread", "thread"), ("20-layout-tabs", "list"), ("21-hangout", "hangout"), ("11-frame-wide-thread", "wide"), ("21-hangout-chat", "hangout-chat")):
            path = SHOTS / f"{src}-{theme}.png"
            if path.exists():
                save(Image.open(path).convert("RGB"), name, theme)


if __name__ == "__main__":
    main()
    write_stack()
