#!/bin/sh
# Checks the music link without a sound (tool/spotify/check.swift says how), and the music sent without loss
# (lossless.swift; check.sh lossless for that alone), and
# the Mac's player of it (sink.swift; check.sh sink). Needs the WebRTC framework a macOS build
# has fetched: WEBRTC=<folder holding WebRTC.framework>, or it is looked for under build/macos.
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
fw=${WEBRTC:-$(find "$here/build/macos/SourcePackages/artifacts" -type d -path '*macos-arm64_x86_64' 2>/dev/null | head -1)}
[ -d "$fw/WebRTC.framework" ] || fw="$here/build/spotify/webrtc"
[ -d "$fw/WebRTC.framework" ] || { echo "no WebRTC.framework: set WEBRTC to the folder it is in"; exit 2; }
out="$here/build/spotify"
mkdir -p "$out/check"
# The C the app packs the music with, and what the check alone reads it back with, as modules.
mkdir -p "$out/check/VoiceFxC" "$out/check/MusicUnpack"
cp "$here/native/voicefx/include/music_pack.h" "$out/check/VoiceFxC/"
cp "$here/native/voicefx/test/music_unpack.h" "$out/check/MusicUnpack/"
printf 'module VoiceFxC { header "music_pack.h" export * }\n' > "$out/check/VoiceFxC/module.modulemap"
printf 'module MusicUnpack { header "music_unpack.h" export * }\n' > "$out/check/MusicUnpack/module.modulemap"
cc -O2 -std=c11 -target arm64-apple-macos12.0 -I"$here/native/voicefx/include" -c "$here/native/voicefx/music_pack.c" -o "$out/check/music_pack.o"
build() {
  cp "$here/tool/spotify/$1.swift" "$out/check/main.swift"
  swiftc -swift-version 5 -O -target arm64-apple-macos12.0 -I "$out/check/VoiceFxC" -I "$out/check/MusicUnpack" -F "$fw" -framework WebRTC -Xlinker -rpath -Xlinker "$fw" "$here/macos/Runner/MusicLink.swift" "$out/check/main.swift" "$out/check/music_pack.o" -o "$out/$2"
}
# The player needs no WebRTC, and renders into memory.
cp "$here/tool/spotify/sink.swift" "$out/check/main.swift"
swiftc -swift-version 5 -O -target arm64-apple-macos12.0 "$here/macos/Runner/MusicSink.swift" "$out/check/main.swift" -o "$out/sink-check"
echo "--- the player (must pass)"; "$out/sink-check"
cmp "$here/macos/Runner/MusicSink.swift" "$here/ios/Runner/MusicSink.swift"
if [ "$1" = sink ]; then exit 0; fi
if [ "$1" = lossless ]; then
  build lossless lossless-check
  if [ -n "$2" ]; then exec "$out/lossless-check" "$2"; fi
else
  build check music-check
  if [ -n "$1" ]; then exec "$out/music-check" "$1"; fi
  echo "--- as it is (must pass)"; "$out/music-check" right
  echo "--- swapped (must fail)"; if "$out/music-check" swapped; then echo "the check did not notice the sides were swapped"; exit 1; fi
  echo "--- cut (must fail)"; if "$out/music-check" cut; then echo "the check did not notice there was no music"; exit 1; fi
  build lossless lossless-check
fi
echo "--- without loss, as it is (must pass)"; "$out/lossless-check" as
echo "--- one sample changed (must fail)"; if "$out/lossless-check" changed; then echo "the check did not notice a sample was changed"; exit 1; fi
echo "--- a frame left out (must fail)"; if "$out/lossless-check" late; then echo "the check did not notice a frame was left out"; exit 1; fi
echo "all did as they should"
