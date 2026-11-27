#!/bin/sh
# Turns a cosmetic's animation from Lovart into what the app draws (lib/me/cosmetics.dart, GMFB-34): a transparent
# animated WebP, and a still PNG where none was given.
#
#   tool/cosmetic_art.sh <input> <kind> <id> [size]
#
#   <input>  an animated WebP/APNG (kept as it is, resized), a folder of PNG frames, or a video on pure green (#00FF00),
#            whose green is cut out.
#   <kind>   decorations | borders | banners | names | effects
#   <id>     the piece's id in CosmeticCatalog (ghost-ring, haunted, …)
#   [size]   WxH; default 512x512 for decorations and borders, 1080x1920 for effects.
#
# Writes assets/cosmetics/<kind>/<id>.webp, and <id>.png (its first frame) unless one is there. 24 frames a second.
set -e
in=$1 kind=$2 id=$3
[ -n "$in" ] && [ -n "$kind" ] && [ -n "$id" ] || { echo "usage: $0 <input> <kind> <id> [WxH]" >&2; exit 2; }
case $kind in
  decorations|borders) size=${4:-512x512} ;;
  effects) size=${4:-1080x1920} ;;
  *) size=${4:?give a size for $kind} ;;
esac
here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/assets/cosmetics/$kind
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmetic.XXXXXX")
w=${size%x*} h=${size#*x}
scale="scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=0x00000000"
if [ -d "$in" ]; then
  ffmpeg -loglevel error -framerate 24 -pattern_type glob -i "$in/*.png" -vf "$scale,format=rgba" "$work/%04d.png"
else
  case $in in
    *.webp|*.png|*.apng|*.gif) ffmpeg -loglevel error -i "$in" -vf "fps=24,$scale,format=rgba" "$work/%04d.png" ;;
    # Video on green: the green keyed out, its fringe taken off.
    *) ffmpeg -loglevel error -i "$in" -vf "fps=24,chromakey=0x00FF00:0.18:0.06,despill=type=green,$scale,format=rgba" "$work/%04d.png" ;;
  esac
fi
n=$(ls "$work"/*.png | wc -l | tr -d ' ')
img2webp -loop 0 -lossy -q 82 -m 6 -d 42 "$work"/*.png -o "$out/$id.webp" >/dev/null 2>&1
[ -f "$out/$id.png" ] || cp "$work/0001.png" "$out/$id.png"
echo "ok $out/$id.webp: $n frames, $(du -k "$out/$id.webp" | cut -f1) KB ($size)"
