# StampCamera — 기능 명세 (Feature Specification)

우표 펀칭 카메라 앱. 사진을 우표(천공 테두리) 모양으로 크롭해 **모으고(컬렉션)**, 골라서 **전시(액자 벽)**한다.

이 문서는 현재 구현된 기능을 명세하며, `StampCameraTests`의 테스트 대상과 1:1로 대응한다.

---

## 1. 우표 모양 — `StampShape` / `stampBezierPath` (StampShape.swift)
- 사각형 영역의 네 변을 **반원 천공(perforation)**으로 깎은 우표 외곽선. 크롭 마스크의 단일 소스.
- 파라미터: `teethX`(가로 천공 수, 기본 6), `teethY`(세로, 기본 8), `biteRatio`(천공 반지름 = `min(step)·biteRatio`, 기본 0.196).
- 모서리는 `cr = min(step)·0.12`로 살짝 둥글린 볼록 코너.
- **균일 간격**: 한 변의 모든 간격(모서리 여백 포함)이 동일하도록 천공 중심을 분배
  (`변길이 = 2·cr + teeth·2r + (teeth+1)·gap`).
- 불변식:
  - path의 바운딩 박스 ≈ 입력 rect.
  - 중심점은 path 내부, 멀리 바깥 점은 외부.
  - 윗변 천공 중심 x 위치는 path 바깥(구멍), 천공 사이 위치는 path 안쪽.
- `stampBezierPath(in:teethX:teethY:biteRatio:)`는 동일 모양의 `UIBezierPath`(크롭 클리핑용).

## 2. 크롭 합성 — `StampCompositor.makeStamp` (StampCompositor.swift)
- 입력: 원본 사진(`UIImage`), `previewSize`, `windowRect`(화면 좌표), `mirrored`, `scale`(기본 3).
- 처리: 방향을 `.up`으로 정규화 → 화면(aspect-fill) 좌표를 원본 픽셀로 역매핑 → `windowRect`를 잘라 우표 모양으로 클리핑.
- 반환: `(image, cropNorm)`
  - `image.size == windowRect.size · scale`.
  - `cropNorm`: 정규화 원본 이미지 기준 크롭 영역(0…1 사각형). 나중에 다른 테두리로 재크롭하기 위한 메타.
  - `mirrored`면 `cropNorm.minX`가 좌우 반전(`1 − (minX + width)`).
- `UIImage.normalizedUp()`: 방향을 픽셀에 구워 `.up`으로 만든 복사본.

## 3. 컬렉션 저장소 — `CollectionStore` (ContentView.swift)
디스크 백업 `ObservableObject`. `init(directory:)`로 테스트 격리 가능(기본 `Documents/Collection`).

### 모델
- `CollectedStamp { id, image, caption, album, createdAt, place }`.
- `Exhibition { name, stampIDs(순서) }`.

### 디스크 레이아웃 (우표 id = `<epoch_ms>.png`)
| 파일 | 내용 |
|---|---|
| `{id}` (png) | 우표 이미지 |
| `{id}.txt` | 캡션 |
| `{id}.grp` | 소속 우표첩 이름 |
| `{id}.json` | 메타(createdAt, lat/lon, place, cropX/Y/W/H, mirrored) |
| `{id}.orig.jpg` | 크롭 전 원본 사진 |
| `albums.json` | `{albums, active}` |
| `exhibitions.json` | `[{name, stampIDs}]` |

### 우표
- `add(image, location:, original:, cropNorm:, mirrored:) -> id`: 활성 우표첩에 추가, png/메타/원본 저장, 배열에 append.
- `setCaption(_:for:)`, `setPlace(_:for:)`(메타의 좌표/시간 보존), `move(_:to album:)`.
- `delete(_:)`: 모든 사이드카(png/txt/grp/json/orig.jpg) 제거 + 배열/전시에서 제거.
- `originalImage(for:)`: 원본 사진 로드(없으면 nil).

### 우표첩(albums)
- 기본 우표첩 `"내 우표첩"`. `reconcile()`로 최소 1개 보장, 고아 보정.
- `createAlbum`(생성+활성화), `setActive`, `renameAlbum`(우표 이동 포함), `deleteAlbum`(우표까지 삭제, 최소 1개 유지).
- `stamps(in:)`/`count(in:)`은 **전시 중인 우표 제외**.

### 전시(exhibitions) — 모으기/전시 분리
- 전시 멤버십 = 전시의 정렬된 id 목록(단일 진실). 우표의 `album`(원래 집)은 보존.
- `placeInExhibition(id, into:)`: 컬렉션에서 빠지고 전시에 추가(다른 전시에서 먼저 제거 = 단일 멤버십).
- `returnToCollection(id)`: 전시에서 빼고 원래 우표첩 복귀.
- `moveExhibitedStamp(id, to:)`, `reorderExhibition(name, moving:to:)` / `(from:to:)`.
- `renameExhibition`, `deleteExhibition`(우표는 원래 우표첩으로 복귀, 삭제 아님).
- `collectedStamps`(전시 제외), `isExhibited`, `stampsInExhibition`(순서대로), `exhibitionCount`.
- **배경**: 각 전시는 다이어리 속지 스타일(`BackgroundStyle` 10종: 크림/모눈/줄/도트/크라프트/양피지/코넬/그래프/민트/다크그리드)을 가짐. `createExhibition(_:background:)`, `setExhibitionBackground`, `backgroundStyle(of:)`. `DiaryBackground`가 Canvas로 절차 렌더. 전시 생성 시 `NewExhibitionSheet`에서 선택.
- `reconcileExhibitions()`: 존재하지 않는 우표 id 제거, 중복 멤버십 정리.
- 하위호환: `exhibitions.json` 없으면 빈 전시, 모든 우표는 우표첩에 그대로.

### 영속성
- 모든 변경은 즉시 사이드카/JSON에 기록(atomic). 새 `CollectionStore(directory:)`로 재오픈 시 우표·우표첩·전시·순서가 복원.

## 4. 색상 — `Color(hex:)` (PuncherFrameView.swift)
- `UInt32` RGB(0xRRGGBB)를 sRGB Color로. 예) `0xFF0000`→빨강.

## 5. 카메라/촬영 (UI, 테스트 범위 외)
- `CameraManager`: `AVCaptureVideoDataOutput`로 무음 캡처(시스템 셔터음 회피), portrait·비미러.
- 셔터: 프레임을 누르면 축소, 떼면 촬영 + `punching.mp3`(~1초).
- 촬영 연출: 크롭 우표가 화면 밖으로 팡 날아가고, 원본 자국이 윈도우에 ~2초 머묾.
- 위치: `LocationManager`로 촬영 장소 역지오코딩 → 우표에 장소 기록.

## 6. 전시 UI 제스처 (UI, 테스트 범위 외)
- 컬렉션 시트: 우표첩 + 전시 두 구역, 우표를 하단 전시 바로 드래그해 걸기.
- 전시 벽: 손잡이 모서리(왼/오 선택) 기준 **화투패 라디얼 부채** — 아크 스와이프로 무한 스크롤, 카드를 끌어내 드롭, 다른 곳 탭하면 접힘.

---

> 테스트(`StampCameraTests/`)는 §1–4의 순수/저장 로직을 Swift Testing으로 검증한다. §5–6은 카메라/제스처 의존이라 단위 테스트 범위 밖.
