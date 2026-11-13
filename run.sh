#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# If NetEase is running without the CDP port, the app's menu can restart it.
# This keeps the running app simple and avoids killing a playback session.
open "$(pwd)/TouchFlow.app" --args --open
echo "TouchFlow started. Look for the stack icon in the menu bar."
