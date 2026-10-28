#!/bin/bash
# Builds "ChatGPT Multi-Accounts.app" and the chatgpt-multi command into ./build,
# as universal binaries that run on both Apple silicon and Intel Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"   # shown in Finder; raise it, and BUILD, for every release. 0.x while in beta
BUILD="1"

# A stale SDKROOT (Command Line Tools removed after Xcode was installed) breaks swift build.
if [ -n "${SDKROOT:-}" ] && [ ! -d "$SDKROOT" ]; then unset SDKROOT; fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product ChatGPTMultiAccounts
swift build -c release "${ARCHS[@]}" --product chatgpt-multi
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/ChatGPT Multi-Accounts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ChatGPTMultiAccounts" "$APP/Contents/MacOS/ChatGPTMultiAccounts"
# The command ships inside the app too; Settings → Install links it into ~/.local/bin.
cp "$BIN/chatgpt-multi" "$APP/Contents/MacOS/chatgpt-multi"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/chatgpt-multi" build/chatgpt-multi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ChatGPT Multi-Accounts</string>
    <key>CFBundleDisplayName</key>
    <string>ChatGPT Multi-Accounts</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>local.chatgpt-multi-accounts</string>
    <key>CFBundleExecutable</key>
    <string>ChatGPTMultiAccounts</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures, inner binary first, so macOS runs them on this Mac. They aren't notarized,
# so a downloaded copy gets a security warning the first time it opens (the README explains it).
codesign --force --sign - "$APP/Contents/MacOS/chatgpt-multi"
codesign --force --sign - "$APP"
codesign --force --sign - build/chatgpt-multi

echo "Built: $APP"
echo "Built: build/chatgpt-multi"
