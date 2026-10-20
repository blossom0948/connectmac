#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/package-release.sh <version> (for example 0.3.3)" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use MAJOR.MINOR.PATCH format." >&2
  exit 2
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macOS/Info.plist")"
ANDROID_VERSION="$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' "$ROOT/android/app/build.gradle.kts" | head -1)"
if [[ "$PLIST_VERSION" != "$VERSION" || "$ANDROID_VERSION" != "$VERSION" ]]; then
  echo "Version mismatch: macOS=$PLIST_VERSION, Android=$ANDROID_VERSION, requested=$VERSION" >&2
  echo "Update macOS/Info.plist and android/app/build.gradle.kts before packaging." >&2
  exit 1
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
fi
if [[ -z "$JAVA_HOME" && -x /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java ]]; then
  JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
fi
if [[ -z "$JAVA_HOME" || ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "Java 17 is required. Set JAVA_HOME to an installed JDK." >&2
  exit 1
fi
export JAVA_HOME
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

ANDROID_BUILD_TOOLS="$(find "$ANDROID_HOME/build-tools" -maxdepth 1 -type d -print | sort | tail -1)"
APKSIGNER="$ANDROID_BUILD_TOOLS/apksigner"
if [[ ! -x "$APKSIGNER" ]]; then
  echo "Android build tools with apksigner were not found in $ANDROID_HOME." >&2
  exit 1
fi

EXPECTED_ANDROID_CERT="669674a2114fb59d85c56bba774b89fec9ce7f7ee79825769826130362a091c9"
ANDROID_OUT="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
RELEASE_DIR="$ROOT/dist/releases/v$VERSION"
DMG_STAGE="$RELEASE_DIR/dmg-stage"
SPARKLE_STAGE="$RELEASE_DIR/sparkle"
SPARKLE_BIN="$ROOT/macOS/.build/artifacts/sparkle/Sparkle/bin"
DOWNLOAD_PREFIX="https://github.com/blossom0948/connectmac/releases/download/v$VERSION/"

mkdir -p "$RELEASE_DIR"
python3 - "$DMG_STAGE" "$SPARKLE_STAGE" <<'PY'
from pathlib import Path
import shutil
import sys

for value in sys.argv[1:]:
    path = Path(value)
    if path.exists() or path.is_symlink():
        shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
    path.mkdir(parents=True)
PY

echo "Building Android APK..."
"$ROOT/android/gradlew" -p "$ROOT/android" :app:assembleDebug
ACTUAL_ANDROID_CERT="$("$APKSIGNER" verify --print-certs "$ANDROID_OUT" | sed -n 's/.*certificate SHA-256 digest: //p' | head -1 | tr -d ':[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTUAL_ANDROID_CERT" != "$EXPECTED_ANDROID_CERT" ]]; then
  echo "Android signing certificate changed; refusing to package an APK that cannot update existing installs." >&2
  exit 1
fi
cp "$ANDROID_OUT" "$RELEASE_DIR/PhoneBridge-android.apk"
APK_SHA256="$(shasum -a 256 "$RELEASE_DIR/PhoneBridge-android.apk" | awk '{print $1}')"
VERSION_CODE="$(sed -n 's/.*versionCode = \([0-9][0-9]*\).*/\1/p' "$ROOT/android/app/build.gradle.kts" | head -1)"
cat > "$RELEASE_DIR/phonebridge-update.json" <<EOF
{
  "versionName": "$VERSION",
  "versionCode": $VERSION_CODE,
  "apkUrl": "${DOWNLOAD_PREFIX}PhoneBridge-android.apk",
  "sha256": "$APK_SHA256",
  "notes": "버튼을 눌러도 페어링이 지워지지 않도록 정리하고 연결 복구를 강화했습니다. Android 화면을 연결·전송·설정 탭으로 새롭게 구성했습니다."
}
EOF

echo "Building macOS app and DMG..."
swift "$ROOT/macOS/scripts/generate-app-icon.swift"
(cd "$ROOT/macOS" && swift build -c release && ./scripts/make-app.sh)
ditto "$ROOT/macOS/.build/PhoneBridge.app" "$DMG_STAGE/PhoneBridge.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname PhoneBridge -srcfolder "$DMG_STAGE" -format UDZO -ov "$RELEASE_DIR/PhoneBridge-macOS.dmg" >/dev/null

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Sparkle tools are missing. Run (cd macOS && swift package resolve)." >&2
  exit 1
fi
if [[ -f "$ROOT/updates/appcast.xml" ]]; then
  cp "$ROOT/updates/appcast.xml" "$SPARKLE_STAGE/appcast.xml"
else
  if curl -fsSL https://github.com/blossom0948/connectmac/releases/latest/download/appcast.xml -o "$SPARKLE_STAGE/previous-appcast.xml"; then
    cp "$SPARKLE_STAGE/previous-appcast.xml" "$SPARKLE_STAGE/appcast.xml"
  fi
fi
cp "$RELEASE_DIR/PhoneBridge-macOS.dmg" "$SPARKLE_STAGE/PhoneBridge-macOS.dmg"
cat > "$SPARKLE_STAGE/PhoneBridge-macOS.md" <<EOF
PhoneBridge $VERSION

- Android 연결 해제를 설정 안의 확인 단계로 옮기고, 버튼 한 번으로 페어링이 지워지지 않게 했습니다.
- Android 화면을 연결·전송·설정 세 탭으로 나누고 글자 대비와 크기, 짧은 화면 전환과 버튼 반응을 개선했습니다.
- 암호화된 연결 확인은 정상 Mac 명령도 연결 상태 증거로 계산하며, 응답 대기 시간을 늘려 작업 중 오탐 연결 종료를 줄입니다.
- Wi-Fi 연결이 끊기거나 바뀌면 Android가 Bonjour 검색으로 Mac을 다시 찾고, 재시도 간격은 최대 30초까지 늘어납니다.
- Mac의 로컬 TCP 수신기가 오류로 중단되면 자동으로 다시 시작합니다.
EOF
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" --embed-release-notes "$SPARKLE_STAGE"
cp "$SPARKLE_STAGE/appcast.xml" "$RELEASE_DIR/appcast.xml"
mkdir -p "$ROOT/updates"
cp "$SPARKLE_STAGE/appcast.xml" "$ROOT/updates/appcast.xml"
cp "$RELEASE_DIR/phonebridge-update.json" "$ROOT/updates/phonebridge-update.json"

cat > "$RELEASE_DIR/SHA256SUMS.txt" <<EOF
$(shasum -a 256 "$RELEASE_DIR/PhoneBridge-macOS.dmg" "$RELEASE_DIR/PhoneBridge-android.apk" "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/phonebridge-update.json")
EOF

echo "Release assets ready in $RELEASE_DIR"
echo "Create the GitHub release with these files:"
echo "  PhoneBridge-macOS.dmg"
echo "  PhoneBridge-android.apk"
echo "  appcast.xml"
echo "  phonebridge-update.json"
