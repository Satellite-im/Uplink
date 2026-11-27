# Open spaces

Matt, 2026-11-23: "make a new kind of space called a "open space" which has a top down view and lets you move around in
the space so we can hear people louder or quieter depending on where in the space we are, allow creating groups in the
space that display as a targeted circle that expands as more people enter it so you could have different spaces for
games like valorant group casual chat group movie watching etc for now just use avatar profile pictures for the people
with the voice ripple effect, but allow walking around with wasd or arrow keys and plan for a actual character to be
used in the near future like a ghost we can customize with cosmetics".

| Part | Where | What |
| --- | --- | --- |
| The kind | `SpaceKind.open` (`lib/voice/voice.dart`) | A space with a call (`hasVoice`). Its word on the wire is `open` |
| The floor | `lib/voice/open_space.dart` (`OpenSpace`, `OpenWorld`, `SpaceGroup`, `OpenSpaces`) | Everyone's place, the groups, how loud each person is played, walking |
| The gain | `PlacedMedia.setPlaceGain` (`lib/voice/rtc.dart`) | One more gain on a person's sound, under their own volume and the output volume |
| The view | `lib/ui/open_space_view.dart` (`OpenSpaceView`) | The floor from above; keys, a press and a drag walk; groups made and changed |
| Where it is shown | `lib/ui/hangout_screen.dart` | In the people's place on a phone; over the chat in the pane on a wide window |
| Tests | `test/open_space_test.dart`, `test/open_space_view_test.dart` | The floor without a screen; the view (pictures `test/shots/open-space-*`) |

## How it works

It is an ordinary call. Nothing about the connections, the relay or the roster changes, and the relay learns nothing
new: what is said about the floor is sealed with the space's key like everything else in the call's room.

- **`os`**: `{t: 'os', x, y, d, w}`. Where a device stands (whole units of a 2400 by 1600 floor), which way it faces
  in degrees, and `w: 1` while it walks. Said at most ten times a second while walking, once on stopping, every three
  seconds standing still, and at once when someone comes in.
- **`osg`**: `{t: 'osg', g: [{i, n, x, y, h, at, gone}]}`. Groups: id, name, middle, hue, when last changed, and
  `gone: 1` for one taken away. The newest `at` wins for each id; a tie goes to the one taken away, then the greater
  name. Each device keeps what it knows (`open_<room>_groups` in the app's choices) and says it on coming in, so the
  groups outlast an empty room. One taken away is remembered for 14 days.
- **Hearing** (`OpenWorld.gain`): whole within 170 units, falling away by the square to nothing at 760. In the same
  group: whole. One in a group the other is not in: what distance gives, times 0.3.
- **A group's circle** (`OpenWorld.radiusFor`): 130 with nobody in it, plus 38 times the square root of how many are,
  up to 420. Who is inside is counted until it settles, since growing can take in someone at the edge.
- **Older builds.** Alone, a space of a kind a build doesn't know is a voice space (`SpaceKind.of`): everyone is heard
  and nobody is placed. In a circle it is a chat (`CircleSpace.fromJson`), never offered a call. Someone in the call
  who says no `os` stands in the middle (`Place.unsaid`).

- **The walls** (`_FloorPainter._walls` in the view): the floor is a room seen from above and a little in front, its
  walls glass in the app's own colour (`--app-accent`: the bubble colour chosen, else the page's ink): every face a
  see-through wash, every edge a hard line at full strength, as the groups' circles are. The far wall shows its face
  (104 units high, ruled into panels) under its top, the side walls their tops, and the near wall its top and its
  outer face, fainter. They are drawn only, at the floor's own edge. The view stops at them
  (`OpenSpaceView.cameraFor`): it follows this device until an edge of it would pass a wall, then stays.
- **The chat over the floor** (`lib/ui/open_space_chat.dart`, `FloorBubbles`): each message written after the floor
  was opened comes up as a bubble, over the group its writer stands in or at the side of the view for someone in no
  group. A stack holds the newest four, a bubble stays ten seconds and fades out, and each is fainter the less of its
  writer (or its group) is heard from here. A small box at the floor's foot writes to the space's chat. Nothing is
  kept or sent by it: the chat is the space's own, whole on its Chat tab.
- **Where it sits.** Entering an open space leaves the list beside it alone (a circle's spaces stay where they are):
  the floor fills the space's own page, with the call's controls over the middle of its foot. The words saying how to
  walk fade once this device has walked.

## Not built

- **Who may change groups.** Anyone in the call may make, rename, move or remove one. Roles could hold it to whoever
  may change the space.
- **Groups for someone who has never been in while another device was.** There is no copy on the relay: a device
  learns of the groups from another that has them.
- **The browser guest page and the Discord bridge** say no place and stand in the middle.
- **Stereo by direction** (someone on your left in your left ear).

## The character (planned)

Today a person is their profile picture inside the call's ripple (`avatarFigure`). The view draws everyone through
one builder, `OpenFigureBuilder`, which is handed an `OpenFigure`: id, name, size, how loud they are, muted, which way
they face, whether they are walking, and how much of them is heard. A ghost that walks is another builder:

1. Draw it from `OpenFigure.facing` and `walking` (both are already said in `os`), with the ripple or a glow from
   `level`.
2. Dress it from the person's cosmetics (`lib/me/cosmetics.dart`, as `DressedFace` in `lib/ui/cosmetics_ui.dart` does
   for a face). Their cosmetics already travel with their profile; if a figure needs choices of its own (a body, a
   hat), say them as one more field beside the place (`f`), which builds from before pass over.
3. Hand the builder to `OpenSpaceView(figure: ...)` from `lib/ui/hangout_screen.dart`, behind a choice in Settings if
   both looks are to stay.

Nothing in `lib/voice/open_space.dart` needs to change for it.
