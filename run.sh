#!/bin/sh
# Launches the menu bar app via `open` so it is NOT tied to this terminal.
# Running .build/release/LlmTokenWidget directly and pressing Ctrl+C will quit the app.
set -e
cd "$(dirname "$0")"
./package_app.sh
open LlmTokenWidget.app
echo "LlmTokenWidget launched (not attached to this shell). Check the menu bar on the right."
