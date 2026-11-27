#!/bin/sh
# Builds the music's packing and tries it on this computer, reading it back with the test's own reader and, on a Mac,
# with the system's FLAC decoder. run_pack.sh fixture writes test/support/music_chunks.bin anew, for test/flac_test.dart.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -r "$out"' EXIT
cc -O2 -std=c11 -Wall -Wextra -fsanitize=address,undefined -I"$here/include" -I"$here/test" "$here/music_pack.c" "$here/test/music_pack_test.c" -lm -o "$out/test"
"$out/test" "$out"
if command -v afconvert >/dev/null; then
  afconvert -f caff -d LEI16 "$out/pack.flac" "$out/pack.caf"
  # The samples are the last of the file: compared from its end.
  size=$(wc -c < "$out/pack.raw" | tr -d ' ')
  python3 - "$out/pack.raw" "$out/pack.caf" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read()
caf = open(sys.argv[2], 'rb').read()
at = caf.find(b'data', 8)
# The data chunk: its name, 8 bytes of length, 4 of edits, then the samples.
got = caf[at + 16:at + 16 + len(raw)]
sys.exit('FAIL: the Mac read something else' if got != raw else print("the Mac's own FLAC decoder read it bit for bit:", len(raw), 'bytes'))
PY
fi
if [ "$1" = fixture ]; then cp "$out/music_chunks.bin" "$here/../../test/support/music_chunks.bin"; fi
