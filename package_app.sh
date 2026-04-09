#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP="LlmTokenWidget.app"
BIN=".build/release/LlmTokenWidget"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/LlmTokenWidget"
echo "Built $APP — run: open \"$APP\""
