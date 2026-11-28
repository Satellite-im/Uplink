#!/bin/sh
# The logo as it turns while the app loads or looks for an update (lib/art/loading_logo.dart; Matt, 2026-11-27:
# "update the update screen to use the loading_logo.mp4 and make it larger so it is visible, also on the phone add a
# loading splash screen using the same logo").
#
#   sh tool/loading_logo.sh     art/loading_logo.mp4 into assets/art/loading-logo.webp and loading-logo-still.webp
#
# His film is the white logo turning on black, 960 square, 97 frames at 24 a second, coming back to where it began.
# A film takes a player, a player takes a moment to start, and neither a computer's small splash nor a phone's first
# second has one; and black is the page only in the dark. So the app carries it as a picture that moves (an animated
# WebP, which every platform's Flutter reads by itself), cut to the part the logo ever reaches (640 by 548 of the
# film, at +159+192: what the brightest of all its frames covers, and a twentieth more round it) and kept black and
# white as it is. The app draws it in the page's ink, taking how bright each dot is for how much of the ink it gets
# (LoadingLogo's colour matrix), so the black is whatever page is behind it. Kept solid, the frames come to about
# 0.9 MB; with the black made see-through in the file itself they were over 2 MB.
#
# Needs ffmpeg, ImageMagick (magick) and libwebp's img2webp and cwebp. The frames are left in build/loading-logo.
set -e
cd "$(dirname "$0")/.."
out=build/loading-logo
mkdir -p "$out"
ffmpeg -v error -y -i art/loading_logo.mp4 "$out/frame_%03d.png"
for f in "$out"/frame_*.png; do
  # The film's black is 0 to 5 of 255 and its white a little under full: brought to none and all.
  magick "$f" -crop 640x548+159+192 +repage -colorspace Gray -level 3%,96% -colorspace sRGB -alpha off "$f"
done
# 42 ms a frame is the film's 24 a second; -loop 0 goes round for as long as it is shown.
img2webp -loop 0 -lossy -q 75 -m 5 -d 42 "$out"/frame_*.png -o assets/art/loading-logo.webp
# Its first frame by itself, for a device asked to move less: the logo where the film begins, drawn the same way and
# the same size, so nothing differs but that it doesn't turn.
cwebp -quiet -lossless -z 9 "$out/frame_001.png" -o assets/art/loading-logo-still.webp
ls -l assets/art/loading-logo.webp assets/art/loading-logo-still.webp
