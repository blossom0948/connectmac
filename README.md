# PhoneBridge

Mac과 Android 휴대폰을 같은 로컬 Wi‑Fi에서 연결하는 앱입니다. Phone Link에서 익숙한 개요·알림·메시지·통화·사진·파일·미디어·휴대폰 화면 구성을 제공합니다. EchoPods의 푸른 포인트와 둥근 표면 스타일을 잇고, macOS 26 이상에서는 플로팅 사이드바와 제어 도구 막대에 실제 SwiftUI Liquid Glass를 적용했습니다. Android는 Apple API를 사용하지 않고 Compose 기반 blur/lens 재질과 터치 피드백을 사용합니다. 기능 비교와 현재 플랫폼 경계는 [FEATURE_COMPARISON.md](FEATURE_COMPARISON.md)에 정리했습니다.

## 현재 구현된 기능

- QR 코드로 최초 페어링하고 같은 Wi‑Fi에서 Bonjour/NSD로 자동 재연결
- 페어링 키를 Mac Keychain과 Android Keystore 기반 저장소에 보관하고 연결 이벤트와 명령을 AES‑GCM으로 암호화
- Android 알림을 Mac 앱과 macOS 알림 배너로 전달하고 Mac에서 휴대폰 알림 지우기
- 알림이 Android `RemoteInput` 답장 동작을 제공하면 Mac에서 빠른 답장
- Mac에서 전화번호·문자 내용을 작성해 Android 알림으로 전달하고, 휴대폰의 기본 메시지 앱에서 확인 후 보내기
- Android에서 통화 상태를 전달하고, 전화 알림이 제공하는 받기/거절 동작을 Mac에서 실행
- 전화번호를 Android 기본 다이얼러에 전달해 사용자가 확인 후 통화 시작
- Android의 활성 미디어 세션을 이전/재생/일시 정지/다음으로 제어
- 사진과 파일을 시스템 선택기로 골라 양방향 전송하고, Mac에서 수신 파일 저장 위치 선택
- Mac에서 요청하면 연결된 Android 휴대폰에서 찾기 알림음 재생
- Android의 시스템 동의 화면으로 시작하는 화면 미리보기. Mac에서 공유 중지 가능
- 텍스트 클립보드 양방향 전송. Mac에서 전송하거나 Android 앱에서 보내기를 눌러야 하며, Mac은 수신 텍스트를 사용자가 눌러 복사
- 메인 창을 닫아도 메뉴 막대 제어와 연결 유지
- 알림·메시지 기록 검색, 최근 활동 내보내기와 기록 지우기
- 사이드바 그룹과 최근 항목 수 배지, 짧은 hover/press 반응. macOS Reduce Motion 설정도 반영
- Mac은 Sparkle로 앱 안에서 업데이트를 확인하고 받으며, Android도 앱에서 APK를 내려받아 파일 해시와 게시자 서명을 확인한 뒤 시스템 설치 화면으로 넘김

파일은 항목당 100MB, 클립보드 텍스트는 20KB까지 전송합니다. 미디어·알림·전화 동작은 Android의 알림 접근 서비스와 해당 알림/미디어 앱이 제공하는 기능을 사용합니다.

## 플랫폼 경계

PhoneBridge는 일반 앱에 공개된 API만 사용합니다. 이 제한은 비활성 화면이나 가짜 동작으로 숨기지 않고 각 화면에 안내합니다.

- **문자:** 메시지 알림 기록을 보여주고 지원되는 알림에 답장합니다. 새 문자는 Android 기본 메시지 앱에 초안을 전달하며, 사용자가 내용을 확인하고 직접 전송합니다. PhoneBridge는 SMS 데이터베이스나 전체 대화 기록을 읽지 않습니다.
- **전화:** 통화 상태와 전화 알림 동작을 지원하고 번호를 Android 다이얼러에 전달합니다. 사용자가 휴대폰에서 확인해야 하며, PhoneBridge는 긴급 전화를 처리하거나 통화 음성을 Mac으로 보내지 않습니다.
- **사진·앱 미러링:** 시스템 사진 선택기로 양방향 전송하고, 사용자가 승인한 Android 화면 미리보기를 제공합니다. Mac에서 전체 갤러리 탐색·정리, Android 앱을 데스크톱 창으로 미러링하거나 터치/키보드 입력을 보내지는 않습니다.
- **휴대폰 화면:** 사용자가 매번 Android 시스템 화면 캡처 동의를 해야 하는 저해상도 미리보기입니다. Mac에서 터치·키보드 입력을 보내거나 제조사 전용 앱 스트리밍을 제공하지 않습니다.
- **iPhone:** PhoneBridge가 iPhone 알림·문자·통화 데이터에 직접 접근하지 않습니다. Mac 화면의 iPhone 미러링 열기 버튼은 Apple 시스템 앱을 열며, 지원되는 연동은 Apple Continuity가 처리합니다.
- **네트워크 및 제조사 기능:** 현재는 같은 로컬 네트워크 연결입니다. 인터넷 릴레이, Instant Hotspot, 제조사 전용 앱 스트리밍, 다중 휴대폰 동시 연결, 자동 클립보드 감시는 포함하지 않습니다.

## 바로 실행하기

### Mac

[PhoneBridge-macOS.dmg](https://github.com/blossom0948/connectmac/releases/latest/download/PhoneBridge-macOS.dmg)을 내려받아 더블클릭합니다. 열린 창에서 **PhoneBridge.app**을 **Applications** 폴더로 끌어 놓은 뒤 앱을 실행하세요. macOS가 개발자를 확인할 수 없다고 막으면 Finder에서 앱을 Control-클릭해 **열기**를 선택합니다.

이 개발용 빌드는 ad hoc 서명만 되어 있으며 Apple Developer ID 공증은 받지 않았습니다. 공식 Release에서 받은 앱인데도 macOS가 “손상되어 열 수 없습니다”라고 표시하면 터미널에서 격리 속성을 제거한 뒤 다시 여세요.

```sh
sudo xattr -dr com.apple.quarantine /Applications/PhoneBridge.app
```

소스에서 직접 빌드하려면 저장소 폴더에서 아래 명령을 실행합니다.

Xcode Command Line Tools와 Swift 5.9 이상이 필요합니다.

```sh
cd macOS
swift build -c release
./scripts/make-app.sh
open .build/PhoneBridge.app
```

처음 실행할 때 macOS 로컬 네트워크와 알림 권한을 허용합니다.

### Android

Android 휴대폰에서 [PhoneBridge Android APK](https://github.com/blossom0948/connectmac/releases/latest/download/PhoneBridge-android.apk)를 내려받아 설치합니다. 설치를 위해 브라우저나 파일 앱에 **알 수 없는 앱 설치 허용**을 켜야 할 수 있습니다. USB 디버깅을 사용한다면 프로젝트 폴더에서 다음 명령으로 설치할 수도 있습니다.

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

직접 다시 빌드할 때는 Android SDK 36과 JDK 17을 사용합니다. `compileSdk`는 36이며 앱 실행 동작을 결정하는 `targetSdk`는 35입니다.

```sh
cd android
./gradlew :app:assembleDebug
```

## 앱 안에서 업데이트

- **Mac:** PhoneBridge 메뉴의 **업데이트 확인…** 또는 설정 화면에서 새 버전을 확인합니다. 하루 간격으로 업데이트를 확인하고, Sparkle이 새 버전을 백그라운드에서 내려받아 적용합니다. 앱이 실행 중이면 업데이트 설치를 위해 앱을 종료한 뒤 다시 열 때 적용될 수 있습니다. v0.1.0에는 업데이트 기능이 없으므로 v0.2.0을 한 번 수동 설치해야 합니다. 앱은 Developer ID 공증을 받지 않아 최초 실행 때 macOS 보안 확인이 계속 표시될 수 있습니다.
- **Android:** 앱의 **앱 업데이트** 카드에서 확인하거나, 실행할 때 6시간 간격으로 자동 확인합니다. APK는 앱 안에서 내려받고 SHA-256 및 앱 서명을 확인합니다. v0.1.0에는 업데이트 기능이 없어 v0.2.0 APK를 한 번 수동 설치해야 합니다. 그 뒤 설치는 Android 시스템 확인 화면에서 승인하며, 처음 한 번 PhoneBridge의 **알 수 없는 앱 설치 허용**을 켜야 할 수 있습니다. 일반 Android 앱은 사용자 확인 없이 자체 APK를 조용히 설치할 수 없습니다.
- 두 앱 모두 업데이트 확인과 다운로드는 PhoneBridge 안에서 시작되며, 웹 브라우저로 이동하지 않습니다. macOS와 Android가 요구하는 최초 설치·시스템 확인은 OS 화면을 거칩니다.

## 새 버전 배포

Mac과 Android의 버전을 각각 `macOS/Info.plist`와 `android/app/build.gradle.kts`에서 같은 값으로 올리고 Android `versionCode`도 증가시킨 뒤 다음 명령을 실행합니다.

```sh
scripts/package-release.sh 0.3.0
```

이 명령은 DMG, APK, Sparkle `appcast.xml`, Android `phonebridge-update.json`을 `dist/releases/v0.3.0/`에 만듭니다. 이 네 파일을 같은 이름으로 GitHub의 `v0.3.0` 릴리스에 올리면 각 앱의 내장 업데이트 주소가 그 릴리스를 읽습니다. Android 업데이트가 기존 설치 위에 적용되려면 릴리스 서명 키가 계속 같아야 합니다. 스크립트는 키가 바뀌면 배포용 파일 생성을 중단합니다.

## 처음 연결하기

1. Mac과 Android를 같은 Wi‑Fi에 연결합니다. 게스트 Wi‑Fi나 기기 간 통신 차단이 켜진 네트워크에서는 연결되지 않을 수 있습니다.
2. Mac에서 PhoneBridge를 실행합니다. 개요에 표시되는 QR 코드는 5분 동안 유효합니다.
3. Android에서 PhoneBridge를 열고 **Mac QR 코드 스캔**을 눌러 QR을 읽습니다.
4. Android에서 알림 전달·빠른 답장·알림 지우기·미디어 제어를 쓰려면 알림 권한과 **알림 접근 허용**을 켭니다. 새 문자·전화 요청은 휴대폰 알림을 거칩니다. 통화 상태는 별도의 선택 권한입니다.
5. 필요할 때 파일·사진 전송, 클립보드 보내기, 화면 공유 기능을 사용합니다. 화면 공유는 Android 시스템 확인 창에서 매번 허용해야 합니다.

연결이 끊겨도 페어링 정보가 남아 있으면 같은 네트워크에서 Android 앱 서비스가 Mac을 다시 찾습니다. 다른 휴대폰으로 바꾸려면 Mac의 QR 페어링 카드를 먼저 **기기 연결 해제**하고 새 휴대폰에서 다시 스캔합니다.

## 개인정보 및 저장

- 알림 접근을 켜면 알림 제목과 내용이 Mac으로 전송됩니다. 이 앱은 데이터를 서버로 보내지 않으며 최근 이벤트는 Mac 앱 메모리에 보관합니다.
- QR 페어링은 로컬 주소와 일회용 비밀값을 포함합니다. QR을 신뢰하는 기기만 스캔하세요.
- 클립보드는 자동으로 읽거나 동기화하지 않습니다. 텍스트 전송은 사용자가 버튼을 눌렀을 때만 시작합니다. Android는 Mac에서 받은 클립보드 텍스트를 시스템 클립보드에 넣고, Android 13 이상에서는 시스템 복사 확인이 표시됩니다.
- 받은 파일은 Mac에서 저장 위치를 묻고, Android에서는 앱 전용 Downloads 폴더에 저장합니다.
- Android가 화면 공유를 시작할 때 시스템 캡처 동의가 필요하며, Android 상태 표시줄에서 언제든 공유를 중지할 수 있습니다.
