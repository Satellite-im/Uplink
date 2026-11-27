#!/bin/sh
# Builds the Matrix helper (sidecar/matrix, on mautrix-go, MPL-2.0):
#   build/matrix-sidecar/mac/matrix-sidecar               Apple silicon
#   build/matrix-sidecar/android/libmatrixsidecar.so      the phone's (an executable named as a library, as libgmsidecar.so is)
#   build/matrix-sidecar/windows/matrix-sidecar.exe       Windows on x64
# The code is pure Go: end-to-end encryption by goolm (the `goolm` build tag, no libolm) and its store in
# modernc.org/sqlite, so the computers' copies are built with CGO off. The phone's is built with the NDK's C compiler
# (CGO on), as the Google Messages sidecar's is, so names are looked up by Android's own resolver: a CGO-less Go program
# on Android reads /etc/resolv.conf, which a phone does not have.
#
# Matrix is not in the app's list yet (lib/inbox/inbox.dart), so the phone's copy goes to build/, not
# android/.../jniLibs, which would pack it into every APK; `android --ship` puts it there for a build that is to carry it.
# Usage: tool/build-matrixsidecar.sh [mac|android|windows|all] [--ship]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/matrix-sidecar"
want=${1:-mac}
flags="-trimpath -tags goolm -ldflags=-s"
# build GOOS GOARCH OUT [CC]: CGO only where a C compiler is given.
build() { (cd "$root/sidecar/matrix" && if [ -n "$4" ]; then export CGO_ENABLED=1 CC="$4"; else export CGO_ENABLED=0; fi && GOOS="$1" GOARCH="$2" go build $flags -o "$3" .); }
if [ "$want" = mac ] || [ "$want" = all ]; then
  mkdir -p "$out/mac"
  build darwin arm64 "$out/mac/matrix-sidecar"
  echo "ok $out/mac/matrix-sidecar"
fi
if [ "$want" = android ] || [ "$want" = all ]; then
  sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
  ndk=$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)
  [ -n "$ndk" ] || { echo "x no Android NDK under $sdk/ndk"; exit 1; }
  cc=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android29-clang | head -1)
  dest="$out/android"
  [ "$2" = --ship ] && dest="$root/android/app/src/main/jniLibs/arm64-v8a"
  mkdir -p "$dest"
  build android arm64 "$dest/libmatrixsidecar.so" "$cc"
  echo "ok $dest/libmatrixsidecar.so"
fi
if [ "$want" = windows ] || [ "$want" = all ]; then
  mkdir -p "$out/windows"
  build windows amd64 "$out/windows/matrix-sidecar.exe"
  echo "ok $out/windows/matrix-sidecar.exe"
fi
