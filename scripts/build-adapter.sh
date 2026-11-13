#!/bin/bash
# Rebuild the bundled MediaRemote adapter (BSD-3-Clause) from upstream source,
# as a universal (arm64 + x86_64) dylib.
#
#   ./scripts/build-adapter.sh
#
# The result is written to vendor/mediaremote-mini/build/mediaremote-mini/.
set -euo pipefail
cd "$(dirname "$0")/.."

COMMIT="8c8c1fa4820681fd4bbd6a17ce0a5655e1f4ebe7"
OUT="vendor/mediaremote-mini/build/mediaremote-mini/MediaRemoteMini.dylib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching nowplaying-cli @ $COMMIT"
curl -fsSL "https://codeload.github.com/kirtan-shah/nowplaying-cli/tar.gz/$COMMIT" -o "$TMP/src.tar.gz"
tar xzf "$TMP/src.tar.gz" -C "$TMP"
SRC="$TMP/nowplaying-cli-$COMMIT"
[ -d "$SRC/src/mediaremote-mini" ] || { echo "unexpected tarball layout"; exit 1; }

SOURCES=(
  src/mediaremote-mini/adapter/env.m
  src/mediaremote-mini/adapter/get.m
  src/mediaremote-mini/adapter/globals.m
  src/mediaremote-mini/adapter/keys.m
  src/mediaremote-mini/adapter/now_playing.m
  src/mediaremote-mini/private/MediaRemote.m
  src/mediaremote-mini/utility/helpers.m
)

for arch in arm64 x86_64; do
  echo "compiling $arch"
  clang -dynamiclib -fobjc-arc -fvisibility=default -O3 \
    -I"$SRC/src/mediaremote-mini/include" -I"$SRC/src/mediaremote-mini" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -target "${arch}-apple-macos12.0" \
    -o "$TMP/${arch}.dylib" "${SOURCES[@]/#/$SRC/}"
done

mkdir -p "$(dirname "$OUT")"
lipo -create -output "$OUT" "$TMP/arm64.dylib" "$TMP/x86_64.dylib"
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "wrote $OUT"
lipo -info "$OUT"
