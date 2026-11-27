#!/bin/sh
# Builds an account helper (sidecar/messenger, sidecar/instagram or sidecar/linkedin; sidecar/ACCOUNT_HELPERS.md):
#   build/<name>-sidecar/mac/<name>-sidecar                Apple silicon
#   build/<name>-sidecar/linux/<name>-sidecar              x86-64
#   build/<name>-sidecar/windows/<name>-sidecar.exe        x86-64
#   build/<name>-sidecar/android/lib<name>sidecar.so       the phone's (an executable named as a library, as
#                                                          libwhatsappsidecar.so is)
# They are Go alone on a computer (CGO off: nothing of the system's to link, so one Mac builds all three computers').
# The phone's is built with the NDK's clang and CGO on even where the helper has no C: without it Go resolves names
# by /etc/resolv.conf, which Android does not have, and nothing would connect.
#
# `android --ship` puts the phone's into android/.../jniLibs, which packs it into the APK; without it, build/.
# Usage: tool/build-accountsidecar.sh <messenger|instagram|linkedin|discord|twitter|slack> [mac|linux|windows|android] [--ship]
set -e
name=${1:-}
case "$name" in messenger|instagram|linkedin|discord|twitter|slack) ;; *) echo "usage: tool/build-accountsidecar.sh <messenger|instagram|linkedin|discord|twitter|slack> [mac|linux|windows|android] [--ship]" >&2; exit 2 ;; esac
want=${2:-mac}
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/sidecar/$name"
out="$root/build/$name-sidecar"
flags="-trimpath -ldflags=-s"
[ -d "$src" ] || { echo "x no $src"; exit 1; }
case "$want" in
  mac)
    mkdir -p "$out/mac"
    (cd "$src" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build $flags -o "$out/mac/$name-sidecar" .)
    echo "ok $out/mac/$name-sidecar"
    ;;
  linux)
    mkdir -p "$out/linux"
    (cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build $flags -o "$out/linux/$name-sidecar" .)
    echo "ok $out/linux/$name-sidecar"
    ;;
  windows)
    mkdir -p "$out/windows"
    (cd "$src" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build $flags -o "$out/windows/$name-sidecar.exe" .)
    echo "ok $out/windows/$name-sidecar.exe"
    ;;
  android)
    sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
    ndk=$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)
    [ -n "$ndk" ] || { echo "x no Android NDK under $sdk/ndk"; exit 1; }
    tc=$(ls -d "$ndk"/toolchains/llvm/prebuilt/*/bin | head -1)
    dest="$out/android"
    [ "${3:-}" = --ship ] && dest="$root/android/app/src/main/jniLibs/arm64-v8a"
    mkdir -p "$dest"
    (cd "$src" && CGO_ENABLED=1 CC="$tc/aarch64-linux-android29-clang" CXX="$tc/aarch64-linux-android29-clang++" \
      GOOS=android GOARCH=arm64 go build $flags -o "$dest/lib${name}sidecar.so" .)
    echo "ok $dest/lib${name}sidecar.so"
    ;;
  *) echo "x unknown target $want" >&2; exit 2 ;;
esac
