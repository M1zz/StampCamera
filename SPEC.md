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
- 스티커 팩: `saveMeta()`마다 `syncStickers()` → `Stickers/collections.json`에 수집함별 `{name, files}`(수집함 순서)와
  `words`(파일 이름 → 찾을 말). 한 마디 · 장소를 바꿔도 다시 내보낸다.

### 찾기
- `searchWords`: 스티커마다 찾을 말(소문자) — 한 마디 · 장소 · 수집함 · 스티커 글자 · 날짜. 앱과 확장이 같은 말을 쓴다.
- `search(_:)`: 띄어 쓴 낱말이 모두 들어 있는 스티커를 새것부터. 빈 말이면 빈 결과.
- 앱: 수집함 목록의 찾기 칸. 메시지 확장: 서랍 위 찾기 칸(치기 시작하면 서랍이 펴진다).
  키보드: 입력창에 방금 친 낱말(조사가 붙으면 뒤에서 줄여 두 글자까지)에 맞는 스티커를 그 낱말 칩으로 먼저 보여 준다.

### 테두리 · 글자 — `StickerDecor` (StickerDecor.swift)
- 테두리 없음/얇게/보통/두껍게 × 색 6, 스티커 아래 글자(최대 24자). 메타 `outline` · `outlineColor` · `label`.
- 원본에서 다시 만들 때 마지막에 입힌다(`finishLook`: 색감 → 테두리 · 글자). 정지 · 움직임 프레임 · 내보내기 · 메시지 스티커에 모두 같다.

### 파일로 꺼내기 · 수집함 보내기 — `StickerArchive` (StickerArchive.swift)
- `.kkuk` 묶음(Apple Archive). `makeArchive(album:)`: nil 이면 전부(수집함 정보 포함), 아니면 그 수집함만.
- `importArchive(at:)`: 더하기만 한다. 같은 id 는 건너뛴다. 정해진 이름 꼴의 일반 파일만 받는다(경로 탈출 · 링크 · 과대 파일 차단).
- 자동 백업은 LeeoKit 백업 금고가 맡는다(설정 ▸ 지원 ▸ 백업 및 복원). 앱이 따로 하지 않는다.

### 컬렉션 → 수집함 이전 (한 번)
- `exhibitions.json`이 있으면 컬렉션마다 같은 이름의 수집함을 만들고 스티커를 **옮긴다**(이름이 겹치면 `이름 (컬렉션)`).
- 배경과 순서는 꾸미기로 옮기고, 파일은 `exhibitions.migrated.json`으로 이름만 바꾼다. 다시 열어도 다시 돌지 않는다.

### 영속성
- 모든 변경은 즉시 사이드카/JSON에 기록(atomic). 새 `CollectionStore(directory:)`로 재오픈 시 스티커·수집함·꾸미기·순서가 복원.

## 4. 색상 — `Color(hex:)` (PuncherFrameView.swift)
- `UInt32` RGB(0xRRGGBB)를 sRGB Color로. 예) `0xFF0000`→빨강.

## 5. 카메라/촬영 (UI, 테스트 범위 외)
- `CameraManager`: `AVCaptureVideoDataOutput`로 무음 캡처(시스템 셔터음 회피), portrait·비미러.
- 화면: 미리보기가 화면을 가득 채운다(펀칭 틀과 좁은 창은 2026-11 에 걷어 냈다). 아래 가운데 둥근 셔터.
- 셔터: 꾹 누르면 들어가고, 떼면 촬영 + `punching.mp3`(~1초).
- 줌(`ZoomControl`): 평소에는 배율 단추(0.5 · 1× · 2 …)만. 길게 누르면 각도기 같은 다이얼이 펴지고 누른 채 좌우로 밀어 맞춘다(로그 눈금 `ZoomScale`, 왼쪽으로 밀면 당겨 찍기). 손을 떼면 1.2초 뒤 접힌다. 두 손가락 벌리기도 그대로.
- 찍은 뒤 — 사진 한 장에서 스티커 여러 개 (`StickerPicking.swift`)
  - `PhotoShot`: 화면에 보이던 그대로의 사진 + 대상 지도(`SubjectMap`) + 얼굴 자리.
  - 후보(`StickerProposals.plan`): 큰 대상부터 하나씩 → 모두 함께(둘 이상) → 얼굴만 크게(대상의 절반보다 작을 때) → 사진 그대로(가운데, 우표 모양).
  - 고른 후보는 가운데에 스티커가 된 모습 그대로 크게 뜬다(실제와 같은 규칙으로 다시 오려낸 그림, 네모 테두리 없음). 사진을 누르면 걷힌다. 사진에서는 고른 대상만 밝다.
  - 움직임 단추(카메라로 찍었을 때만): 움직이는 스티커로 담을지 고른다. 켜면 가운데 그림도 움직인다. 처음 값은 설정의 기본.
  - 직접 그리기: 둘러 그린 영역 안에서 대상을 한 번 더 찾는다(`StickerMask.refine`). 대상이 60% 넘게 안에 있으면 그 대상을 통째로, 일부만 둘렀으면 그 부분만 대상의 가장자리를 따라 딴다. 영역 안에 대상이 없을 때만 그린 모양 그대로. 대상이 테두리 밖으로 조금 삐져나가도 담기게 둘레에 15% 여유를 둔다.
  - 화질: 스티커는 원본 사진의 해상도로 자른다(`PhotoShot.crop`, 긴 변 최대 1200px, 원본보다 늘리지 않는다). 다시 만들기 · 손보기도 같은 크기.
  - 움직임: 처음에는 언제나 멈춘 스티커. 움직임 단추를 켰을 때만 움직이는 스티커로 담는다(움직임 원본은 늘 함께 남아 나중에 상세에서 켤 수 있다).
  - 손떨림 보정(`Stabilizer`): 움직임 프레임을 가운데 장에 맞춰 옮긴다(Vision 평행 이동 정렬). 긴 변의 8%보다 크게 밀린 장은 카메라를 옮긴 것으로 보고 두며, 옮기며 드러난 가장자리는 원래 장으로 메운다.
  - 고르는 화면(`SubjectPickView`): 아래 줄의 후보를 여러 개 골라 한 번에 담는다. 사진 속 대상을 눌러도 골라진다. "직접 그리기"로 손가락으로 둘러 그린 부분이 후보로 더해진다.
  - 담기(`CollectionStore.addStickers`): 후보의 자리가 조각의 창이 된다. 같은 사진에서 나온 스티커는 원본 한 장을 나눠 쓴다(하드링크). 멈춘 스티커를 먼저 담고 움직임은 그 뒤에 잘라 붙인다.
  - 조각 안에서는 가장 큰 대상과 가장자리에 걸리지 않은 대상만 남긴다(`SubjectMap.kept`).
  - 사진에서 가져오기도 같은 화면을 쓴다(움직임 없음).
- 손으로 정한 모양: `<id>.cut` (불투명한 곳만 남는 그림). 있으면 자동 오려내기 대신 그 모양대로 오린다(`stillLook` · `clipLook` 의 `mask`).
  - 직접 그린 스티커는 태어날 때부터 가진다. 스티커 상세 ▸ "오려낸 가장자리 손보기"(`EdgeEditView`)에서 지우기 · 되살리기 · 되돌리기 · 자동으로 다시 오려내기.
  - 움직이는 스티커에서는 모양이 프레임마다 같다(테두리는 그대로, 안의 장면만 움직인다). 백업 · 보내기 묶음에 함께 들어간다.
- 촬영 연출: 담으면 첫 스티커가 카드로 뜨고, 여럿이면 "스티커 n개를 담았어요".
- 위치: `LocationManager`로 촬영 장소 역지오코딩 → 우표에 장소 기록.

## 6. 수집함 UI 제스처 (UI, 테스트 범위 외)
- 3×4 책장, 가로로 넘김(설정 ▸ 책처럼 넘기기로 종이 넘김).
- 탭 = 스티커 보기, 꾹 = 복사 · 보내기 · 다른 수집함으로 · 삭제(시스템 컨텍스트 메뉴라 넘김을 막지 않음).
- 선택 모드: 여러 장 옮기기 · 삭제.
- ⋯ ▸ 자유롭게 꾸미기: 아래에 속지 고르기, 스티커를 꾹 눌러 들어 올려 같은 손가락으로 원하는 칸에 놓기.

---

> 테스트(`StampCameraTests/`)는 §1–4의 순수/저장 로직을 Swift Testing으로 검증한다. §5–6은 카메라/제스처 의존이라 단위 테스트 범위 밖.
