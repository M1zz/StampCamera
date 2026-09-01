# 잠금화면 · 제어센터 카메라 버튼 설정

배포 타깃은 이미 **iOS 18.0**로 올렸고, 앱 쪽 배선(딥링크 `kkuk://camera`,
`OpenKkukCameraIntent`, 앱 숏컷, 카메라 라우터)은 앱 타깃에 들어가 빌드까지
확인했습니다. 남은 건 **제어센터 전용 컨트롤 위젯 타깃**을 Xcode에서 추가하는
일뿐입니다. (Xcode가 코드사인·프로비저닝·Info.plist를 자동 생성해 주므로
이 부분만 GUI로 하는 게 안전합니다.)

## 지금 당장 (타깃 추가 없이) 되는 것
앱을 한 번 실행하면 `OpenKkukCameraIntent`가 시스템에 등록됩니다. 그러면:
- **제어센터**: 설정 → 제어센터(또는 제어센터에서 + 버튼) → "꾹 카메라 열기"
  앱 숏컷을 추가
- **잠금화면**: 잠금화면 길게 누르기 → 사용자화 → 잠금화면 → 컨트롤 영역에
  같은 숏컷 추가
- **액션 버튼 / Siri**: "꾹 열기"

탭하면 앱이 떠서 곧장 라이브 카메라로 들어갑니다(열려 있던 시트/모음은 닫힘).

## 폴리시된 전용 컨트롤 (KkukControls 위젯 익스텐션)
1. **File ▸ New ▸ Target… ▸ Widget Extension** 선택.
   - Product Name: `KkukControls`
   - "Include Live Activity" 체크 해제, "Include Configuration App Intent" 해제
   - Embed in Application: `StampCamera`
2. 생성된 타깃의 **Deployment Target을 iOS 18.0**으로 설정.
3. Xcode가 만든 기본 위젯 소스(예: `KkukControls.swift`)는 지워도 됩니다.
   대신 이 폴더의 **`KkukControlWidget.swift`** 를 타깃에 추가하세요
   (File Inspector ▸ Target Membership ▸ `KkukControls` 체크).
   - 만약 Xcode가 생성한 `@main WidgetBundle`을 남겨 둘 거면, 그 번들 body에
     `KkukCameraControl()` 만 넣고 이 파일의 `KkukControlsBundle`(중복 @main)은
     지우세요. (`@main`은 타깃당 하나)
4. **`StampCamera/OpenKkukCameraIntent.swift`** 를 열어 File Inspector에서
   `KkukControls` 타깃 멤버십도 체크 (앱·익스텐션이 같은 인텐트를 공유).
5. 빌드 → 실행. 제어센터 갤러리(+)에 "꾹 카메라"가 뜨고, 탭 한 번에 앱이
   카메라로 열립니다. 같은 컨트롤을 잠금화면 컨트롤 슬롯에도 넣을 수 있습니다.

> 컨트롤은 `OpenKkukCameraIntent`(openAppWhenRun = true)를 실행 → 앱을
> 포그라운드로 올리고 `CameraLaunchRouter`가 카메라로 라우팅합니다.

## (선택) 잠금 상태에서 바로 촬영 — LockedCameraCapture
위 컨트롤은 잠금화면에서 탭하면 Face ID 해제 후 앱 카메라로 들어갑니다.
**잠금을 풀지 않고도** 잠금화면에서 바로 촬영까지 하려면 별도의
`LockedCameraCaptureExtension`(iOS 18)이 필요합니다. 이건 자체 UI·세션을 가진
또 하나의 익스텐션 타깃이고, 촬영 결과를 App Group으로 본체에 넘기는 작업이
따로 듭니다. 원하면 다음 단계로 스캐폴딩해 드릴게요:
- 새 타깃: *Locked Camera Capture Extension*
- 엔타이틀먼트: `com.apple.developer.locked-camera-capture` + App Group 공유
- `LockedCameraCaptureExtension` 구현 + 본체와 공유하는 캡처 UI
