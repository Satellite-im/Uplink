# Message effects

Every effect Uplink can play, what sets each off, and a prompt for generating its overlay (Matt, 2026-11-13:
"a list for me of all the special effects so I can generate some graphics / videos for them to be overlays make sure
each one has a prompt make it ghost themed", then "make sure we support all the same ones as imessage, samsung
messenger, google messenger").

A set of prompts for an image model (still sprites the app moves itself, where the prompts below are for animated
overlays) is in [effect-sprites-prompt.md](effect-sprites-prompt.md). Matt made a sheet for each of the twenty with
it, and since 0.6.0 the app plays them (Matt, 2026-11-13: "the ghost messages assets are on the desktop, please wire
them all and slice them up"): see "The effects' sprites" below.

## Where the set comes from

| App | What it has | Here |
| --- | --- | --- |
| iMessage | Eight screen effects: Echo, Spotlight, Balloons, Confetti, Love, Lasers, Fireworks, Celebration. Four bubble effects: Slam, Loud, Gentle, Invisible Ink | All twelve. An iPhone sending one to a non-iPhone writes "(sent with Lasers)" after the words: that is read, played, and not shown |
| Google Messages | Screen effects on a phrase, such as "It's snowing", "I love you", "Happy birthday", "Congratulations", "Wow", "Kisses", "Thank you", "Good night", "Good morning", "Get well soon", "Bye bye", "I'm hungry", "Sorry", "Party time" | One for each. Google has not published its list, so these are the widely reported ones |
| Samsung Messages | No keyword effects of its own | Nothing to match |
| Uplink | | `ghosts`, for "Boo" and Halloween |

An effect plays once when a message that sets it off arrives or is sent while the conversation is open, and again
from the message's long-press menu ("Play effect"). Settings › Look › Message effects turns them all off, and so does
Android's "Remove animations". The other person sees an effect only if their own app plays one for the same words.

## The effects' sprites

A sheet is a square picture named for its effect (`balloons.png`) with about twelve sprites on a clear background:
ghost characters in the top row, props under them.

    python3 tool/effect_sprites.py ~/Desktop/ghost_messages_assets

keeps each sheet in `art/effects/` (a WebP that loses nothing drawn, with the background remover's faint halo
cleared, a quarter of the PNG's weight) and cuts it into `assets/effects/<effect>-h1.webp…` (characters, 300 px) and
`<effect>-p1.webp…` (props, 200 px). The cutting goes by shape: what is solid is gathered into pieces that touch,
small pieces near a large one join it (a ghost and the dashes drawn round it), parts of a like size in one place of
the sheet's four-by-three are one sprite (three sound waves), and a speck on its own is dropped. A neighbour's corner
inside a sprite's box is masked out. `build/effect-sprites/<effect>.png` shows every cut, to look over after a run.
With no folder named, the sheets already in `art/effects/` are cut again.

### The characters, moving

Matt, 2026-11-13: "6 frame animations for each asset in a sprite sheet". Each character has a sheet of its own,
`<effect>_r1c<n> · <what it does>.png`: one motion (a wave, a sip, a wobble) drawn six times, three across and two
down, on a clear background. `r1c<n>` is the character's place on the effect's still sheet, which is cut as
`<effect>-h<n>.webp`.

    python3 tool/effect_anims.py ~/Desktop/Animated

finds each drawing by its shape (`effect_sprites.cut_grid`) and lays the six side by side as they stood in their
places: `assets/effects/<effect>-a<n>.webp`, with a picture of each strip in `build/effect-anims/` to look over. As
a character flies, the app shows the drawing its time has come to, eight a second (`EffectSprite`, `lib/effects.dart`),
each character starting on a drawing of its own. A character with no sheet keeps its still: of the eighty, balloons'
first and confetti's second are not drawn yet. 78 strips, 5.5 MB. The sheets themselves (a quarter of a gigabyte)
are not kept in the repository.

The app finds an effect's pictures by name (`EffectSprites.of`, `lib/effects.dart`), decodes them the first time the
effect plays and keeps the last three effects' decoded. `_spritePlans` says how each effect's move: how many props
and characters, and whether they rise, fall or burst. Props are many and small (confetti and snow smaller still, and
tumbling); characters are few, large and slower. Under them stays what only the app can draw: the light of fireworks
and lasers, the spotlight, and Echo's copies of the message's own words. An effect whose pictures are missing is
drawn with shapes and emoji as before. `test/screens_test.dart` holds every effect to having characters and props,
and draws a frame of each with them (`test/shots/6-effect-*.png`).

To change an effect's look, draw its sheet again with the prompt, run the tool, and look at the cuts. The stickers
(`tool/sticker_packs.py`) are made from the same sheets' characters, so run that after.

## How an overlay replaces the drawn effect

Until an overlay exists, the app draws each screen effect itself with shapes and emoji (`lib/effects.dart`). To
replace one, add a file named for the effect's id to `assets/effects/` and rebuild. Nothing else changes: the app
looks for the file by name.

| | |
| --- | --- |
| File | `assets/effects/<id>.webp`, an **animated WebP with transparency** (ids below, exactly as written, e.g. `goodNight.webp`) |
| Canvas | 1080 × 2400 px, portrait. It is scaled to cover the conversation, so keep anything that matters inside the middle 1080 × 1800 |
| Background | Fully transparent. No backdrop, no floor shadow: the conversation shows through |
| Length | The "Length" in the tables. Plays once, no loop. The app fades the last 12% out, so the final frames can simply continue the motion |
| Frame rate | 30 fps is plenty. Aim for under 3 MB a file |
| Legibility | Messages are read through it: keep the densest moment short, and the centre lighter than the edges |
| Both themes | It plays over a near-white page and a near-black one. Give light shapes a soft coloured edge or glow so they show on white |

Most video generators can't output transparency. Generate on a flat pure-green (#00FF00) background (pure black for
the glowing ones, as their prompts say), key it out, then export as animated WebP. From a keyed PNG sequence:
`img2webp -loop 1 -d 33 -lossy -q 80 frame_*.png -o ghosts.webp`. From a video with alpha:
`ffmpeg -i in.mov -vf "fps=30,scale=1080:2400" -loop 1 -c:v libwebp_anim -lossless 0 -q:v 75 ghosts.webp`.

`echo` and `spotlight` depend on the message itself (its words, where it sits), so they stay drawn by the app; their
prompts below are for optional decoration layered over what the app draws. The four bubble effects animate the
message's own bubble and take no overlay.

## The shared look

Paste this in front of every prompt so the set reads as one family:

> Uplink brand style: a small, friendly, rounded cartoon ghost mascot, matte white with a soft
> indigo-violet (#8C95FF) rim glow, two simple oval black eyes, no mouth unless smiling, a scalloped hem of three
> curves, no arms unless the action needs them. Flat, clean, modern vector-like 3D with soft shading, no outlines, no
> text, no logos. Portrait 9:16, 1080x2400. Isolated on a pure flat chroma green (#00FF00) background with no
> shadows, no floor and no gradient, so it can be keyed to transparency. Elements enter from off-screen and leave
> off-screen; the centre of the frame stays mostly clear.

## Screen effects

Words match whole words only ("boo" does not fire on "book"), in any letter case, anywhere in the message. Emoji set
an effect off only in a message of nothing but emoji. If a message matches several, the first in this table wins.

| Id | Effect | Like | Words | Emoji | Length |
| --- | --- | --- | --- | --- | --- |
| `balloons` | Balloons | iMessage | happy birthday, happy bday, happy b-day | 🎂 🎈 🥳 | 4.6 s |
| `confetti` | Confetti | iMessage, Google | congratulations, congrats, felicitations, well done, you did it, we did it | 🎉 🎊 🏆 | 3.6 s |
| `celebration` | Celebration | iMessage | happy lunar new year, happy chinese new year, gong xi fa cai, happy eid, eid mubarak | 🧧 🐉 🏮 | 4.2 s |
| `fireworks` | Fireworks | iMessage | happy new year, happy 4th, happy fourth of july, happy diwali | 🎆 🎇 🧨 | 4.2 s |
| `kisses` | Kisses | Google | kisses, xoxo, mwah | 💋 😘 😚 | 4.0 s |
| `hearts` | Hearts (Love) | iMessage, Google | i love you, love you, love u, happy valentine, happy anniversary, miss you | ❤️ 😍 🥰 💕 💖 💗 💘 💝 💞 | 4.0 s |
| `snow` | Snow | Google | it's snowing, let it snow, merry christmas, happy holidays, snow day | ❄️ ☃️ ⛄ 🎄 | 6.0 s |
| `lasers` | Lasers | iMessage | pew pew | | 3.0 s |
| `ghosts` | Ghosts | ours | boo, happy halloween, trick or treat, spooky | 👻 🎃 | 4.6 s |
| `wow` | Wow | Google | wow, woah, whoa | 🤩 🤯 😮 | 2.6 s |
| `thanks` | Thank you | Google | thank you so much, thanks so much, thank you very much, many thanks | 🙏 💐 | 4.2 s |
| `goodNight` | Good night | Google | good night, goodnight, sweet dreams, nighty night | 🌙 😴 💤 🌛 | 5.0 s |
| `goodMorning` | Good morning | Google | good morning, rise and shine | ☀️ 🌅 🌞 🌄 | 4.4 s |
| `getWell` | Get well soon | Google | get well soon, feel better soon, feel better | 🤒 🩹 🤧 | 4.4 s |
| `bye` | Bye bye | Google | bye bye, bye-bye, goodbye, see you later | 👋 | 3.6 s |
| `hungry` | Hungry | Google | i'm hungry, so hungry, i'm starving | 🍕 🍔 🌮 🤤 | 4.2 s |
| `sorry` | Sorry | Google | i'm sorry, so sorry, i apologize | 🥺 😢 😭 | 4.4 s |
| `party` | Party time | Google | party time, let's party | 🪩 🕺 💃 | 4.2 s |
| `echo` | Echo | iMessage | only "(sent with Echo)" from an iPhone, or Play effect | | 3.6 s |
| `spotlight` | Spotlight | iMessage | only "(sent with Spotlight)" from an iPhone, or Play effect | | 3.4 s |

A plain "thanks" sets nothing off on purpose: it is said too often to be an occasion.

### `balloons`

- **Drawn now:** 16 glossy balloons with strings rising from the bottom, drifting side to side.
- **Prompt:**
  > [shared look] A drift of balloons rises from below the frame and floats up and out of the top. Half are ordinary
  > glossy balloons in indigo, violet, mint, coral and gold; the other half are balloon-shaped ghosts, round and
  > inflated with a knot and a string at the hem, smiling. One small ghost rides up holding a single balloon's string
  > and waves. Gentle side-to-side sway, strings trailing. 4.6 seconds, slow and buoyant, no loop.

### `confetti`

- **Drawn now:** 140 small coloured rectangles tumbling down from the top, swaying and flipping.
- **Prompt:**
  > [shared look] Three little ghosts pop up from the bottom corners and fling handfuls of confetti upward. The
  > confetti pieces are tiny ghost silhouettes, stars and ribbons in indigo, violet, mint, coral and gold. The confetti
  > bursts up, fills the frame, then tumbles and flutters down past the camera and out of the bottom. The ghosts duck
  > back out of frame in the first second. 3.6 seconds, energetic then settling, no loop.

### `celebration`

- **Drawn now:** twelve bursts of gold, amber and red sparks.
- **Prompt:**
  > [shared look] A festival of warm light: showers of gold and red sparks bloom and cascade down from the upper
  > third like sparklers. Two ghosts carry a string of glowing red paper lanterns across the top of the frame, and a
  > long ribbon-like ghost dragon made of linked little ghosts weaves through once from left to right. Gold coins and
  > sparks drift down and out. 4.2 seconds, festive and warm, no loop. Use a pure black background instead of green
  > for this one, so the glow keys cleanly.

### `fireworks`

- **Drawn now:** seven bursts of sparks in different colours, each opening and falling away.
- **Prompt:**
  > [shared look] Fireworks without the sky: five to seven bursts open one after another in the upper two thirds of
  > the frame, in indigo, violet, mint, gold and white. Each burst blooms into the outline of a ghost for a beat
  > (round head, two dark eye gaps, scalloped hem) before its sparks arc down and fade with glittering trails. A tiny
  > ghost rockets up from the bottom on a spark trail to light the first one. 4.2 seconds, bright pops with soft glow,
  > no loop. Use a pure black background instead of green for this one, so the glow keys cleanly.

### `kisses`

- **Drawn now:** kiss marks, kissing faces and small hearts rising from the bottom.
- **Prompt:**
  > [shared look] Ghosts blowing kisses: four or five blushing ghosts drift up the sides of the frame, each puckering
  > and blowing a kiss toward the centre. Every kiss becomes a glossy coral lip-print that floats up, wobbles and pops
  > into three tiny hearts. One ghost leans in close to the camera, plants a kiss that leaves a lip-print on the
  > "glass", and floats away giggling. 4.0 seconds, sweet and cheeky, no loop.

### `hearts`

- **Drawn now:** 30 pink and red hearts floating up from the bottom, popping in and tilting.
- **Prompt:**
  > [shared look] Soft hearts in rose, coral and violet float up from the bottom of the frame like bubbles. Among
  > them drift three or four blushing ghosts, each hugging a heart. Two ghosts meet in the upper third and their hems
  > curl together into a heart shape, which swells once like a heartbeat, then they drift apart and out of the top.
  > 4.0 seconds, tender and floaty, no loop.

### `snow`

- **Drawn now:** 110 white flakes with a blue-grey edge falling slowly and swaying.
- **Prompt:**
  > [shared look] Gentle snowfall across the whole frame, large soft flakes near the camera and fine ones behind,
  > each with a faint blue-violet edge so it shows on white. Some flakes are tiny ghosts curled up as snowflakes with
  > six-point frost patterns. A ghost in a knitted scarf and bobble hat drifts down slowly through the middle with its
  > arms out, catching flakes, and exits at the bottom. 6.0 seconds, calm and quiet, no loop.

### `lasers`

- **Drawn now:** twelve neon beams sweeping from the top centre in green, magenta, cyan and yellow.
- **Prompt:**
  > [shared look] A ghost wearing tiny mirrored rave sunglasses hovers at the very top centre and fires thin neon
  > laser beams from its eyes down across the frame: electric green, magenta, cyan and yellow, sweeping and crossing
  > like a club light show, with a soft glow along each beam and quick pulses. Two smaller ghosts zip across making
  > finger-gun "pew pew" poses with small star flashes. 3.0 seconds, fast and punchy, no loop. Use a pure black
  > background instead of green for this one, so the glow keys cleanly.

### `ghosts`

- **Drawn now:** 14 white ghosts with an indigo edge rising from the bottom, wobbling as they go.
- **Prompt:**
  > [shared look] A playful haunting: a dozen ghosts of different sizes swoop up from the bottom of the frame in
  > loose S-curves, some peeking in from the left and right edges and ducking back. One large ghost rushes toward the
  > camera, stops, and says a silent "boo" with wide eyes and raised hem-hands, then giggles and floats off. A few
  > small glowing jack-o'-lanterns and wisps of violet mist trail behind them. Everything leaves through the top.
  > 4.6 seconds, bouncy and mischievous rather than scary, no loop.

### `wow`

- **Drawn now:** star-struck faces, sparkles and exclamation marks thrown outward from the middle.
- **Prompt:**
  > [shared look] A ghost shoots up into the middle of the frame, its eyes going huge and star-shaped and its hem
  > flaring out in shock. A ring of comic-style starburst rays, sparkles and bold exclamation-mark shapes explodes
  > outward from behind it to the edges of the frame in indigo, gold and coral, then the ghost drops back down out of
  > view as the sparkles fade. 2.6 seconds, one big snappy beat, no loop.

### `thanks`

- **Drawn now:** folded hands, bouquets, blossoms and sparkles drifting down.
- **Prompt:**
  > [shared look] A shower of flowers: blossoms, tulips and soft sparkles in rose, violet and gold drift down from
  > the top. Three ghosts descend with them, each holding out a small bouquet toward the camera and giving a little
  > bow, eyes closed in a happy curve. The largest ghost offers its bouquet at the centre-bottom, then all drift down
  > and out. 4.2 seconds, warm and graceful, no loop.

### `goodNight`

- **Drawn now:** moons, stars and "zzz" drifting down.
- **Prompt:**
  > [shared look] Bedtime in the air: a crescent moon rises slowly up the right side while small stars twinkle on
  > across the upper frame one by one. A sleepy ghost in a tiny striped nightcap floats down the left side hugging a
  > pillow, yawning, with soft "z" shapes drifting up from it. Two baby ghosts are already asleep, curled on little
  > clouds that drift across the bottom. Deep indigo and soft gold light. 5.0 seconds, slow and drowsy, no loop. Use a
  > pure black background instead of green for this one, so the glow keys cleanly.

### `goodMorning`

- **Drawn now:** suns, sunflowers, coffee cups and little birds rising.
- **Prompt:**
  > [shared look] Sunrise from the bottom edge: a warm golden sun-glow rises from below the frame with soft rays
  > fanning upward. A ghost stretches awake in front of it, arms up, nightcap slipping off, then perks up holding a
  > steaming coffee cup. Two small ghosts flutter past like songbirds with tiny wings, and a few sunflowers pop open
  > along the bottom. 4.4 seconds, fresh and cheerful, no loop.

### `getWell`

- **Drawn now:** tulips, bouquets, plasters, cups of tea and yellow hearts rising.
- **Prompt:**
  > [shared look] A caring visit: a ghost wearing a tiny nurse's cap with a heart on it floats up from the bottom
  > carrying a steaming bowl of soup, followed by two ghosts holding tulips and a hot-water bottle. Soft yellow hearts
  > and little sticking plasters with heart patterns drift up around them. The lead ghost blows gently on the soup and
  > holds it out toward the camera, then they float up and out. 4.4 seconds, gentle and comforting, no loop.

### `bye`

- **Drawn now:** waving hands rising.
- **Prompt:**
  > [shared look] A send-off: five ghosts rise up the frame in a loose line, each turning back toward the camera to
  > wave with a little mitten-like hand, one after another like a wave passing along them. The last and smallest
  > ghost lingers, waves with both hands, then hurries after the others and out of the top, leaving a few fading
  > sparkles. 3.6 seconds, friendly and light, no loop.

### `hungry`

- **Drawn now:** pizza, burgers, tacos, noodles, fries and doughnuts falling.
- **Prompt:**
  > [shared look] It's raining food: pizza slices, burgers, tacos, bowls of noodles, fries and doughnuts tumble down
  > from the top. Three wide-eyed drooling ghosts dart around the frame with their mouths open, catching pieces as
  > they fall; one swallows a whole pizza slice and swells up round and content. The rest of the food falls out of the
  > bottom. 4.2 seconds, greedy and funny, no loop.

### `sorry`

- **Drawn now:** pleading faces, tear drops and blue hearts falling.
- **Prompt:**
  > [shared look] An apology: one small ghost floats down into the centre-bottom holding a single drooping flower,
  > looking up with enormous watery puppy eyes, hem tucked in shyly. Soft blue raindrops fall around it from a little
  > grey cloud that follows above its head. It holds the flower out toward the camera; the cloud parts, a tiny heart
  > rises from the flower, and the ghost drifts down out of frame. 4.4 seconds, small and sincere, no loop.

### `party`

- **Drawn now:** disco balls, music notes, dancers and sparkles falling.
- **Prompt:**
  > [shared look] A disco ball lowers from the top centre, spinning and throwing coloured light spots across the
  > frame in indigo, magenta, cyan and gold. Four ghosts in tiny party hats dance in from the sides, bobbing and
  > spinning in turn, one doing a little moonwalk along the bottom. Music notes and sparkles bounce up around them.
  > The ball rises back out as the ghosts dance off. 4.2 seconds, upbeat with a steady bounce, no loop. Use a pure
  > black background instead of green for this one, so the light keys cleanly.

### `echo`

- **Drawn now:** the message's own words, 26 times over at every size, rising past. Stays drawn by the app.
- **Prompt (optional decoration over it):**
  > [shared look] Echoes of one ghost: a single ghost at the bottom centre cups its hands and calls out, and a dozen
  > translucent copies of itself peel away and drift upward and outward at different sizes, each fainter than the
  > last, like a shout bouncing around a canyon. No words or letters anywhere. 3.6 seconds, airy, no loop.

### `spotlight`

- **Drawn now:** the page dims but for a soft round light low in the conversation, where the newest message is.
  Stays drawn by the app.
- **Prompt (optional decoration over it):**
  > [shared look] A stage moment at the bottom third of the frame only: two ghosts perched in the top corners swing
  > theatre spotlights so their beams cross at the bottom centre, with dust motes glittering in the beams. Nothing in
  > the middle of the frame. 3.4 seconds, dramatic and still, no loop. Use a pure black background instead of green.

## Bubble effects

How one message arrives, from an iPhone's "(sent with Slam)". They animate the bubble itself, so there is nothing to
generate.

| Effect | Set off by | What the bubble does |
| --- | --- | --- |
| Slam | (sent with Slam) | Drops in from large, lands hard and shudders |
| Loud | (sent with Loud) | Swells and shakes, then settles |
| Gentle | (sent with Gentle) | Arrives small and grows slowly to its size |
| Invisible Ink | (sent with Invisible Ink) | Blurred past reading until it is tapped |

## Adding an effect

In `lib/effects.dart`: a name in `ScreenEffect`, its words in `_phrases` and its emoji in `_emoji`, a length in
`_durations`, and something to draw until its overlay exists (a row in `_flights` is enough for one made of emoji).
`test/effects_test.dart` holds the triggers, and `test/screens_test.dart` draws a frame of each into
`test/shots/6-effect-*.png`.
