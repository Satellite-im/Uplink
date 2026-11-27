#!/bin/sh
# Builds the Google Messages sidecar (sidecar/gmessages, AGPL-3.0) for the desktop apps:
#   build/gmsidecar/mac/gmsidecar        one file for Apple silicon and Intel
#   build/gmsidecar/windows/gmsidecar.exe
#   android/app/src/main/jniLibs/arm64-v8a/libgmsidecar.so   the phone's (an executable, named as a library so
#                                                             Android unpacks it where the app may run it)
# Pure Go for the computers, so a Mac builds them all; the phone's is built with Android's own C toolchain (the NDK),
# so names are looked up by Android's resolver. Usage: tool/build-gmsidecar.sh [mac|windows|android|all]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/sidecar/gmessages"
out="$root/build/gmsidecar"
want=${1:-all}
cd "$src"
export CGO_ENABLED=0
flags="-trimpath -ldflags=-s"
if [ "$want" = mac ] || [ "$want" = all ]; then
  mkdir -p "$out/mac"
  GOOS=darwin GOARCH=arm64 go build $flags -o "$out/mac/gmsidecar-arm64" .
  GOOS=darwin GOARCH=amd64 go build $flags -o "$out/mac/gmsidecar-amd64" .
  lipo -create -output "$out/mac/gmsidecar" "$out/mac/gmsidecar-arm64" "$out/mac/gmsidecar-amd64"
  rm "$out/mac/gmsidecar-arm64" "$out/mac/gmsidecar-amd64"
  echo "ok $out/mac/gmsidecar"
fi
if [ "$want" = windows ] || [ "$want" = all ]; then
  mkdir -p "$out/windows"
  GOOS=windows GOARCH=amd64 go build $flags -o "$out/windows/gmsidecar.exe" .
  echo "ok $out/windows/gmsidecar.exe"
fi
if [ "$want" = android ] || [ "$want" = all ]; then
  sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
  ndk=$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)
  [ -n "$ndk" ] || { echo "x no Android NDK under $sdk/ndk"; exit 1; }
  cc=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android29-clang | head -1)
  dest="$root/android/app/src/main/jniLibs/arm64-v8a"
  mkdir -p "$dest"
  CGO_ENABLED=1 CC="$cc" GOOS=android GOARCH=arm64 go build $flags -o "$dest/libgmsidecar.so" .
  echo "ok $dest/libgmsidecar.so"
  # arm64 alone: the phones this is for, and the emulators on an Apple-silicon Mac. (An x86_64 copy went into
  # 0.7.32's APK although the app's abiFilters say arm64: what is in jniLibs is packed as it is.)
  rm -f "$root/android/app/src/main/jniLibs/x86_64/libgmsidecar.so"
fi
