#!/usr/bin/env bash
# Build the capture helper as a single CLI binary (no Xcode project).
# The per-process Core Audio HAL used by CallDetector needs macOS 14.4+.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/build"

# See app/build.sh and Sources/ObjC/TapInstall.h: installTapOnBus raises an
# ObjC exception on a format mismatch, which Swift cannot catch, so the @try
# lives in a single ObjC file compiled alongside.
echo "Compiling the ObjC exception shim…"
mkdir -p "$DIR/build/obj"
xcrun clang -c \
  -O2 -fobjc-arc \
  -target arm64-apple-macos14.4 \
  -o "$DIR/build/obj/TapInstall.o" \
  "$DIR/Sources/ObjC/TapInstall.m"

echo "Compiling livecall-helper…"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos14.4 \
  -parse-as-library \
  -import-objc-header "$DIR/Sources/ObjC/TapInstall.h" \
  -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  -framework CoreGraphics -framework ApplicationServices \
  -o "$DIR/build/livecall-helper" \
  "$DIR/build/obj/TapInstall.o" \
  "$DIR"/Sources/*.swift

echo "Built $DIR/build/livecall-helper"
echo "Note: mic / Screen Recording / Accessibility + Input Monitoring (global hotkeys)"
echo "      prompts attach to the terminal app you run it from, not to this binary."
