#!/bin/sh
# Builds TDLib's JSON client (libtdjson), Telegram's own client library, from Telegram's source at a pinned commit,
# for Uplink's Telegram inbox (lib/networks/telegram.dart; Matt, 2026-11-15: "Let's build in telegram and bluesky").
#
#   sh tool/build-tdlib.sh mac        build/tdlib/mac/libtdjson.dylib        (Apple silicon)
#   sh tool/build-tdlib.sh android    build/tdlib/android/arm64-v8a/libtdjson.so
#
# Built here rather than taken from a package of prebuilt binaries: nothing that holds people's Telegram sessions comes
# from anywhere but github.com/tdlib/td and openssl/openssl. OpenSSL is linked in statically, so the library stands on
# its own. A build is kept and reused while TD_COMMIT is the same (build/tdlib/<target>/.commit); the first takes a
# long while (TDLib is a large C++ library: twenty minutes or more a target).
#
# Needs cmake, gperf, perl, git; for the Mac, Homebrew's openssl@3; for Android, the NDK under ~/Library/Android/sdk.
set -e
TD_COMMIT=c8828d50f5eac2fc7089ce1089d7ce9095c61b5e
OPENSSL_TAG=openssl-3.5.4
NDK_VERSION=28.2.13676358
ANDROID_API=24
JOBS=${JOBS:-6}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/build/tdlib"
SRC="$WORK/src"
target=${1:-}
case "$target" in mac|android) ;; *) echo "usage: sh tool/build-tdlib.sh mac|android" >&2; exit 2 ;; esac

OUT="$WORK/$target"
if [ "$target" = mac ]; then LIB="$OUT/libtdjson.dylib"; else LIB="$OUT/arm64-v8a/libtdjson.so"; fi
if [ -f "$LIB" ] && [ "$(cat "$WORK/.commit-$target" 2>/dev/null)" = "$TD_COMMIT" ]; then
  echo "ok $LIB (TDLib ${TD_COMMIT%"${TD_COMMIT#???????}"}, built before)"
  exit 0
fi

# The source, at the pinned commit.
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then git clone --quiet https://github.com/tdlib/td.git "$SRC"; fi
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet --force "$TD_COMMIT"

if [ "$target" = mac ]; then
  SSL=$(brew --prefix openssl@3)
  B="$WORK/build-mac"
  mkdir -p "$B" "$OUT"
  cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DOPENSSL_ROOT_DIR="$SSL" -DOPENSSL_USE_STATIC_LIBS=TRUE -DTD_ENABLE_LTO=OFF >/dev/null
  cmake --build "$B" --target tdjson -j "$JOBS"
  cp "$B/libtdjson."*.dylib "$LIB" 2>/dev/null || cp "$B/libtdjson.dylib" "$LIB"
  install_name_tool -id @rpath/libtdjson.dylib "$LIB"
  if otool -L "$LIB" | grep -q -e homebrew -e /usr/local; then echo "x $LIB links a library outside the system: $(otool -L "$LIB")" >&2; exit 1; fi
else
  NDK="$HOME/Library/Android/sdk/ndk/$NDK_VERSION"
  [ -d "$NDK" ] || { echo "x no NDK at $NDK" >&2; exit 1; }
  TOOLS="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"

  # The generated sources TDLib cross-compiles from, made by a build for this Mac.
  H="$WORK/build-host"
  if [ ! -f "$H/.prepared-$TD_COMMIT" ]; then
    mkdir -p "$H"
    cmake -S "$SRC" -B "$H" -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" >/dev/null
    cmake --build "$H" --target prepare_cross_compiling -j "$JOBS"
    touch "$H/.prepared-$TD_COMMIT"
  fi

  # OpenSSL for Android, static, from its own source.
  S="$WORK/openssl-android"
  if [ ! -f "$S/out/lib/libssl.a" ]; then
    rm -rf "$S"
    git clone --quiet --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$S/src"
    (cd "$S/src" && PATH="$TOOLS/bin:$PATH" ANDROID_NDK_ROOT="$NDK" ./Configure android-arm64 -D__ANDROID_API__=$ANDROID_API \
      no-shared no-tests no-ui-console --prefix="$S/out" --libdir=lib >/dev/null \
      && PATH="$TOOLS/bin:$PATH" ANDROID_NDK_ROOT="$NDK" make -j "$JOBS" build_libs >/dev/null \
      && make install_dev >/dev/null)
  fi

  B="$WORK/build-android"
  mkdir -p "$B" "$OUT/arm64-v8a"
  cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$ANDROID_API -DANDROID_STL=c++_static \
    -DOPENSSL_ROOT_DIR="$S/out" -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_INCLUDE_DIR="$S/out/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$S/out/lib/libcrypto.a" -DOPENSSL_SSL_LIBRARY="$S/out/lib/libssl.a" -DTD_ENABLE_LTO=OFF >/dev/null
  cmake --build "$B" --target tdjson -j "$JOBS"
  "$TOOLS/bin/llvm-strip" --strip-unneeded -o "$LIB" "$B/libtdjson.so"
fi

echo "$TD_COMMIT" > "$WORK/.commit-$target"
echo "ok $LIB ($(du -h "$LIB" | cut -f1))"
