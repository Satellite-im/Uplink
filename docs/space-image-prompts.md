# Space images for the Uplink website

Matt, 2026-11-27: "Redo the whole website with branding geared towards uplink, remove the ghost images and give me
space type images prompts to generate".

The site (site/) has a slot for each picture below. Until a file exists, its page shows a starfield drawn in code, so
nothing is broken while they are missing. Generate each, save it at the path given (convert to WebP; the share card is
a JPEG), and the page picks it up.

## The look all of them share

Add this to the end of every prompt, so the set reads as one family and sits with Uplink's black-and-white logo:

> cinematic space illustration, near-black deep space background, crisp white highlights, monochrome with only a faint
> cool blue glow, high contrast, clean modern minimal composition, lots of empty dark space for text, sharp details,
> subtle film grain, no text, no letters, no logos, no watermark

Keep the left or right third quiet (mostly empty space) where the page sets words over the picture: each prompt says
which side.

## The pictures

| File | Size | Where it shows |
|---|---|---|
| `site/art/space/hero.webp` | 2400×1350 | Behind the top of the landing page |
| `site/art/space/og.jpg` | 1200×630 | The card shown when gogho.st is shared |
| `site/art/space/messages.webp` | 1600×1000 | Landing: texts and chats |
| `site/art/space/calls.webp` | 1600×1000 | Landing: voice and video |
| `site/art/space/networks.webp` | 1600×1000 | Landing: Telegram, Signal and the rest beside your texts |
| `site/art/space/desktop.webp` | 1600×1000 | Landing: the computer app |
| `site/art/space/privacy.webp` | 1600×1000 | Landing: sealed end to end |
| `site/art/space/effects.webp` | 1600×1000 | Landing: effects, reactions, stickers |
| `site/art/space/join.webp` | 1600×1000 | Behind the invite and join pages |

**hero.webp**: the uplink itself.
> A lone satellite dish on a dark rocky ridge at night, sending a single thin, bright white beam of light straight up
> into a vast starfield, the beam sharp as a needle and slightly angled forward, a faint arc of a planet's horizon
> glowing at the bottom edge, the Milky Way soft behind; the right half of the frame mostly empty sky. Ultra-wide.

**og.jpg**: the share card.
> A small white communications satellite in orbit above the curve of a dark planet, one bright beam of light rising
> from the planet's surface to the satellite, stars all around; the satellite and beam in the right third, the left
> two thirds dark empty space.

**messages.webp**: messages travelling.
> Dozens of tiny glowing points of light travelling in graceful arcs between a dark planet and a ring of satellites,
> like messages in flight, leaving faint thin trails; composition weighted to the right, left side dark.

**calls.webp**: voices across space.
> Two distant planets facing each other across space, a soft rippling wave of light passing between them like a sound
> wave, concentric rings fading outward; centered, with dark space above and below.

**networks.webp**: many networks, one place.
> A constellation of small satellites of different shapes and sizes all linked by thin white lines into one network
> around a single bright central satellite, like a star map; weighted to the left, right side dark.

**desktop.webp**: the big screen.
> A huge dark observatory window looking out onto a starfield and a ringed planet, the edge of a sleek desk and a glowing
> screen silhouetted in the foreground, calm and quiet; the left third dark.

**privacy.webp**: sealed.
> A small sealed capsule of light travelling through a dark tunnel of stars, wrapped in a faint geometric shield of
> thin white lines, nothing else near it; centered, lots of dark space around.

**effects.webp**: the fun part.
> A bright burst of a nebula exploding in white and pale blue light, streaks and sparks flying outward like fireworks
> in zero gravity, shooting stars crossing the frame; weighted to the right.

**join.webp**: an invitation.
> A narrow beam of white light reaching down from a starfield to a single small landing pad on a dark moon surface,
> like a signal calling someone in, long soft shadows; the top half open sky for the page's words.

## Retro-futuristic styles (Matt, 2026-11-27: "a few different styles of images for the assets that match the style of uplink and satellite.im with a retro futuristic vibe")

Satellite's own art, which these match: the Uplink logo (a black, forward-slanted speech-bubble sticker with a white
inset outline and an upward needle) and Satellite's mascot (a chibi space cat in a teal hood, purple headphones and a
gold crystal on its forehead, drawn with thick purple outlines and flat cel shading in teal, butter yellow, purple
and orange). Each style below is one line to put after any subject above, in place of the shared look. Keep one style
for the whole set.

**1. Space-age screen print (1960s mission poster)**
> retro-futuristic 1960s space-age poster, screen-printed look with halftone dots and slight ink misregistration,
> limited palette of deep teal, butter yellow, purple and burnt orange on near-black, bold flat shapes, forward-slanted
> speed lines, clean geometric composition, no text

**2. Retro anime cel (90s sci-fi OVA)**
> 1990s retro sci-fi anime cel, hand-painted backgrounds, flat cel shading with thick purple outlines, teal and butter
> yellow with purple shadows and orange highlights, glowing CRT-style screens, starfield, soft film grain, no text

**3. Sticker sheet, ink and screentone (the logo's own look)**
> bold black-and-white sticker illustration, thick ink outlines, die-cut white border, manga screentone shading,
> forward-leaning angular shapes, one sharp upward needle of light, high contrast, retro sci-fi comic style, no text

**4. Synth-wave chrome (80s)**
> 1980s retro-futurism, chrome and neon, purple and teal glow with orange sunrise, perspective grid fading into the
> stars, airbrushed highlights, VHS scanlines, dramatic, no text

**5. 16-bit pixel art**
> 16-bit pixel art, limited palette of teal, butter yellow, purple and orange on deep navy-black, crisp pixels, dithered
> gradients, retro console game title screen feel, twinkling stars, no text, no anti-aliasing

**6. Retro toy diorama (soft 3D)**
> retro-futuristic soft 3D diorama, glossy toy-like plastic and rounded chrome, teal and butter yellow bodies with purple
> accents and orange lights, tiny tilt-shift miniature look, studio lighting on a dark starry backdrop, no text

**Satellite's cat in the pictures (optional):** add
> featuring a small chibi space cat mascot in a teal hood with pointed ears, big purple eyes, chunky purple headphones
> and a gold crystal on its forehead

to a subject (it works best with styles 2, 5 and 6): piloting the satellite in the hero, holding a glowing envelope in
messages, wearing its headphones with sound waves in calls, sitting in front of the observatory screen in desktop,
inside the sealed capsule in privacy, riding a firework in effects, waving from the landing pad in join. Give the tool
Satellite's own mascot picture (in the Uplink repository, ui/extra/images/mascot/idle.png) as a character reference so
it stays the same cat.

## Tips

- Generate at the size listed (or the nearest the tool offers at the same shape) and crop to fit.
- Midjourney: add `--ar 16:9` for the hero, `--ar 1.91:1` for the share card, `--ar 8:5` for the rest, and
  `--style raw --no text, letters, logo`.
- Give the tool the hero you like best as a style reference for the rest (Midjourney `--sref`), so they match.
- Convert to WebP (the share card stays JPEG): `cwebp -q 82 in.png -o hero.webp`.
