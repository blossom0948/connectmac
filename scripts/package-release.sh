#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
DEVELOPER_ID="${PHONEBRIDGE_DEVELOPER_ID:-}"
NOTARY_PROFILE="${PHONEBRIDGE_NOTARY_PROFILE:-}"
if [[ -z "$DEVELOPER_ID" || -z "$NOTARY_PROFILE" ]]; then
  if [[ "${PHONEBRIDGE_ALLOW_UNNOTARIZED:-0}" != "1" ]]; then
    echo "A Developer ID Application identity and notarytool keychain profile are required for a distributable Mac DMG." >&2
    echo "Set PHONEBRIDGE_DEVELOPER_ID and PHONEBRIDGE_NOTARY_PROFILE. For a local-only build, explicitly set PHONEBRIDGE_ALLOW_UNNOTARIZED=1." >&2
    exit 1
  fi
  if [[ -n "$DEVELOPER_ID" || -n "$NOTARY_PROFILE" ]]; then
    echo "Set both signing and notarization values, or unset both for the explicit unnotarized local build." >&2
    exit 1
  fi
fi
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/package-release.sh <version> (for example 0.3.6)" >&2
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
  "notes": "양방향 파일 전송 진행률과 취소를 제공하고 Wi-Fi가 다시 연결되면 중단한 위치부터 이어받습니다. 연결·전송 진단 기록은 개인정보를 제외하고 공유할 수 있습니다."
}
EOF

echo "Building macOS app and DMG..."
swift "$ROOT/macOS/scripts/generate-app-icon.swift"
(cd "$ROOT/macOS" && swift build -c release && ./scripts/make-app.sh)
APP="$ROOT/macOS/.build/PhoneBridge.app"
if [[ -n "$DEVELOPER_ID" ]]; then
  FRAMEWORKS="$APP/Contents/Frameworks"
  while IFS= read -r -d '' CODE_FILE; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$CODE_FILE"
  done < <(find "$FRAMEWORKS" -type f -perm -111 -print0)
  while IFS= read -r -d '' CODE_BUNDLE; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$CODE_BUNDLE"
  done < <(find "$FRAMEWORKS" -depth -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
fi
ditto "$ROOT/macOS/.build/PhoneBridge.app" "$DMG_STAGE/PhoneBridge.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname PhoneBridge -srcfolder "$DMG_STAGE" -format UDZO -ov "$RELEASE_DIR/PhoneBridge-macOS.dmg" >/dev/null

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "Submitting Mac DMG for Apple notarization..."
  xcrun notarytool submit "$RELEASE_DIR/PhoneBridge-macOS.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$RELEASE_DIR/PhoneBridge-macOS.dmg"
  xcrun stapler validate "$RELEASE_DIR/PhoneBridge-macOS.dmg"
else
  echo "Building an explicitly unnotarized local-only DMG. Do not publish this file."
fi

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

- 양방향 파일 전송 진행률, 취소, Wi-Fi 재연결 후 이어받기와 진단 기록 내보내기를 추가했습니다.
- Mac 배포 DMG는 Developer ID 서명과 Apple 공증 후 티켓을 첨부합니다.
- 갤러리에서 여러 사진을 선택해 순서대로 받을 수 있으며, 이미 받는 중인 사진을 중복 요청하지 않습니다.
- Android에서 받은 파일을 전체·사진·파일로 분류하고 열기, 다른 앱으로 공유, 확인 후 삭제할 수 있습니다.
- 끊긴 연결의 불완전한 파일 조각을 정리하고, 큰 전송의 누적 용량 계산을 효율적으로 처리합니다.
- 기존 Android 설치와 macOS 앱을 자동 업데이트할 수 있도록 동일 서명 APK와 Sparkle DMG를 함께 제공합니다.
EOF
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" --embed-release-notes "$SPARKLE_STAGE"
cp "$SPARKLE_STAGE/appcast.xml" "$RELEASE_DIR/appcast.xml"
if [[ -n "$DEVELOPER_ID" ]]; then
  mkdir -p "$ROOT/updates"
  cp "$SPARKLE_STAGE/appcast.xml" "$ROOT/updates/appcast.xml"
  cp "$RELEASE_DIR/phonebridge-update.json" "$ROOT/updates/phonebridge-update.json"
else
  echo "Stable update feeds were left unchanged because this is an unnotarized local-only build."
fi

cat > "$RELEASE_DIR/SHA256SUMS.txt" <<EOF
$(shasum -a 256 "$RELEASE_DIR/PhoneBridge-macOS.dmg" "$RELEASE_DIR/PhoneBridge-android.apk" "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/phonebridge-update.json")
EOF

echo "Release assets ready in $RELEASE_DIR"
echo "Create the GitHub release with these files:"
echo "  PhoneBridge-macOS.dmg"
echo "  PhoneBridge-android.apk"
echo "  appcast.xml"
echo "  phonebridge-update.json"
