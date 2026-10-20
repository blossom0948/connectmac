#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/package-release.sh <version> (for example 0.3.5)" >&2
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
  "notes": "사진 여러 장을 차례로 안전하게 받고, Mac에서 Android로 보내는 파일은 저장 확인과 재시도 상태를 표시합니다. Android에서 받은 파일을 다른 앱으로 공유하거나 삭제할 수 있고, 중단된 파일 조각은 연결이 끊길 때 정리합니다."
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

- Mac에서 Android로 보내는 파일을 한 개씩 처리하고 휴대폰 저장 완료를 확인합니다. 연결 오류나 저장 실패를 표시하고 재시도할 수 있습니다.
- 갤러리에서 여러 사진을 선택해 순서대로 받을 수 있으며, 이미 받는 중인 사진을 중복 요청하지 않습니다.
- Android에서 받은 파일을 전체·사진·파일로 분류하고 열기, 다른 앱으로 공유, 확인 후 삭제할 수 있습니다.
- 끊긴 연결의 불완전한 파일 조각을 정리하고, 큰 전송의 누적 용량 계산을 효율적으로 처리합니다.
- 기존 Android 설치와 macOS 앱을 자동 업데이트할 수 있도록 동일 서명 APK와 Sparkle DMG를 함께 제공합니다.
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
