#!/bin/sh
# Builds the Signal helper (sidecar/signal, on mautrix-signal's signalmeow and Signal's libsignal, AGPL-3.0):
#   build/signal-sidecar/mac/signal-sidecar           Apple silicon
#   build/signal-sidecar/android/libsignalsidecar.so  the phone's (an executable named as a library, as libgmsidecar.so is)
# libsignal (Rust) is built first from github.com/signalapp/libsignal at the commit mautrix-signal pins, into
# build/signal/libsignal (protoc and cmake are needed; rustup fetches libsignal's own Rust).
#
# Signal is Coming soon (lib/inbox/inbox.dart), so the phone's copy goes to build/, not android/.../jniLibs, which
# would pack it into every APK; `android --ship` puts it there for a build that is to carry it.
# Usage: tool/build-signalsidecar.sh [mac|android] [--ship]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
pin=904c8dc8216073b078a5f2f5090e3da8382e6a92   # mautrix-signal main 23093d82 (2026-11-16)'s pkg/libsignalgo/libsignal (v0.106.1)
lib="$root/build/signal/libsignal"
out="$root/build/signal-sidecar"
want=${1:-mac}
if [ ! -d "$lib" ]; then git clone -q https://github.com/signalapp/libsignal "$lib"; fi
(cd "$lib" && git fetch -q --depth 1 origin $pin && git checkout -q $pin)
flags="-trimpath -ldflags=-s"
rust() { (cd "$lib" && RUSTFLAGS="-Ctarget-feature=-crt-static" RUSTC_WRAPPER="" cargo build -q -p libsignal-ffi --profile=release --target "$1"); }
if [ "$want" = mac ]; then
  rust aarch64-apple-darwin
  mkdir -p "$out/mac"
  (cd "$root/sidecar/signal" && CGO_ENABLED=1 LIBRARY_PATH="$lib/target/aarch64-apple-darwin/release" GOOS=darwin GOARCH=arm64 go build $flags -o "$out/mac/signal-sidecar" .)
  echo "ok $out/mac/signal-sidecar"
fi
if [ "$want" = android ]; then
  sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
  ndk=$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)
  [ -n "$ndk" ] || { echo "x no Android NDK under $sdk/ndk"; exit 1; }
  tc=$(ls -d "$ndk"/toolchains/llvm/prebuilt/*/bin | head -1)
  (rustup target add aarch64-linux-android --toolchain "$(cat "$lib/rust-toolchain")" >/dev/null 2>&1 || true)
  CC_aarch64_linux_android="$tc/aarch64-linux-android26-clang" CXX_aarch64_linux_android="$tc/aarch64-linux-android26-clang++" \
    AR_aarch64_linux_android="$tc/llvm-ar" CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$tc/aarch64-linux-android26-clang" \
    ANDROID_NDK_HOME="$ndk" rust aarch64-linux-android
  dest="$out/android"
  [ "$2" = --ship ] && dest="$root/android/app/src/main/jniLibs/arm64-v8a"
  mkdir -p "$dest"
  (cd "$root/sidecar/signal" && CGO_ENABLED=1 CC="$tc/aarch64-linux-android29-clang" CXX="$tc/aarch64-linux-android29-clang++" \
    CGO_LDFLAGS="-L$lib/target/aarch64-linux-android/release" GOOS=android GOARCH=arm64 go build $flags -o "$dest/libsignalsidecar.so" .)
  # libsignal needs Android's shared C++ library, which a phone does not have: it goes beside the helper, and the app
  # starts the helper with LD_LIBRARY_PATH on that folder (lib/inbox/signal.dart).
  cp "$(dirname "$tc")/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$dest/libc++_shared.so"
  echo "ok $dest/libsignalsidecar.so (and libc++_shared.so)"
fi
