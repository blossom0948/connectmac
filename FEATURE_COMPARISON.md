# Phone Link과 PhoneBridge 기능 비교

조사일: 2026-10-20. Microsoft의 Phone Link 기능은 Android 제조사·모델·OS 버전과 Windows 빌드에 따라 달라진다. 아래 표는 공개된 Phone Link 기능을 기준으로, 현재 PhoneBridge에서 실제로 제공하는 동작과 구분한다.

## Windows Phone Link에서 확인한 기능

| Phone Link 기능 | PhoneBridge 현재 지원 | 차이와 조건 |
|---|---|---|
| 휴대폰 상태와 연결 | QR 1회 페어링, 같은 Wi‑Fi 자동 재연결, 연결·배터리·통화 상태 | 인터넷 중계와 여러 휴대폰 동시 연결은 없음 |
| Android 알림 | 현재 활성 알림과 새 알림, Mac 알림 배너, 선택한 휴대폰 알림 지우기, 검색·내보내기·기록 삭제 | Android 알림 접근 및 macOS 알림 권한 필요. 이미 사라진 항목은 지울 수 없음 |
| 메시지 | 메시지 알림, 알림 빠른 답장, Mac에서 새 문자 초안을 보내고 Android 기본 메시지 앱에서 마무리 | 전체 SMS 대화 기록을 읽거나 Android 백그라운드에서 SMS를 직접 전송하지 않음 |
| 전화 | 통화 상태, 전화 알림의 가능한 동작, 번호를 Android 다이얼러로 전달 | 사용자가 휴대폰에서 통화를 확인·시작해야 함. 음성은 Bluetooth/휴대폰 경로로 유지 |
| 최근 사진 보기 | Mac에서 허용 범위의 Android 사진 목록·썸네일 탐색, 원본 다운로드, 양방향 사진 전송 | Android 사진 접근 권한 필요. Android 14 이상 부분 선택 권한이면 선택한 미디어만 표시. 파일당 최대 100MB |
| 파일 전송 | 시스템 선택기와 Mac 끌어놓기, Android 시스템 공유 메뉴를 이용한 양방향 전송 | Mac 수신 위치 선택, Android 전용 Downloads 저장. 파일당 최대 100MB |
| Android 앱을 PC에서 열기 | Android 화면 미리보기와 사용자가 선택한 탭·스와이프·뒤로·홈·최근 앱 조작 | 화면 공유와 Android 접근성 원격 터치를 각각 사용자가 승인해야 함. 앱을 개별 데스크톱 창으로 열지 않으며, 보호된 화면은 조작을 막을 수 있음 |
| 미디어 제어 | 이전·재생/일시정지·다음 | Android 알림 접근과 앱의 미디어 세션 지원에 의존 |
| 기기 간 복사·붙여넣기 | 버튼으로 시작하는 텍스트 전송 | 자동 감시·동기화 없음. 텍스트만, 전송당 20KB |
| Instant Hotspot 및 제조사 연동 | 없음 | 통신사·기기 제조사별 지원과 OS 권한에 묶이는 기능 |
| 연결 기능 설정 | 기본 권한을 Android와 macOS 시스템 설정에서 관리 | Phone Link의 기능별 동기화 토글, 전송 폴더 지정, 배경화면 동기화, 모바일 데이터 동기화는 없음 |
| 앱 업데이트 | Mac Sparkle 업데이트 창, Android 앱 내 확인·다운로드 및 OS 설치 확인 | 두 플랫폼 모두 업데이트는 앱에서 시작하지만 운영체제 설치 승인은 사용자 확인이 필요함 |
| iPhone 연동 | Mac에서 Apple iPhone 미러링 앱 열기 | PhoneBridge가 iPhone 알림·메시지·통화 데이터를 직접 수집하지 않음 |

Phone Link에서 앱 실행·클립보드·일부 파일 기능은 제조사와 기종에 따라 지원 범위가 다르다. PhoneBridge는 지원되지 않는 기능을 완료된 것처럼 표시하지 않고, Android와 macOS의 공개 API로 동작하는 범위를 화면에서 안내한다.

## 이 버전에 추가한 실사용 흐름

- **새 문자:** Mac에서 번호와 내용을 작성하면 Android에 비공개 알림이 온다. 알림을 눌러 기본 메시지 앱에서 내용을 확인하고 사용자가 전송한다. SMS 권한으로 백그라운드 전송하지 않는다.
- **전화 걸기:** Mac에서 번호를 입력하면 Android 다이얼러를 여는 알림이 온다. 사용자가 휴대폰에서 번호를 확인하고 통화 버튼을 누른다.
- **알림 정리:** Mac에서 알림 항목을 눌러 Android 알림 창에서도 해당 알림을 지울 수 있다. Android 알림 접근 서비스가 연결되어 있고 알림이 아직 활성 상태여야 한다.
- **알림·메시지 찾기:** 현재 메모리에 보관된 최근 이벤트를 검색하고, 알림 데이터를 JSON으로 내보내거나 최근 기록 전체를 지울 수 있다.
- **탐색:** 기능을 휴대폰, 공유, 앱 그룹으로 정리하고 알림·메시지·통화 항목의 개수를 표시한다.
- **갤러리:** Mac에서 Android 사진을 40개 단위로 가져오며, 썸네일만 목록에서 전송하고 원본은 사용자가 누른 경우에만 내려받는다.
- **화면 조작:** Android 접근성 서비스에서 창 내용 읽기는 끄고 제스처만 허용한다. 활성 MediaProjection 세션이 없으면 터치 명령을 Android가 거부한다.
- **파일 전달:** Mac 파일 선택에서 여러 항목을 고르거나 파일을 끌어놓을 수 있다. Android 앱은 시스템 공유 메뉴에서 PhoneBridge를 대상으로 선택할 수 있다.

## 아직 제공하지 않는 기능과 이유

- **전체 SMS 대화함 및 임의 발송:** Android는 SMS Provider에 쓰기와 새 SMS/MMS 전달을 기본 SMS 앱 역할로 제한한다. PhoneBridge는 기본 메시지 앱을 대체하거나 MMS 전달 책임을 맡지 않으며, 이미 지원하는 알림 빠른 답장과 기본 앱 초안 흐름을 유지한다.
- **인터넷 중계·다중 휴대폰:** 지금은 동일 로컬 네트워크에서 한 기기를 연결한다. 원격 릴레이를 제공하려면 별도의 공개 서버, TLS 운영, 인증 및 배포 기반이 필요하다.
- **자동 클립보드:** 민감한 클립보드를 백그라운드에서 감시하지 않는다. Android는 사용자가 앱을 직접 누른 경우에만 클립보드 읽기를 제공한다.
- **통화 음성 전달:** Android 통화 오디오 라우팅은 기본 전화 앱·통신사/Telecom·Bluetooth 오디오 경로에 묶여 일반 컴패니언 앱에서 임의의 Wi‑Fi 음성 전달로 구현되지 않는다.
- **iPhone 데이터 직접 연결:** PhoneBridge는 iOS의 개인 알림·SMS·통화에 접근하는 공개 API가 없다. iPhone은 Apple의 iPhone 미러링 및 Continuity 기능을 사용한다.
- **Instant Hotspot 및 제조사 전용 앱 스트리밍:** 기기 제조사·통신사 권한 또는 전용 PC 연동 구성요소가 필요하다.

## 디자인 원칙

macOS의 Liquid Glass는 플로팅 내비게이션과 주요 제어 계층에만 사용한다. 알림과 메시지 같은 콘텐츠는 읽기 쉬운 표면에 두고, 글래스 표면을 중첩하지 않는다. 포인터가 있는 Mac에서는 hover 이동을 제공하며 Reduce Motion 설정을 존중한다. Android는 Apple 재질 API를 사용하지 않고 Compose 재질과 터치 피드백으로 같은 시각적 위계를 만든다.

## 공식 참고 자료

- [Microsoft Phone Link requirements and setup](https://support.microsoft.com/en-us/windows/apps/phonelink/phone-link-requirements-and-setup)
- [Microsoft: set up notifications](https://support.microsoft.com/en-gb/windows/apps/phonelink/setting-up-notifications-in-the-phone-link)
- [Microsoft: seamless content transfer](https://support.microsoft.com/en-us/windows/apps/phonelink/seamlessly-transfer-content-between-your-devices)
- [Microsoft: use Android apps on your PC](https://support.microsoft.com/en-us/windows/apps/mobileapps/use-apps-from-your-android-device-on-your-pc)
- [Microsoft: Instant Hotspot](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/instant-hotspot)
- [Microsoft: additional Phone Link features and settings](https://support.microsoft.com/en-us/windows/apps/phonelink/additional-features-and-settings-in-phone-link)
- [Microsoft: message from your PC](https://support.microsoft.com/en-us/windows/apps/phonelink/send-and-receive-text-messages-from-your-pc)
- [Microsoft: calls from your PC](https://support.microsoft.com/en-us/windows/apps/make-and-receive-phone-calls-from-your-pc)
- [Microsoft: manage Android photos](https://support.microsoft.com/en-gb/windows/apps/photos/view-and-manage-photos-from-your-android-device-on-your-pc)
- [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple SwiftUI: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Android Intent API](https://developer.android.com/reference/android/content/Intent)
- [Android background activity and service restrictions](https://developer.android.com/develop/background-work/background-tasks/foreground-services)
- [Android: partial photo and video access](https://developer.android.com/about/versions/14/changes/partial-photo-video-access)
- [Android: AccessibilityService gestures](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#dispatchGesture(android.accessibilityservice.GestureDescription,android.accessibilityservice.AccessibilityService.GestureResultCallback,android.os.Handler))
- [Android: Telephony and the default SMS app](https://developer.android.com/reference/android/provider/Telephony)
- [Android: SMS permissions](https://developer.android.com/reference/android/Manifest.permission#SEND_SMS)
