#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/PhoneBridge.app"
BIN="$ROOT/.build/release/PhoneBridgeMac"
PROJECT_ROOT="$(cd "$ROOT/.." && pwd)"
ICON="$PROJECT_ROOT/assets/icons/AppIcon.icns"
FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"

if [ ! -x "$BIN" ]; then
  echo "Build the release executable first: swift build -c release" >&2
  exit 1
fi

if [ -z "$FRAMEWORK" ] || [ ! -d "$FRAMEWORK" ]; then
  echo "Sparkle.framework is missing. Run swift package resolve first." >&2
  exit 1
fi

if [ ! -f "$ICON" ]; then
  echo "App icon is missing. Run macOS/scripts/generate-app-icon.swift first." >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhoneBridgeMac"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
if ! /usr/bin/otool -l "$APP/Contents/MacOS/PhoneBridgeMac" | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/PhoneBridgeMac"
fi
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "Created $APP"
