#!/bin/sh
# 스토어 원본 스크린샷을 시뮬레이터에서 다시 찍는다 → docs/screenshots/raw/ko/
#
# 사용법:
#   sh scripts/capture_screenshots.sh <Debug .app 경로> [시뮬레이터 UDID]
#
# 앱의 DEBUG 전용 실행 인자(StampCamera/ScreenshotScene.swift)를 쓴다:
#   -ScreenshotSeed docs/screenshots/seed   사진을 기본 모양 스티커로 담는다
#   -ScreenshotScene <장면>                 그 화면을 바로 연다
# 장면마다 새로 설치해 빈 상태에서 시작하므로 결과가 매번 같다.
set -e
ROOT="$(git rev-parse --show-toplevel)"
APP="$1"
UDID="${2:?시뮬레이터 UDID — 다른 작업과 겹치지 않게 전용 기기를 쓴다}"
BUNDLE=com.devkoan.StampCamera
SEED="$ROOT/docs/screenshots/seed"
OUT="$ROOT/docs/screenshots/raw/ko"
mkdir -p "$OUT"

xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

shoot() {   # <파일 이름> <장면> <기다릴 초>
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
  for s in camera location photos; do xcrun simctl privacy "$UDID" grant "$s" "$BUNDLE" 2>/dev/null || true; done
  xcrun simctl launch "$UDID" "$BUNDLE" -ScreenshotSeed "$SEED" -ScreenshotScene "$2" >/dev/null
  i=0; while [ $i -lt "$3" ]; do sleep 1; i=$((i+1)); done
  xcrun simctl io "$UDID" screenshot "$OUT/$1" >/dev/null
  echo "✓ $1 ($2)"
}

shoot 01-reveal.png   reveal   ${WAIT:-45}
shoot 02-album.png    album    ${WAIT:-45}
shoot 03-detail.png   detail   ${WAIT:-45}
shoot 04-arrange.png  arrange  ${WAIT:-45}
shoot 05-camera.png   camera   ${WAIT:-45}
shoot 06-settings.png settings ${WAIT:-45}

xcrun simctl status_bar "$UDID" clear
