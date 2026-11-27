# Uplink effect sprites: prompts for Nano Banana 3

Twenty-one images: one reference sheet of the ghost, then one sprite sheet for each of the twenty message effects.

An image model makes stills, not animation, so these are **sprites**: separate little pictures on a flat background.
The app cuts each sheet into its sprites and moves them itself (rising, falling, bursting), in place of the emoji and
plain shapes it draws today.

## How to use this

1. Settings for every image: **aspect ratio 1:1**, the **highest resolution** on offer (2K or 4K), PNG.
2. Generate **0. The reference sheet** first. Keep it.
3. For each effect, start a new request, **attach the reference sheet**, and paste **The style block** followed by
   that effect's block.
4. Save each result under the file name its block gives, all in one folder (say `~/Desktop/ghost-effects/`).
5. Check each one against **What to look for** at the bottom, and regenerate the ones that fail.
6. Hand the folder back and the sprites get cut out and built into the app.

If your tool can export a truly transparent background, use it and delete the BACKGROUND line's green from the style
block. If it can't, leave the green: it is keyed out afterwards.

---

## The style block (paste at the top of every request)

```
You are drawing a sprite sheet for a mobile messaging app. The app cuts the sheet into separate sprites and animates
them itself, so every sprite must be one complete, separate object.

CHARACTER: the Uplink ghost, exactly as in the attached reference sheet. A small, friendly, rounded cartoon
ghost: matte white body, two simple oval black eyes, no mouth unless the pose needs one, a scalloped hem of three
curves, no arms unless the pose needs them (then short mitten-like hands). A solid indigo-violet rim (#8C95FF) runs
round its whole silhouette, about 2% of its width.

STYLE: flat, clean, modern, vector-like 3D with soft shading inside each shape. No outlines other than the rim. Bright,
friendly, a little mischievous, never scary.

PALETTE: indigo #4F5BD5, indigo-violet #8C95FF, violet #C77DFF, pale blue-teal #7FE3D4, coral #FF7A6B, rose #FF7AA8,
gold #FFC94D, white, near-black #16181D. Never use green of any kind inside a sprite.

BACKGROUND: one flat colour, pure chroma green #00FF00, from edge to edge. No gradient, no texture, no vignette, no
floor, no horizon, and no shadow cast onto the background.

LAYOUT: exactly 12 sprites in a grid of 4 columns and 3 rows, evenly spaced, one sprite in each cell, centred in its
cell. Sprites never touch or overlap each other or the edge of the canvas: clear green shows all the way round every
sprite. No grid lines, borders, labels, numbers, captions, watermark or text of any kind.

ROW 1: four ghost characters, each filling most of its cell.
ROWS 2 AND 3: eight small props, each filling about two thirds of its cell.

EDGES: crisp, clean silhouettes. No motion blur, no smoke, no haze, no see-through parts, no soft glow spilling onto
the background. Anything that should glow is drawn as a solid lighter shape with a hard edge.

BOTH THEMES: these sprites are shown over a near-white page and over a near-black page. Every white or very pale
shape carries the solid indigo-violet rim. Every near-black shape carries a thin pale rim.

Square image, 1:1, at the highest resolution available.
```

---

## 0. The reference sheet

Save as `ghost-reference.png`. Do not attach anything to this one. Paste the style block, then:

```
A character reference sheet of the ghost alone, in place of the 12-sprite layout: the same ghost drawn 9 times in a
3 by 3 grid, each separate on the green background.
Row 1: front view, three-quarter view facing left, three-quarter view facing right.
Row 2: happy (eyes closed in upward curves), surprised (eyes wide and round), sleepy (eyes half closed).
Row 3: waving with one mitten hand, both arms raised cheering, curled up small.
Identical proportions, rim, eyes and hem in all nine.
```

---

## 1. Balloons (happy birthday)

Save as `balloons.png`.

```
ROW 1: a ghost shaped like an inflated balloon, round, with a knot and a string at its hem, smiling. A ghost floating
up holding one balloon's string and waving. A balloon-shaped ghost tilted to the left. A ghost hugging a balloon
bigger than itself.
ROWS 2 AND 3: five glossy party balloons with short strings, one each in indigo, violet, pale blue-teal, coral and
gold. One small balloon shaped like a ghost. One curled party streamer in violet. One small gold star.
```

## 2. Confetti (congratulations)

Save as `confetti.png`.

```
ROW 1: a ghost flinging a handful of confetti upward with both arms. A ghost popping up with both arms raised,
cheering. A ghost blowing a striped party horn. A ghost holding a small confetti cannon that has just fired.
ROWS 2 AND 3: confetti pieces drawn large, one per cell: a tiny ghost silhouette in indigo, a tiny ghost silhouette
in pale blue-teal, a five-point star in gold, a five-point star in coral, a curled ribbon in violet, a curled ribbon
in rose, a tilted paper rectangle in coral, a tilted paper square in gold.
```

## 3. Celebration (lunar new year, Eid)

Save as `celebration.png`.

```
ROW 1: a ghost carrying a glowing red paper lantern on a short stick. A ghost holding a lit sparkler. The head of a
friendly ribbon dragon made of little linked ghosts. A ghost holding up a large gold coin with both hands.
ROWS 2 AND 3: a red paper lantern with a gold tassel. A gold coin with a square hole. A red envelope with a gold
seal. A starburst of gold sparks drawn as a solid flat shape. A short string of red firecrackers. A gold lucky knot.
A small four-point gold spark. A small four-point coral spark.
```

## 4. Fireworks (happy new year)

Save as `fireworks.png`.

```
ROW 1: a tiny ghost riding a firework rocket upward, holding on tight. A ghost covering where its ears would be,
grinning. A ghost pointing up with its eyes wide. A ghost holding a sparkler above its head.
ROWS 2 AND 3: five firework bursts, each a flat starburst of rays and dots with a hard edge, one each in indigo,
violet, pale blue-teal, gold, and white with the indigo-violet rim. One burst whose sparks form the outline of a
ghost's head and hem. One firework rocket with a striped body. One short curved trail of sparks.
```

## 5. Kisses (xoxo, mwah)

Save as `kisses.png`.

```
ROW 1: a blushing ghost puckering up. A ghost blowing a kiss from its mitten hand. A ghost with heart-shaped eyes.
A giggling ghost with its eyes squeezed shut and a hand over its mouth.
ROWS 2 AND 3: three glossy coral lip-prints, each at a different tilt and size. A small rose heart. A small coral
heart. A small violet heart. A four-point gold sparkle. A cluster of three tiny hearts.
```

## 6. Hearts (I love you)

Save as `hearts.png`.

```
ROW 1: a blushing ghost hugging a large rose heart. Two ghosts side by side whose hems curl together into a heart
shape (draw the pair as one sprite). A ghost with heart-shaped eyes, hands on its cheeks. A ghost floating up under
a heart-shaped balloon.
ROWS 2 AND 3: six soft glossy hearts, each a different size and tilt: two rose, two coral, two violet. One heart
with a tiny ghost face on it. One four-point rose sparkle.
```

## 7. Snow (it's snowing, merry Christmas)

Save as `snow.png`.

```
ROW 1: a ghost in a knitted scarf and bobble hat, arms out, looking up. A ghost curled up as a snowflake, with a
six-point frost pattern round it. A ghost built like a snowman, with a carrot nose and coal buttons. A ghost catching
a snowflake on its tongue.
ROWS 2 AND 3: five snowflakes, each a different six-point design, white with a blue-violet edge. One soft round puff
of snow with the same edge. One tiny ghost shaped like a snowflake. One small pale-blue ice crystal.
```

## 8. Lasers (pew pew)

Save as `lasers.png`. The beams themselves are drawn by the app.

```
ROW 1: a ghost wearing tiny mirrored rave sunglasses, facing front, looking cool. A ghost making a finger-gun pose
to the left. A ghost making a finger-gun pose to the right. A ghost DJ wearing headphones, one hand on a turntable.
ROWS 2 AND 3: three small star flashes, one each in magenta, cyan and yellow. Two zigzag lightning bolts, one cyan
and one magenta. One neon ring in cyan. One small burst of short rays in yellow. One pair of mirrored rave
sunglasses on their own.
```

## 9. Ghosts (boo, happy Halloween)

Save as `ghosts.png`.

```
ROW 1: a large ghost saying a silent "boo": eyes wide, mouth a small round o, hem-hands raised. A ghost peeking in
from the side, only its upper half, leaning. A giggling ghost with its eyes closed. A small ghost swooping in a
curve, its hem trailing.
ROWS 2 AND 3: four small ghosts, each in a different pose and size. One cheerful jack-o'-lantern with a ghost-shaped
grin. One wisp of violet mist drawn as a solid flat curl. One small wrapped sweet in coral and gold. One tiny bat
with a pale rim.
```

## 10. Wow

Save as `wow.png`.

```
ROW 1: a ghost with huge star-shaped eyes and its hem flared out in shock. A ghost with its mouth dropped wide open.
A ghost with both mitten hands on its cheeks. A ghost with a small puff rising from the top of its head.
ROWS 2 AND 3: a comic-book starburst of rays in gold. A second starburst in coral. Three four-point sparkles, one
each in indigo-violet, gold and coral. Two bold exclamation marks drawn as plain shapes (a tapered bar over a dot),
one indigo and one coral. One small spinning star in gold.
```

## 11. Thank you

Save as `thanks.png`.

```
ROW 1: a ghost holding out a small bouquet and bowing, its eyes closed in happy curves. A ghost with its mitten
hands pressed together. A ghost offering a single tulip. A ghost hugging a little flower pot.
ROWS 2 AND 3: a round blossom in rose. A round blossom in violet. A tulip in coral with a short stem. A small tied
bouquet. Two loose petals, one rose and one violet. One four-point gold sparkle. One small gold heart.
```

## 12. Good night

Save as `goodNight.png`.

```
ROW 1: a sleepy ghost in a tiny striped nightcap, hugging a pillow and yawning. A baby ghost asleep, curled up on a
small cloud (draw ghost and cloud as one sprite). A ghost holding a small teddy bear. A ghost wearing a sleep mask
pushed up on its head.
ROWS 2 AND 3: a crescent moon in soft gold. Three stars in gold, each a different size. Three sleep marks, each a
plain zigzag "Z" shape in indigo-violet, small, medium and large. One small pale cloud with the rim.
```

## 13. Good morning

Save as `goodMorning.png`.

```
ROW 1: a ghost stretching awake with both arms up, its nightcap slipping off. A perky ghost holding a steaming
coffee cup. A ghost with tiny wings, fluttering like a songbird. A ghost in round sunglasses, one hand raised in
greeting.
ROWS 2 AND 3: a sun with short rays in gold. A sunflower. A coffee cup with a curl of steam drawn as a solid shape.
A small round songbird in coral. A croissant. A small pale cloud with the rim. A musical note in indigo. A four-point
gold sparkle.
```

## 14. Get well soon

Save as `getWell.png`.

```
ROW 1: a ghost wearing a tiny nurse's cap with a heart on it, carrying a steaming bowl of soup. A ghost holding a
bunch of tulips. A ghost hugging a hot-water bottle. A ghost wrapped in a blanket, only its face showing, smiling.
ROWS 2 AND 3: two soft yellow hearts, different sizes. Two sticking plasters with a tiny heart pattern, at different
tilts. A cup of tea with a slice of lemon. A bowl of soup. A single tulip in coral. A small jar of honey.
```

## 15. Bye bye

Save as `bye.png`.

```
ROW 1: a ghost waving with its left mitten hand. A ghost waving with its right mitten hand. A ghost waving with
both hands. A ghost floating away, looking back over its shoulder and waving.
ROWS 2 AND 3: a single waving mitten hand. A paper aeroplane in pale blue-teal. A small suitcase in coral. A tiny
ghost waving, very small. Two four-point sparkles, one gold and one indigo-violet. A small cloud puff with the rim.
A small rose heart.
```

## 16. Hungry

Save as `hungry.png`.

```
ROW 1: a wide-eyed ghost with its mouth open and a drop of drool. A ghost swollen round and content, patting its
belly. A ghost holding a fork in one hand and a knife in the other. A ghost reaching up after a doughnut just out of
reach (draw ghost and doughnut as one sprite).
ROWS 2 AND 3: a slice of pizza. A burger. A taco. A bowl of noodles with chopsticks. A carton of fries. A doughnut
with rose icing. A piece of sushi. A chicken drumstick.
```

## 17. Sorry

Save as `sorry.png`.

```
ROW 1: a small ghost holding a single drooping flower, looking up with enormous watery eyes. A ghost under a little
grey rain cloud (draw ghost and cloud as one sprite). A shy ghost half hidden behind its own hem. A ghost holding out
a small heart with both hands.
ROWS 2 AND 3: three blue raindrops, each a different size. One small grey cloud with a pale rim. One drooping
flower. One blue heart. One single teardrop with a highlight. One tiny rose heart.
```

## 18. Party time

Save as `party.png`.

```
ROW 1: a ghost in a party hat dancing, one arm up. A ghost in a party hat dancing, leaning the other way, both arms
out. A ghost moonwalking, facing left. A ghost spinning, its hem flared out round it.
ROWS 2 AND 3: a mirrored disco ball. Two musical notes, one indigo and one coral. A striped party hat. Three round
light spots drawn as flat solid discs, one each in magenta, cyan and gold. One curled streamer in violet.
```

## 19. Echo

Save as `echo.png`. The app still draws the message's own words; these go with them.

```
ROW 1: a ghost cupping its mitten hands round its mouth, calling out. The same ghost drawn smaller and paler, a
lighter flat tint, not see-through. The same again, smaller and paler still. A ghost with one hand behind where its
ear would be, listening.
ROWS 2 AND 3: three curved sound-wave arcs in indigo-violet, small, medium and large. Three more in pale blue-teal,
small, medium and large. Two tiny pale ghosts, different sizes.
```

## 20. Spotlight

Save as `spotlight.png`. The app still dims the page and draws the light; these go with it.

```
ROW 1: a ghost perched on a ledge aiming a theatre spotlight down to the right. The same, aiming down to the left.
A ghost taking a deep bow. A ghost in a tiny top hat with its arms spread wide.
ROWS 2 AND 3: a theatre spotlight lamp on its own. Three dust motes drawn as small four-point sparkles in gold,
different sizes. A single red rose with a short stem. A five-point gold star. A red velvet curtain tassel. A small
ticket stub with no writing on it.
```

---

## What to look for

Regenerate a sheet when any of these is true:

- A sprite touches another sprite or the edge of the image.
- The background is not one flat green: there is a gradient, a floor, a shadow or a glow on it.
- There are letters, numbers, labels or grid lines.
- A sprite contains green.
- The ghost doesn't match the reference sheet.
- A white shape has no rim (it would vanish on the light theme).

Twelve sprites exactly is the aim. Eleven or thirteen good ones is fine: the cutting finds each sprite by its shape,
not by counting cells.
