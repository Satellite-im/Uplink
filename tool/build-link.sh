#!/bin/sh
# Builds the link helper: iroh's relay server (the crate iroh-relay, MIT or Apache-2.0), which the direct network's
# devices find each other through and fall back on when no straight path can be made (docs/OPEN_NETWORK.md section 2,
# docs/SELF_HOSTING.md). It is not Uplink's relay, and nothing of ours is in it.
#   build/link/iroh-relay        the server's: Linux, x86-64, glibc 2.31 or later (Ubuntu 20.04, Debian 11, and newer)
#   build/link/host/iroh-relay   this machine's: what native/link-check starts, and what a server builds for itself
# Beside each, iroh-relay.sha256 and iroh-relay.version: tool/deploy-link.mjs sends nothing those two don't match.
#
# Nothing prebuilt is fetched. The source is iroh-relay 1.5.0 as crates.io holds it, taken only if it has the
# checksum below (crates.io's own for that version, read from its index 2026-11-22), and built --locked: with the
# Cargo.lock its authors published it with, so every crate under it is the version and checksum they built.
# The server's is linked by zig (cargo-zigbuild) against glibc 2.31, older than Ubuntu 22.04's 2.35, and the build
# stops if the program turns out to ask for anything newer. No zig is needed for `host`.
# Usage: tool/build-link.sh [server|host]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
version=1.5.0
cksum=aef6e9c979c78b0dadf6a2aac4ff629c4ffb91ec34586275673524248dc72f55
target=x86_64-unknown-linux-gnu
glibc=2.31
out="$root/build/link"
src="$out/src/iroh-relay-$version"
want=${1:-server}
case "$want" in server | host) ;; *) echo "x tool/build-link.sh [server|host]"; exit 1 ;; esac
# A file's SHA-256, by whichever of the two tools this machine has (Linux's, or the Mac's).
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# The source: the crate file as crates.io serves it, unpacked afresh each time, so what is built is what was checked.
mkdir -p "$out/src"
crate="$out/src/iroh-relay-$version.crate"
if [ ! -f "$crate" ] || [ "$(sum "$crate")" != "$cksum" ]; then
  curl -fsSL -o "$crate" "https://static.crates.io/crates/iroh-relay/iroh-relay-$version.crate"
fi
[ "$(sum "$crate")" = "$cksum" ] || { echo "x $crate is not iroh-relay $version as crates.io lists it (sha256 $(sum "$crate")). Nothing was built."; exit 1; }
rm -rf "$src"
tar -xzf "$crate" -C "$out/src"
[ -f "$src/Cargo.lock" ] || { echo "x iroh-relay $version came without a Cargo.lock. Nothing was built."; exit 1; }

# Its symbols are left out (a third smaller), and the paths in it are not this machine's.
export CARGO_PROFILE_RELEASE_STRIP=symbols
export RUSTFLAGS="--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}/registry/src/=/crates.io/ --remap-path-prefix=$out/src/=/"
# Builds the server program with the command given (cargo build, or cargo zigbuild and its target), by the crate's
# own Cargo.lock and nothing newer.
build() { (cd "$src" && "$@" --locked --release --features server --bin iroh-relay --target-dir "$out/target"); }
keep() { # the program built, and where it goes
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2.new" && chmod 755 "$2.new" && mv "$2.new" "$2"
  (cd "$(dirname "$2")" && echo "$(sum iroh-relay)  iroh-relay" > iroh-relay.sha256 && echo "$version" > iroh-relay.version)
  echo "ok $2 (iroh-relay $version, $3; $(($(wc -c < "$2") / 1000000)) MB, sha256 $(sum "$2"))"
}

if [ "$want" = host ]; then
  build cargo build
  said=$("$out/target/release/iroh-relay" --version)
  [ "$said" = "iroh-relay $version" ] || { echo "x what was built says it is \"$said\", not iroh-relay $version"; exit 1; }
  keep "$out/target/release/iroh-relay" "$out/host/iroh-relay" "for this machine: $(uname -sm)"
fi
if [ "$want" = server ]; then
  command -v zig >/dev/null && command -v cargo-zigbuild >/dev/null || { echo "x the server's build is linked by zig: brew install zig cargo-zigbuild (or build on the server itself: tool/build-link.sh host)"; exit 1; }
  (rustup target add $target >/dev/null 2>&1 || true)
  build cargo zigbuild --target "$target.$glibc"
  built="$out/target/$target/release/iroh-relay"
  # The newest glibc it asks for, read from the program itself: a floor that is only claimed is not a floor.
  asks=$(objdump -T "$built" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -u -V | tail -1)
  [ -n "$asks" ] || { echo "x could not read which glibc $built asks for (objdump -T)"; exit 1; }
  [ "$(printf '%s\n%s\n' "$asks" "$glibc" | sort -V | tail -1)" = "$glibc" ] || { echo "x it asks for glibc $asks, newer than $glibc"; exit 1; }
  keep "$built" "$out/iroh-relay" "Linux x86-64, glibc $asks or later (built against $glibc)"
fi
