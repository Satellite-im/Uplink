#!/bin/sh
# Builds the WhatsApp helper (sidecar/whatsapp, on whatsmeow, MPL-2.0):
#   build/whatsapp-sidecar/mac/whatsapp-sidecar             Apple silicon
#   build/whatsapp-sidecar/android/libwhatsappsidecar.so    the phone's (an executable named as a library, as libsignalsidecar.so is)
# whatsmeow is pure Go; only SQLite (mattn/go-sqlite3) is C, built by cgo with the system compiler on a Mac and the
# NDK's clang for the phone. No Rust, no libsignal, no C++ library to carry.
#
# WhatsApp is not yet in a release, so the phone's copy goes to build/, not android/.../jniLibs, which would pack it
# into every APK; `android --ship` puts it there for a build that is to carry it.
# Usage: tool/build-whatsappsidecar.sh [mac|android] [--ship]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/whatsapp-sidecar"
want=${1:-mac}
flags="-trimpath -ldflags=-s"
if [ "$want" = mac ]; then
  mkdir -p "$out/mac"
  (cd "$root/sidecar/whatsapp" && CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 go build $flags -o "$out/mac/whatsapp-sidecar" .)
  echo "ok $out/mac/whatsapp-sidecar"
fi
if [ "$want" = android ]; then
  sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
  ndk=$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)
  [ -n "$ndk" ] || { echo "x no Android NDK under $sdk/ndk"; exit 1; }
  tc=$(ls -d "$ndk"/toolchains/llvm/prebuilt/*/bin | head -1)
  dest="$out/android"
  [ "$2" = --ship ] && dest="$root/android/app/src/main/jniLibs/arm64-v8a"
  mkdir -p "$dest"
  (cd "$root/sidecar/whatsapp" && CGO_ENABLED=1 CC="$tc/aarch64-linux-android29-clang" CXX="$tc/aarch64-linux-android29-clang++" \
    GOOS=android GOARCH=arm64 go build $flags -o "$dest/libwhatsappsidecar.so" .)
  echo "ok $dest/libwhatsappsidecar.so"
fi
