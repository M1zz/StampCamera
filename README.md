# 📮 펀칭 (PUNCHING)

> 꾹 눌러 뜯은 순간을 움직이는 스티커로.

펀칭기 컨셉의 움직이는 스티커 카메라(프로젝트명 StampCamera). 카메라 프리뷰 위에 펀칭
프레임이 올라가고, 꾹 누르면 프레임 안쪽이 움직이는 스티커로 뜯겨 나옵니다 — 대상만
오려 내거나(배경 제거), 대상이 없으면 우표 모양(톱니 perforation)으로. 스티커는 수집함에
모이고, 메시지 스티커·키보드·인쇄용 스티커 시트로 꺼내 씁니다.

정체성 · 용어 · 화면 구조의 기준은 [`IDENTITY.md`](IDENTITY.md), 구현 명세는 [`SPEC.md`](SPEC.md).

## 실행 방법

1. `StampCamera.xcodeproj`를 Xcode 15+에서 엽니다.
2. Signing & Capabilities에서 본인 Team을 선택합니다 (Bundle ID: `com.devkoan.StampCamera` — 필요시 변경).
3. **실제 기기**에 빌드합니다. (시뮬레이터에는 카메라가 없어 프리뷰가 검게 나옵니다.)
4. 카메라/사진 권한을 허용하면 동작합니다.

## 구조

| 파일 | 역할 |
|------|------|
| `StampShape.swift` | 우표 윤곽 path 생성. 오버레이·마스크·촬영 크롭이 **모두 같은 path**를 공유 |
| `CameraManager.swift` | AVCaptureSession 설정, 전후면 전환, 사진 촬영 |
| `CameraPreview.swift` | `AVCaptureVideoPreviewLayer`를 SwiftUI로 브릿지 (`.resizeAspectFill`) |
| `PuncherFrameView.swift` | 레퍼런스 기반 펀칭 프레임 UI (플라스틱 바디·메탈 트레이·기어·눈금자·렌즈) |
| `StampCompositor.swift` | 촬영 이미지를 화면 창 좌표에 맞춰 크롭 + 우표 모양 클리핑 → 투명 PNG |
| `ContentView.swift` | 전체 화면 조립, 셔터, 결과 시트, 앨범 저장 |

## 핵심 정합성 포인트

화면 프리뷰(`.resizeAspectFill`)와 촬영 이미지(고해상도, 다른 비율)의 좌표계를 맞추는 게
정확도의 관건입니다. `StampCompositor.makeStamp`에서 aspect-fill cover 스케일을 역산해
화면의 우표 창 rect → 원본 픽셀 rect로 변환합니다. 전면 카메라는 미러 보정이 들어갑니다.

## 커스터마이즈

- 톱니 밀도: `ContentView`의 `teethX` / `teethY`
- 프레임 크기: `widthFraction`
- 색상: `PuncherFrameView`의 `Color(hex:)` 값
- 우표 출력 해상도: `StampCompositor.makeStamp`의 `scale` (기본 3배)

## 확장 아이디어

- 우표 종이 질감(노이즈 텍스처) 오버레이
- 빈티지/세피아 필터 토글
- 여러 우표를 모으는 앨범(수집) 화면
- 우표 아래 캡션/날짜 스탬프

## 지원 · 개인정보

- [지원 페이지](https://m1zz.github.io/StampCamera/support.html) — 문의, 자주 묻는 질문
- [개인정보 처리방침](https://m1zz.github.io/StampCamera/privacy.html) — 사진·스티커는 기기 안에만 저장됩니다 (익명 사용 통계·오류 보고만 iCloud로 전송)

(소스: [`docs/`](docs/) — GitHub Pages로 서빙)
