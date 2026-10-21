# StampCamera — 기능 명세 (Feature Specification)

움직이는 스티커 카메라. 펀칭기로 꾹 눌러 순간을 스티커(오려낸 모양 또는 우표 모양)로 **뜯고**, 수집함에 **담고**, 메시지·키보드·인쇄로 **쓴다**.

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

## 3. 수집함 저장소 — `CollectionStore` (ContentView.swift)
디스크 백업 `ObservableObject`. `init(directory:)`로 테스트 격리 가능(기본 `Documents/Collection`).
스티커를 묶는 방법은 **수집함 하나뿐**이다 (IDENTITY.md). 수집함 하나가 메시지·키보드의 스티커 팩 하나다.

### 모델
- `CollectedStamp { id, image, caption, album, createdAt, place }`.
- `AlbumDecor { background?, order? }` — 수집함의 속지와 직접 정한 순서(자유롭게 꾸미기).

### 디스크 레이아웃 (스티커 id = `<epoch_ms>.png`)
| 파일 | 내용 |
|---|---|
| `{id}` (png) | 스티커 이미지 |
| `{id}.txt` | 한 마디 |
| `{id}.grp` | 소속 수집함 이름 |
| `{id}.json` | 메타(createdAt, lat/lon, place, cropX/Y/W/H, mirrored, filter, style) |
| `{id}.orig.jpg` | 크롭 전 원본 사진 |
| `albums.json` | `{albums, active, decor?}` |
| `exhibitions.migrated.json` | 옛 컬렉션 파일(이전 후 이름만 바꿔 보관) |

### 스티커
- `add(image, location:, original:, cropNorm:, mirrored:) -> id`: 활성 수집함에 추가, png/메타/원본 저장, 배열에 append.
- `setCaption(_:for:)`, `setPlace(_:for:)`(메타의 좌표/시간 보존), `move(_:to album:)`.
- `delete(_:)`: 모든 사이드카(png/txt/grp/json/orig.jpg/클립) 제거.
- `originalImage(for:)`: 원본 사진 로드(없으면 nil).
- `makeExport(for:done:)`: 복사·공유용 — 움직이면 GIF, 아니면 고해상도 투명 PNG.
- `repairBrokenMotion()`: '움직임'인데 안 움직이는 스티커를 열 때 자동으로 바로잡음(다시 만들거나 같은 모양의 멈춤으로). 지우지 않음.

### 수집함(albums)
- 기본 수집함 `"내 수집함"`. `reconcile()`로 최소 1개 보장, 고아 보정.
- `createAlbum`(생성+활성화), `setActive`, `renameAlbum`(스티커·꾸미기 함께 이동), `deleteAlbum`(스티커까지 삭제, 최소 1개 유지).
- `stamps(in:)`: 직접 정한 순서가 있으면 그 순서가 먼저, 나머지는 오래된 순(새로 뜯은 것은 끝에).
- **자유롭게 꾸미기**: `reorder(in:moving:to:)`, `isArranged`, `resetOrder`(찍은 순서로), `setBackground(_:for:)` / `backgroundStyle(of:)`.
  속지는 `BackgroundStyle` 10종(크림/모눈/줄/도트/크라프트/양피지/코넬/그래프/민트/다크그리드), `DiaryBackground`가 Canvas로 절차 렌더.
- 스티커 팩: `saveMeta()`마다 `syncStickers()` → `Stickers/collections.json`에 수집함별 `{name, files}`(수집함 순서).

### 컬렉션 → 수집함 이전 (한 번)
- `exhibitions.json`이 있으면 컬렉션마다 같은 이름의 수집함을 만들고 스티커를 **옮긴다**(이름이 겹치면 `이름 (컬렉션)`).
- 배경과 순서는 꾸미기로 옮기고, 파일은 `exhibitions.migrated.json`으로 이름만 바꾼다. 다시 열어도 다시 돌지 않는다.

### 영속성
- 모든 변경은 즉시 사이드카/JSON에 기록(atomic). 새 `CollectionStore(directory:)`로 재오픈 시 스티커·수집함·꾸미기·순서가 복원.

## 4. 색상 — `Color(hex:)` (PuncherFrameView.swift)
- `UInt32` RGB(0xRRGGBB)를 sRGB Color로. 예) `0xFF0000`→빨강.

## 5. 카메라/촬영 (UI, 테스트 범위 외)
- `CameraManager`: `AVCaptureVideoDataOutput`로 무음 캡처(시스템 셔터음 회피), portrait·비미러.
- 셔터: 프레임을 누르면 축소, 떼면 촬영 + `punching.mp3`(~1초).
- 촬영 연출: 크롭 우표가 화면 밖으로 팡 날아가고, 원본 자국이 윈도우에 ~2초 머묾.
- 위치: `LocationManager`로 촬영 장소 역지오코딩 → 우표에 장소 기록.

## 6. 수집함 UI 제스처 (UI, 테스트 범위 외)
- 3×4 책장, 가로로 넘김(설정 ▸ 책처럼 넘기기로 종이 넘김).
- 탭 = 스티커 보기, 꾹 = 복사 · 보내기 · 다른 수집함으로 · 삭제(시스템 컨텍스트 메뉴라 넘김을 막지 않음).
- 선택 모드: 여러 장 옮기기 · 삭제.
- ⋯ ▸ 자유롭게 꾸미기: 아래에 속지 고르기, 스티커를 꾹 눌러 들어 올려 같은 손가락으로 원하는 칸에 놓기.

---

> 테스트(`StampCameraTests/`)는 §1–4의 순수/저장 로직을 Swift Testing으로 검증한다. §5–6은 카메라/제스처 의존이라 단위 테스트 범위 밖.
