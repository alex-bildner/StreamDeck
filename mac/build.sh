#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCH="$(uname -m)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

swiftc -sdk "$SDK" -target "${ARCH}-apple-macos13.0" -O -o /tmp/deck-make-icon make-icon.swift
ICONSET="$(mktemp -d)/AppIcon.iconset"
/tmp/deck-make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

printf '%s\n' "$ROOT/companion/server.py" > "$APP/Contents/Resources/companion.path"

swiftc -sdk "$SDK" \
  -target "${ARCH}-apple-macos13.0" \
  -O \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -o "$APP/Contents/MacOS/Deck" \
  DeckMac.swift DeckEditor.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

ditto "$APP" "/Applications/Deck.app"
codesign --force --deep --sign - "/Applications/Deck.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Deck.app"

swiftc -sdk "$SDK" -target "${ARCH}-apple-macos13.0" -O -o /tmp/deck-pin-dock pin-dock.swift
/tmp/deck-pin-dock "/Applications/Deck.app"
AGENT="$HOME/Library/LaunchAgents/com.deck.companion.plist"
if [[ -f "$AGENT" ]]; then
  launchctl bootout "gui/$(id -u)/com.deck.companion" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
fi
echo "Pronto: /Applications/Deck.app"
