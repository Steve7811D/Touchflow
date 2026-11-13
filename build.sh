#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="TouchFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Build one binary per architecture and lipo them together, so the app runs on
# both Apple Silicon and the Intel MacBook Pros (which are the machines that
# actually have a Touch Bar).
SOURCES=(
  Sources/Models.swift Sources/CDPClient.swift Sources/NetEaseBridge.swift
  Sources/ImageStore.swift Sources/LyricsStore.swift Sources/SystemNowPlaying.swift
  Sources/CoverFlowBarView.swift Sources/PreviewRender.swift Sources/HUDWindow.swift
  Sources/TouchBarController.swift Sources/Settings.swift Sources/SettingsWindow.swift Sources/AppDelegate.swift Sources/main.swift
)
FLAGS=(-O -swift-version 5 -framework AppKit -framework Foundation -framework QuartzCore -framework Carbon)
mkdir -p build/arm64 build/x86_64
swiftc "${FLAGS[@]}" -target arm64-apple-macos12.0 "${SOURCES[@]}" -o build/arm64/TouchFlow
swiftc "${FLAGS[@]}" -target x86_64-apple-macos12.0 "${SOURCES[@]}" -o build/x86_64/TouchFlow
lipo -create -output "$APP/Contents/MacOS/TouchFlow" build/arm64/TouchFlow build/x86_64/TouchFlow
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
if [ -f icon/TouchFlow.icns ]; then
  cp icon/TouchFlow.icns "$APP/Contents/Resources/TouchFlow.icns"
fi
# Third-party notices are published in the project repository (THIRD-PARTY.md,
# LICENSES/), not inside the app bundle.  Keep those files in the repo.
# Now-playing support: our own glue script + the BSD-3 licensed adapter.
# The GPL-3.0 helper this project used to bundle is gone; only the
# BSD-3 licensed adapter remains.
mkdir -p "$APP/Contents/MacOS/scripts" "$APP/Contents/MacOS/build/mediaremote-mini"
cp scripts/read-nowplaying.pl "$APP/Contents/MacOS/scripts/read-nowplaying.pl"
chmod +x "$APP/Contents/MacOS/scripts/read-nowplaying.pl"
cp vendor/mediaremote-mini/build/mediaremote-mini/MediaRemoteMini.dylib \
   "$APP/Contents/MacOS/build/mediaremote-mini/MediaRemoteMini.dylib"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
