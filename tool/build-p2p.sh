#!/bin/sh
# Builds the direct network's core (native/p2p: Rust on iroh; docs/OPEN_NETWORK.md, section 2; Matt, 2026-11-22: "look
# at iroh as the rust backend for the p2p side") for one platform, into build/p2p, where the app and its releases look:
#
#   sh tool/build-p2p.sh mac        build/p2p/mac/libghost_p2p.dylib              both kinds of Mac in one file
#   sh tool/build-p2p.sh android    build/p2p/android/arm64-v8a/libghost_p2p.so   which the app's jniLibs take in
#   sh tool/build-p2p.sh ios        build/p2p/ios/GhostP2p.xcframework            a static library: an iPhone, and the simulator
#
# Windows and Linux build theirs on their own runners (.github/workflows/messaging-windows.yml, messaging-linux.yml)
# with a plain `cargo build --release --locked` in native/p2p.
#
# Nothing is fetched but what Cargo.lock names, from crates.io (--locked: a build that would need anything else
# stops). cargo keeps what it has built (native/p2p/target) and builds again only what changed, so this is run for
# every release rather than a library from before trusted; a target's first build takes a few minutes.
#
# Built with the Rust native/p2p/rust-toolchain.toml names (1.94.1: rustup installs it the first time), and the
# targets each build needs, which it adds; for Android, the NDK under ~/Library/Android/sdk.
set -e
NDK_VERSION=28.2.13676358
# The app's minSdk (android/app/build.gradle.kts), and the oldest systems the Mac and iPhone apps run on.
ANDROID_API=29
MAC_FROM=12.0
IOS_FROM=16.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CRATE="$ROOT/native/p2p"
OUT="$ROOT/build/p2p"
target=${1:-}
case "$target" in mac|android|ios) ;; *) echo "usage: sh tool/build-p2p.sh mac|android|ios" >&2; exit 2 ;; esac

# The pinned Rust, and nothing else: a build with another would not be the one the tests ran with.
RUST=$(cd "$CRATE" && rustc --version)
case "$RUST" in "rustc 1.94.1 "*) ;; *) echo "x native/p2p is built with Rust 1.94.1 (its rust-toolchain.toml), and this is $RUST" >&2; exit 1 ;; esac
# The targets a build needs, for the pinned Rust (added once; again, nothing happens).
need() { (cd "$CRATE" && rustup target add "$@" >/dev/null 2>&1) || { echo "x rustup could not add $*" >&2; exit 1; }; }

# One kind of library for one target. What follows `--` goes to the last step alone (the library itself), so the same
# built dependencies serve every kind.
build() { (cd "$CRATE" && cargo rustc --quiet --release --locked --lib --crate-type "$1" --target "$2" -- $3); }
# The seven functions the Dart side looks up (native/p2p/include/ghost_p2p.h): a library without one of them is no use.
FUNCTIONS="ghost_p2p_abi ghost_p2p_ready ghost_p2p_node_id ghost_p2p_new ghost_p2p_command ghost_p2p_drop ghost_p2p_finalize"

if [ "$target" = mac ]; then
  need aarch64-apple-darwin x86_64-apple-darwin
  LIB="$OUT/mac/libghost_p2p.dylib"
  # Named, as it is linked, the way the app finds it beside its other libraries (Contents/Frameworks, by @rpath). And
  # stripped by the linker itself (-x: no symbol but the ones it offers), not by the release profile's `strip`: what
  # rustc 1.94 leaves after Xcode 27's strip has been at a library is one macOS 27 will not load ("mis-aligned
  # LINKEDIT string pool"), so for a Mac that setting is turned off here and the linker does the same work.
  for arch in aarch64-apple-darwin x86_64-apple-darwin; do
    MACOSX_DEPLOYMENT_TARGET=$MAC_FROM CARGO_PROFILE_RELEASE_STRIP=false build cdylib $arch "-C link-arg=-Wl,-install_name,@rpath/libghost_p2p.dylib -C link-arg=-Wl,-x"
  done
  mkdir -p "$OUT/mac"
  lipo -create "$CRATE/target/aarch64-apple-darwin/release/libghost_p2p.dylib" "$CRATE/target/x86_64-apple-darwin/release/libghost_p2p.dylib" -output "$LIB"
  # Signed by nobody in particular (an Apple silicon Mac loads no code without a signature, and the Intel half comes
  # out of the linker with none): enough for `flutter run` and the tests. A release signs it again as the app's own
  # (tool/release-mac.mjs signs everything in Contents/Frameworks).
  codesign --force --sign - "$LIB" 2>/dev/null
  [ "$(otool -D "$LIB" | tail -1)" = "@rpath/libghost_p2p.dylib" ] || { echo "x $LIB is not named @rpath/libghost_p2p.dylib" >&2; exit 1; }
  if otool -L "$LIB" | grep -q -e homebrew -e /usr/local; then echo "x $LIB links a library outside the system: $(otool -L "$LIB")" >&2; exit 1; fi
  codesign --verify "$LIB" || { echo "x $LIB has no signature a Mac would load it by" >&2; exit 1; }
  for f in $FUNCTIONS; do nm -gU "$LIB" | grep -q " _$f\$" || { echo "x $LIB has no $f" >&2; exit 1; }; done
  echo "ok $LIB ($(lipo -archs "$LIB"), $(du -h "$LIB" | cut -f1))"
fi

if [ "$target" = android ]; then
  need aarch64-linux-android
  NDK="$HOME/Library/Android/sdk/ndk/$NDK_VERSION"
  [ -d "$NDK" ] || { echo "x no NDK at $NDK" >&2; exit 1; }
  TOOLS=$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin | head -1)
  LIB="$OUT/android/arm64-v8a/libghost_p2p.so"
  # The NDK's own clang compiles what C there is (ring's) and links; 16 KB pages, as Android 15 and later ask of every
  # library an app carries; and named, so that the system loads one copy whether Kotlin loads it first (P2pCore.kt,
  # which hands it the app's context) or Dart does (by that name): the copy with the context is the one Dart uses.
  CC_aarch64_linux_android="$TOOLS/aarch64-linux-android$ANDROID_API-clang" AR_aarch64_linux_android="$TOOLS/llvm-ar" \
    CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLS/aarch64-linux-android$ANDROID_API-clang" \
    build cdylib aarch64-linux-android "-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-soname,libghost_p2p.so"
  mkdir -p "$OUT/android/arm64-v8a"
  "$TOOLS/llvm-strip" --strip-unneeded -o "$LIB" "$CRATE/target/aarch64-linux-android/release/libghost_p2p.so"
  "$TOOLS/llvm-readelf" -h "$LIB" | grep -q "Machine:.*AArch64" || { echo "x $LIB is not for arm64" >&2; exit 1; }
  if "$TOOLS/llvm-readelf" -lW "$LIB" | awk '$1 == "LOAD" && $NF != "0x4000" { bad = 1 } END { exit !bad }'; then echo "x $LIB is not aligned to 16 KB pages" >&2; exit 1; fi
  "$TOOLS/llvm-readelf" -d "$LIB" | grep -q "(SONAME).*\[libghost_p2p.so\]" || { echo "x $LIB is not named libghost_p2p.so" >&2; exit 1; }
  # Loading it runs none of its code (no initialiser): the app opens it when a node is first made, and nothing of it
  # runs until that node is started.
  if "$TOOLS/llvm-readelf" -d "$LIB" | grep -q -e "(INIT)" -e "(INIT_ARRAY)" -e "(PREINIT_ARRAY)"; then echo "x $LIB runs code of its own as it is loaded" >&2; exit 1; fi
  for f in $FUNCTIONS Java_com_infamousvague_ghostmessaging_P2pCore_nativeInstall; do
    "$TOOLS/llvm-readelf" --dyn-syms -W "$LIB" | grep -q " $f\$" || { echo "x $LIB has no $f" >&2; exit 1; }
  done
  echo "ok $LIB ($(du -h "$LIB" | cut -f1))"
fi

if [ "$target" = ios ]; then
  need aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  # A static library (an iPhone app carries no loose dylib of its own making), for the phone and for both kinds of
  # simulator, with the header: what Runner would link. The iPhone app does not link it yet.
  # (Not stripped here at all: a static library is stripped as the app that links it is.)
  for arch in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    IPHONEOS_DEPLOYMENT_TARGET=$IOS_FROM CARGO_PROFILE_RELEASE_STRIP=false build staticlib $arch ""
  done
  rm -rf "$OUT/ios" && mkdir -p "$OUT/ios/phone" "$OUT/ios/simulator" "$OUT/ios/headers"
  cp "$CRATE/target/aarch64-apple-ios/release/libghost_p2p.a" "$OUT/ios/phone/libghost_p2p.a"
  lipo -create "$CRATE/target/aarch64-apple-ios-sim/release/libghost_p2p.a" "$CRATE/target/x86_64-apple-ios/release/libghost_p2p.a" -output "$OUT/ios/simulator/libghost_p2p.a"
  cp "$CRATE/include/ghost_p2p.h" "$OUT/ios/headers/"
  printf 'module GhostP2p {\n  header "ghost_p2p.h"\n  export *\n}\n' > "$OUT/ios/headers/module.modulemap"
  xcodebuild -create-xcframework -library "$OUT/ios/phone/libghost_p2p.a" -headers "$OUT/ios/headers" \
    -library "$OUT/ios/simulator/libghost_p2p.a" -headers "$OUT/ios/headers" -output "$OUT/ios/GhostP2p.xcframework" >/dev/null
  rm -rf "$OUT/ios/phone" "$OUT/ios/simulator" "$OUT/ios/headers"
  echo "ok $OUT/ios/GhostP2p.xcframework ($(du -sh "$OUT/ios/GhostP2p.xcframework" | cut -f1))"
fi
