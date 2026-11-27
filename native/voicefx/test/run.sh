#!/bin/sh
# Builds voicefx with RNNoise for this computer and runs its test.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/voicefx_test
c++ -O2 -std=c++14 -I"$here" -c "$here/stretch.cpp" -o "$out-stretch.o"
cc -O2 -std=c11 -I"$here" -I"$here/include" -I"$here/rnnoise/include" -I"$here/rnnoise/src" "$here/voicefx.c" "$here"/rnnoise/src/*.c "$here/test/voicefx_test.c" "$out-stretch.o" -lc++ -lm -o "$out"
"$out"
# And with DeepFilterNet, where it has been built for this computer (deepfilter/build.sh).
df="$here/deepfilter/target/$(uname -m | sed 's/arm64/aarch64/')-apple-darwin/release/libvoicefx_deepfilter.a"
if [ -f "$df" ]; then
  cc -O2 -std=c11 -DVOICEFX_WITH_DEEPFILTER -I"$here" -I"$here/include" -I"$here/rnnoise/include" -I"$here/rnnoise/src" "$here/voicefx.c" "$here"/rnnoise/src/*.c "$here/test/voicefx_test.c" "$out-stretch.o" "$df" -lc++ -lm -framework CoreFoundation -framework Security -o "$out-df"
  "$out-df"
fi
