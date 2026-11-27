#!/usr/bin/env python3
"""
Uplink's app icon from one square picture (art/app-icon.png), as Ghost Keyboard's tool/app_icon.py makes its.

Matt, 2026-11-27: "update the logo to the uplink logo on the desktop" (~/Desktop/UplinkLogo.png: a white speech
bubble with UP LINK cut out of it, on black). Until then it was the white ghost that is a speech bubble (Matt,
2026-11-13: "update the icon to use the one from the desktop", ~/Desktop/ghost_messenger.png), which is why the
files this writes are still named for a ghost: the app's code names them, and a name is not what anyone sees.

    python3 tool/app_icon.py ~/Desktop/UplinkLogo.png         copies it to art/app-icon.png, then writes every icon
    python3 tool/app_icon.py                                  writes every icon from art/app-icon.png
    python3 tool/app_icon.py --check <the built Mac app>      says whether macOS will draw its icon whole (mac_icon)

The picture is cleaned first (clean): its black made black and its white white.

Android's adaptive icon (minSdk 29, so no legacy PNGs): the foreground is the picture shrunk so the mark, its
corners included, sits inside the mask's 66dp safe circle, its black carried on past the edges to the full 108dp,
over a black background; the monochrome layer is the mark alone (its brightness as alpha), for themed icons. The
notification's small icon is the same shape, white on nothing, cut to its own edges. The site's icons are the full
square, and so are the icons of the app in a browser (web/), but for the two a home screen may cut to a shape of its
own (web_icons). The Mac's is the picture in macOS's own outline (mac_icon), and Linux's is that one again; Windows'
and the iPhone's are the full square at the sizes each asks for, and the browser extension's is the square with its
corners rounded (extension/icons).
"""

import os
import shutil
import sys

from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, 'art', 'app-icon.png')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
SITE = os.path.join(ROOT, 'site')
MAC = os.path.join(ROOT, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
WEB = os.path.join(ROOT, 'web')
# The mark's farthest point (the bubble's lower left corner) is 48.1% of the picture from its centre: 52dp of the
# 108. At 0.63 it is 32.7dp, inside the safe circle's 33. main() measures the picture it is given and refuses one
# this would cut.
SCALE = 0.63
SAFE_DP, FULL_DP = 33, 108
BACKGROUND = (0, 0, 0)
DENSITIES = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
# The status bar's icon is 24dp.
SMALL = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}
LANCZOS = Image.Resampling.LANCZOS


def clean(picture):
    """
    The picture with its black made black and its white white, the greys of its edges between them kept.

    A picture that came out of a drawing made by a model has a faint grain in both (this one: its black anything up
    to 13 of 255, its white anything down to 246, and a trace of colour in each). No eye sees it in the picture, but
    it shows as a box round the mark where the picture's black meets a black that is the system's own (Android's
    background behind the foreground, a browser's behind a maskable icon), and as a mottled mark where brightness
    is used as alpha (the themed icon, the notification's, the mark in the app).

    A picture with real colour in it keeps its colour: only one that is grey all over but for that trace is made
    grey outright.
    """
    def level(v):
        return 0 if v <= 16 else 255 if v >= 240 else round((v - 16) * 255 / 224)
    red, green, blue = picture.convert('RGB').split()
    trace = max(ImageChops.difference(red, green).getextrema()[1], ImageChops.difference(red, blue).getextrema()[1])
    if trace <= 24:
        grey = picture.convert('L').point(level)
        return Image.merge('RGB', (grey, grey, grey))
    return Image.merge('RGB', (red.point(level), green.point(level), blue.point(level)))


def farthest(picture):
    """How far the mark reaches from the picture's middle, as a share of the picture's width (0.5 is its edge)."""
    import math
    small = picture.convert('L').resize((512, 512), LANCZOS).point(lambda v: 255 if v > 40 else 0)
    pixels = small.load()
    far = 0.0
    for y in range(512):
        for x in range(512):
            if pixels[x, y]:
                far = max(far, math.hypot(x + 0.5 - 256, y + 0.5 - 256))
    return far / 512


# The picture at SCALE in the middle of a square of `size`, for Android's adaptive icon: as 'foreground' on the
# black background, otherwise (monochrome) white whose alpha is the picture's brightness.
def shrunk(picture, size, mode):
    inner = round(size * SCALE)
    small = picture.resize((inner, inner), LANCZOS)
    offset = ((size - inner) // 2, (size - inner) // 2)
    if mode == 'foreground':
        out = Image.new('RGB', (size, size), BACKGROUND)
        out.paste(small, offset)
        return out
    alpha = Image.new('L', (size, size), 0)
    alpha.paste(small.convert('L'), offset)
    out = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def mac_shape(side):
    """
    The outline of a macOS icon, [side] across, as a mask (white inside): a superellipse, |x|^5 + |y|^5 = 1,
    measured from Ghost.md's Mac icon (it fits to under two pixels in 824). It is how the icon looks on a macOS
    that masks nothing itself; it is not what keeps the icon off a plate (see mac_icon).
    """
    import math
    from PIL import ImageDraw
    big = 4
    s = side * big
    half = s / 2
    steps = 720
    outline = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, n = math.cos(t), math.sin(t)
        # The point of the superellipse in the direction t: each coordinate's sign, and its size to the 2/5.
        outline.append((half + half * math.copysign(abs(c) ** 0.4, c), half + half * math.copysign(abs(n) ** 0.4, n)))
    mask = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mask).polygon(outline, fill=255)
    return mask.resize((side, side), LANCZOS)


# The least blue anything in the Mac icon has: its black is (0, 0, 2), which no eye tells from black.
MAC_TINT = 2


def mac_icon(picture, size):
    """
    The picture as a macOS icon: 824 of the 1024 across, in the outline above, with a soft shadow under it.

    Matt, 2026-11-13: "the icon on the mac app is also not full width and height, it's inset". macOS 27 drew it
    small on a grey plate of its own. The cause was not the outline (three were tried, and a plain square too):
    this picture is black and white and nothing else, Xcode's asset catalog stores a picture with no colour in it
    as greyscale ("Monochrome"), and macOS puts a greyscale icon on a plate. With one pixel that is not grey the
    catalog stores it as colour and macOS draws it whole, in any outline. So the black here carries [MAC_TINT] of
    blue, and main() refuses to write a Mac icon that is all grey.

    The test is the app as built, since an .icns beside it is not read: `python3 tool/app_icon.py --check
    "build/macos/Build/Products/Release/Uplink.app"` says how its catalog stored the icon, and
    `NSWorkspace.shared.icon(forFile:)` on it is what the Dock draws.
    """
    from PIL import ImageFilter
    work, inner = 1024, 824
    at = (work - inner) // 2
    mask = mac_shape(inner)
    # The shadow: the shape, a little lower, blurred, at a third of black.
    shadow = Image.new('L', (work, work), 0)
    shadow.paste(mask, (at, at + 12))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.3))
    out = Image.new('RGBA', (work, work), (0, 0, 0, 0))
    out.putalpha(shadow)
    out.paste(picture.convert('RGB').resize((inner, inner), LANCZOS), (at, at), mask)
    if size != work:
        out = out.resize((size, size), LANCZOS)
    # The tint last, at the size it is kept at: shrinking would round some of it away.
    red, green, blue, alpha = out.split()
    return Image.merge('RGBA', (red, green, blue.point(lambda v: max(v, MAC_TINT)), alpha))


def has_colour(icon):
    """Whether any pixel of [icon] that is not clear is not grey: what the asset catalog needs to keep it as colour."""
    red, green, blue, alpha = icon.convert('RGBA').split()
    solid = alpha.point(lambda v: 255 if v == 255 else 0)
    from PIL import ImageChops
    return ImageChops.multiply(ImageChops.difference(red, blue), solid).getbbox() is not None or \
        ImageChops.multiply(ImageChops.difference(red, green), solid).getbbox() is not None


def check_built(app):
    """How the built Mac app's asset catalog stored its icon: every size must be colour (see mac_icon)."""
    import json
    import subprocess
    car = os.path.join(app, 'Contents', 'Resources', 'Assets.car')
    rows = json.loads(subprocess.run(['xcrun', 'assetutil', '--info', car], capture_output=True, text=True, check=True).stdout)
    icons = [r for r in rows if r.get('AssetType') == 'Icon Image']
    grey = [r for r in icons if r.get('ColorModel') != 'RGB']
    for r in icons:
        print(f"{r.get('PixelWidth')}px @{r.get('Scale')}x: {r.get('ColorModel')}")
    if not icons or grey:
        raise SystemExit('the Mac icon is stored as greyscale: macOS will draw it small on a plate' if grey else 'no icon in ' + car)
    print('the Mac icon is stored as colour in', car)


def silhouette(picture, size):
    """The mark alone, white with its brightness as alpha, cut to its own edges and centred in a square of [size]."""
    # What is all but black is nothing: a faint box would show round the mark wherever it is drawn over a colour.
    grey = picture.convert('L').point(lambda v: 0 if v < 24 else v)
    box = grey.point(lambda v: 255 if v > 40 else 0).getbbox()
    shape = grey.crop(box)
    side = max(shape.size)
    square = Image.new('L', (side, side), 0)
    square.paste(shape, ((side - shape.width) // 2, (side - shape.height) // 2))
    # A little room round it, as the status bar's own icons have.
    inner = round(size * 0.9)
    alpha = Image.new('L', (size, size), 0)
    alpha.paste(square.resize((inner, inner), LANCZOS), ((size - inner) // 2, (size - inner) // 2))
    out = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


# A "maskable" icon is cut to whatever shape the home screen has, and only a circle four fifths of its width is sure
# to show: 40% of the icon from its middle. The bubble's lower left corner, the farthest thing from the middle,
# measures 48.1% of this picture from it; at 0.8 it is 38.5%, inside that circle.
WEB_SAFE = 0.8
WEB_SURE = 0.40


def web_icons(picture):
    """
    The app in a browser (web/, lib/web/main.dart): the icon in its tab, the two sizes its manifest names, and those
    two again for a home screen that cuts icons to a shape of its own, the picture at [WEB_SAFE] of the size with its
    black carried on to the edges.
    """
    os.makedirs(os.path.join(WEB, 'icons'), exist_ok=True)
    picture.resize((32, 32), LANCZOS).save(os.path.join(WEB, 'favicon.png'), optimize=True)
    for size in (192, 512):
        picture.resize((size, size), LANCZOS).save(os.path.join(WEB, 'icons', f'Icon-{size}.png'), optimize=True)
        inner = round(size * WEB_SAFE)
        cut = Image.new('RGB', (size, size), BACKGROUND)
        cut.paste(picture.resize((inner, inner), LANCZOS), ((size - inner) // 2, (size - inner) // 2))
        cut.save(os.path.join(WEB, 'icons', f'Icon-maskable-{size}.png'), optimize=True)


# The sizes Windows draws an app's icon at: its lists, the taskbar, Alt-Tab, the Start menu's tiles.
WINDOWS_SIZES = [16, 24, 32, 48, 64, 128, 256]


def windows_icon(picture):
    """The Windows app's icon (windows/runner/resources/app_icon.ico): the full square, each size made from the
    whole picture and kept as a PNG inside the file."""
    picture.save(os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico'), format='ICO',
                 sizes=[(n, n) for n in WINDOWS_SIZES])


def ios_icons(picture):
    """The iPhone app's icon (ios/Runner): the full square, with no alpha, at each size its catalog names. iOS rounds
    the corners itself."""
    import json
    folder = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    for entry in json.load(open(os.path.join(folder, 'Contents.json')))['images']:
        side = round(float(entry['size'].split('x')[0]) * int(entry['scale'][0]))
        picture.resize((side, side), LANCZOS).save(os.path.join(folder, entry['filename']), optimize=True)


def extension_icons(picture):
    """The browser extension's icon (extension/icons, and the copy its store page shows): the square with its
    corners rounded, as a browser's toolbar and its extensions page draw nothing round an icon themselves."""
    from PIL import ImageDraw
    folder = os.path.join(ROOT, 'extension', 'icons')
    big = 4
    for size in (16, 48, 128):
        mask = Image.new('L', (size * big, size * big), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * big - 1, size * big - 1), radius=round(size * big * 0.2), fill=255)
        icon = picture.resize((size, size), LANCZOS).convert('RGBA')
        icon.putalpha(mask.resize((size, size), LANCZOS))
        icon.save(os.path.join(folder, f'{size}.png'), optimize=True)
    shutil.copyfile(os.path.join(folder, '128.png'), os.path.join(ROOT, 'extension', 'store', 'promo', 'icon-128.png'))


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--check':
        return check_built(sys.argv[2])
    if len(sys.argv) > 1:
        os.makedirs(os.path.dirname(ART), exist_ok=True)
        shutil.copyfile(os.path.expanduser(sys.argv[1]), ART)
    picture = clean(Image.open(ART))
    far = farthest(picture)
    if far * SCALE * FULL_DP > SAFE_DP:
        raise SystemExit(f'the mark reaches {far:.1%} of the picture from its middle: at SCALE {SCALE} that is '
                         f'{far * SCALE * FULL_DP:.1f}dp, outside the {SAFE_DP}dp a home screen is sure to show')
    if far * WEB_SAFE > WEB_SURE:
        raise SystemExit(f'the mark reaches {far:.1%} of the picture from its middle: at WEB_SAFE {WEB_SAFE} a home '
                         f'screen that cuts icons to a circle would cut it')
    for density, size in DENSITIES.items():
        folder = os.path.join(RES, 'mipmap-' + density)
        os.makedirs(folder, exist_ok=True)
        shrunk(picture, size, 'foreground').save(os.path.join(folder, 'ic_launcher_foreground.png'), optimize=True)
        shrunk(picture, size, 'monochrome').save(os.path.join(folder, 'ic_launcher_monochrome.png'), optimize=True)
    for density, size in SMALL.items():
        folder = os.path.join(RES, 'drawable-' + density)
        os.makedirs(folder, exist_ok=True)
        silhouette(picture, size).save(os.path.join(folder, 'ic_stat_ghost.png'), optimize=True)
    # The page: its icon in a browser's tab and on a phone's home screen, and the mark at its top.
    picture.resize((512, 512), LANCZOS).save(os.path.join(SITE, 'icon.png'), optimize=True)
    picture.resize((180, 180), LANCZOS).save(os.path.join(SITE, 'apple-touch-icon.png'), optimize=True)
    # The app in a browser: its tab's icon and its manifest's.
    web_icons(picture)
    # In the app: the mark on the setup screen.
    os.makedirs(os.path.join(ROOT, 'assets', 'art'), exist_ok=True)
    silhouette(picture, 256).save(os.path.join(ROOT, 'assets', 'art', 'ghost-mark.png'), optimize=True)
    # The Mac app's icon (macos/, the desktop companion), in the outline macOS draws whole (mac_icon).
    for size in (16, 32, 64, 128, 256, 512, 1024):
        icon = mac_icon(picture, size)
        if not has_colour(icon):
            raise SystemExit(f'the Mac icon at {size} is all grey: macOS would draw it small on a plate (mac_icon)')
        icon.save(os.path.join(MAC, f'app_icon_{size}.png'), optimize=True)
        # Linux's menus and docks draw an icon as it is, so its is the Mac's, outline and shadow and all
        # (the package puts it in hicolor/512x512: .github/workflows/messaging-linux.yml).
        if size == 512:
            icon.save(os.path.join(ROOT, 'linux', 'packaging', 'ghost-messaging.png'), optimize=True)
    windows_icon(picture)
    ios_icons(picture)
    extension_icons(picture)
    print('icons written from', ART)


if __name__ == '__main__':
    main()
