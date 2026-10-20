#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/PhoneBridge.app"
BIN="$ROOT/.build/release/PhoneBridgeMac"

if [ ! -x "$BIN" ]; then
  echo "Build the release executable first: swift build -c release" >&2
  exit 1
fi

mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PhoneBridgeMac"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "Created $APP"
