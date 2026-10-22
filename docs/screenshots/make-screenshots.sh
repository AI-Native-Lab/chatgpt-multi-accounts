#!/bin/bash
# Draws the README screenshots from the demo's synthetic accounts: the app renders its own
# windows off screen, so no real account, and no real ChatGPT, is ever shown.
set -euo pipefail
cd "$(dirname "$0")/../.."

macos/scripts/build.sh >/dev/null
"macos/build/ChatGPT Multi-Accounts.app/Contents/MacOS/ChatGPTMultiAccounts" --render-screenshots docs/screenshots
# The diagram is an SVG; the PNG keeps its font (Be Vietnam Pro) wherever the README is read.
rsvg-convert -w 1920 docs/how-it-works.svg -o docs/screenshots/how-it-works.png
echo "Wrote docs/screenshots/how-it-works.png"
