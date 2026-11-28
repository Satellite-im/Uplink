#!/usr/bin/env python3
"""Puts Matt's pictures for gogho.st into site/art/ (and the site's icons), sized for the web.

Matt, 2026-11-15: "gogho.st assets has been added to desktop wire them and redeploy". The pictures were made from
~/Desktop/ghost-messaging-art-prompts.md; their originals stay where Matt keeps them (2048 px PNGs, megabytes each),
and only what the page shows is kept here: WebP at the largest size the page draws them, twice over for sharp screens.

  python3 tool/site-art.py ["~/Desktop/gogho.st assets"] ["~/Desktop/new_graphics"]

The second folder holds the spot icons (Matt, 2026-11-16: "new graphics uploaded to the desktop", made from
~/Desktop/ghost-messaging-icon-prompts.md): objects in Boo's style without Boo, for the cards and the install steps.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
ART = SITE / "art"

# Each picture by the start of its name, where it goes, and the longest side it is kept at.
PICTURES = [
    ("Boo hero mascot", "mascot-hero.webp", 640),
    ("Boo waving mascot", "mascot-wave.webp", 520),
    ("Calls scene", "scene-calls.webp", 1200),
    ("Desktop scene", "scene-desktop.webp", 1000),
    ("Privacy scene", "scene-privacy.webp", 720),
    ("Effects burst scene", "scene-effects.webp", 480),
    ("Empty state — messages", "boo-messages.webp", 360),
    ("Empty state — calls", "boo-calls.webp", 360),
    ("Empty state — codes", "boo-codes.webp", 360),
]

# The spot icons and the inbox scene (the second folder), and the wisps behind the hero and the dark sections.
SPOTS = [
    ("Spot icon 01", "icon-reactions.webp", 320),
    ("Spot icon 02", "icon-friends.webp", 320),
    ("Spot icon 03", "icon-sorted.webp", 320),
    ("Spot icon 04", "icon-emoji.webp", 320),
    ("Spot icon 05", "icon-ticks.webp", 320),
    ("Spot icon 06", "icon-updates.webp", 320),
    ("Spot icon 07", "icon-video.webp", 320),
    ("Spot icon 08", "icon-sealed.webp", 320),
    ("Spot icon 09", "icon-no-account.webp", 320),
    ("Spot icon 10", "icon-texts.webp", 320),
    ("Spot icon 12", "icon-install-phone.webp", 160),
    ("Spot icon 13", "icon-install-computer.webp", 160),
    ("Spot scene 11", "scene-inbox.webp", 900),
]


# The first PNG in `folder`, by name, whose name starts with `start`; stops where there is none.
def find(folder, start):
    for f in sorted(folder.iterdir()):
        if f.name.startswith(start) and f.suffix.lower() == ".png":
            return f
    sys.exit(f"x no picture starting {start!r} in {folder}")


def trim(image):
    """A transparent picture cut to what is drawn, with a little room kept round it."""
    box = image.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    if not box:
        return image
    pad = int(max(image.size) * 0.02)
    l, t, r, b = box
    return image.crop((max(0, l - pad), max(0, t - pad), min(image.size[0], r + pad), min(image.size[1], b + pad)))


# A copy of the picture no longer than `longest` on its longer side, in proportion; never made larger.
def fitted(image, longest):
    image = image.copy()
    image.thumbnail((longest, longest), Image.LANCZOS)
    return image


# The first of the Mac's own fonts that opens (San Francisco, Helvetica, Arial Bold) at `size`; Pillow's default
# where none does.
def font(size, bold=True):
    for path, index in (("/System/Library/Fonts/SFNS.ttf", 0), ("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0), ("/Library/Fonts/Arial Bold.ttf", 0)):
        try:
            f = ImageFont.truetype(path, size, index=index)
            if path.endswith("SFNS.ttf"):
                try:
                    f.set_variation_by_name("Bold" if bold else "Regular")
                except Exception:
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default()


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Desktop" / "gogho.st assets").expanduser()
    spots = Path(sys.argv[2] if len(sys.argv) > 2 else Path.home() / "Desktop" / "new_graphics").expanduser()
    if spots.is_dir():
        ART.mkdir(parents=True, exist_ok=True)
        for start, name, longest in SPOTS:
            image = fitted(trim(Image.open(find(spots, start)).convert("RGBA")), longest)
            image.save(ART / name, "WEBP", quality=86, method=6)
            print(f"ok site/art/{name} {image.size[0]}x{image.size[1]} {(ART / name).stat().st_size // 1024} KB")
        # The wisps: faint, wide, behind everything; not trimmed (their emptiness is the point).
        wisps = Image.open(find(spots, "Wisps texture")).convert("RGBA")
        wisps.thumbnail((1600, 1600), Image.LANCZOS)
        wisps.save(ART / "wisps.webp", "WEBP", quality=80, method=6)
        print(f"ok site/art/wisps.webp {wisps.size[0]}x{wisps.size[1]} {(ART / 'wisps.webp').stat().st_size // 1024} KB")
    ART.mkdir(parents=True, exist_ok=True)
    for start, name, longest in PICTURES:
        image = fitted(trim(Image.open(find(folder, start)).convert("RGBA")), longest)
        image.save(ART / name, "WEBP", quality=86, method=6)
        print(f"ok site/art/{name} {image.size[0]}x{image.size[1]} {(ART / name).stat().st_size // 1024} KB")

    # The share card: 1200 x 630, with the title on its calm left half (the prompt left it for the words).
    card = Image.open(find(folder, "Ghost Messaging share card")).convert("RGB")
    w, h = card.size
    want = 1200 / 630
    if w / h > want:
        nw = int(h * want)
        card = card.crop((w - nw, 0, w, h))  # keep the right, where Boo is
    else:
        nh = int(w / want)
        card = card.crop((0, (h - nh) // 2, w, (h + nh) // 2))
    card = card.resize((1200, 630), Image.LANCZOS)
    draw = ImageDraw.Draw(card)
    draw.text((72, 206), "Uplink", font=font(64), fill=(255, 255, 255))
    draw.text((74, 294), "Private text, voice and video.", font=font(34, bold=False), fill=(225, 250, 246))
    draw.text((74, 340), "In full quality.", font=font(34, bold=False), fill=(225, 250, 246))
    draw.text((74, 470), "gogho.st", font=font(30), fill=(190, 240, 232))
    card.save(ART / "og.jpg", "JPEG", quality=88, optimize=True, progressive=True)
    print(f"ok site/art/og.jpg 1200x630 {(ART / 'og.jpg').stat().st_size // 1024} KB")

    # The site's icons are the app's own black-and-white one (tool/app_icon.py writes them from art/app-icon.png; Matt,
    # 2026-11-16: "the ghost messaging logo on the website should be using the black and white logo the app uses for
    # everything"), so none are made here.


if __name__ == "__main__":
    main()
