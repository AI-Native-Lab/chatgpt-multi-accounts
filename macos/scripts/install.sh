#!/bin/bash
# Builds and installs ChatGPT Multi-Accounts into ~/Applications, links the chatgpt-multi
# command into ~/.local/bin, then opens the app. ChatGPT itself is never quit.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

APP="$HOME/Applications/ChatGPT Multi-Accounts.app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"

# Ask a running copy of this app (not ChatGPT) to quit, and wait until it has: opening the new
# copy while the old one is still shutting down fails (LaunchServices error -600).
running() { pgrep -x -u "$(id -u)" ChatGPTMultiAccounts >/dev/null; }
if running; then
    osascript -e 'ignoring application responses' \
              -e 'tell application id "local.chatgpt-multi-accounts" to quit' \
              -e 'end ignoring' 2>/dev/null || true
    for _ in {1..100}; do
        running || break
        sleep 0.2
    done
    if running; then
        echo "ChatGPT Multi-Accounts hasn't quit (it may be showing a dialog). Quit it, then run this again." >&2
        exit 1
    fi
fi

rm -rf "$APP"
cp -R "build/ChatGPT Multi-Accounts.app" "$HOME/Applications/"
ln -sf "$APP/Contents/MacOS/chatgpt-multi" "$HOME/.local/bin/chatgpt-multi"

open "$APP"
echo "Installed: $APP (its window opens now)"
echo "Command:   ~/.local/bin/chatgpt-multi"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: ~/.local/bin is not on your PATH; add it to use the command by name." ;;
esac
