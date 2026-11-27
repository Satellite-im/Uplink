#!/bin/sh
# Builds DeepFilterNet (this crate) for the Mac, both kinds of Mac, as build/VoiceFxDeepFilter.xcframework, which
# native/voicefx/Package.swift links where it is there. Run by tool/release-mac.mjs; about a minute the first time.
set -e
cd "$(dirname "$0")"
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin
rm -rf build && mkdir -p build/lib build/headers
lipo -create target/aarch64-apple-darwin/release/libvoicefx_deepfilter.a target/x86_64-apple-darwin/release/libvoicefx_deepfilter.a -output build/lib/libvoicefx_deepfilter.a
printf '/* DeepFilterNet for voicefx: the C functions are declared in voicefx.c. */\n' > build/headers/voicefx_deepfilter.h
printf 'module VoiceFxDeepFilter {\n  header "voicefx_deepfilter.h"\n  export *\n}\n' > build/headers/module.modulemap
xcodebuild -create-xcframework -library build/lib/libvoicefx_deepfilter.a -headers build/headers -output build/VoiceFxDeepFilter.xcframework >/dev/null
echo "ok build/VoiceFxDeepFilter.xcframework ($(du -sh build/VoiceFxDeepFilter.xcframework | cut -f1))"
