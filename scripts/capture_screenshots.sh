#!/bin/sh
# 스토어 원본 스크린샷을 시뮬레이터에서 다시 찍는다 → docs/screenshots/raw/<언어>/
#
# 사용법:
#   SHOT_LANG=en-GB sh scripts/capture_screenshots.sh <Debug .app 경로> <시뮬레이터 UDID>
#   (SHOT_LANG 이 없으면 ko. 앱을 그 언어 · 그 지역 형식(날짜 등)으로 띄운다)
#
# 앱의 DEBUG 전용 실행 인자(StampCamera/ScreenshotScene.swift)를 쓴다:
#   -ScreenshotSeed docs/screenshots/seed   사진을 스티커로 담는다 (고르기 장면의 대상 지도는 seed/cut/backdrop-labels.png,
#                                           없으면 seed/crop/backdrop.png 를 내보낸다 → swift tools/subject_labels.swift 로 만든다)
#   -ScreenshotScene <장면>                 그 화면을 바로 연다
# 장면마다 새로 설치해 빈 상태에서 시작하므로 결과가 매번 같다.
set -e
ROOT="$(git rev-parse --show-toplevel)"
APP="$1"
UDID="${2:?시뮬레이터 UDID — 다른 작업과 겹치지 않게 전용 기기를 쓴다}"
BUNDLE=com.devkoan.StampCamera
SEED="$ROOT/docs/screenshots/seed"
SHOT_LANG="${SHOT_LANG:-ko}"
OUT="$ROOT/docs/screenshots/raw/$SHOT_LANG"
# 지역 형식: 그 언어를 쓰는 대표 나라
case "$SHOT_LANG" in
  ko) REGION=ko_KR ;; en) REGION=en_US ;; en-GB) REGION=en_GB ;; ja) REGION=ja_JP ;;
  zh-Hans) REGION=zh_CN ;; zh-Hant) REGION=zh_TW ;; pt-BR) REGION=pt_BR ;; cs) REGION=cs_CZ ;;
  da) REGION=da_DK ;; el) REGION=el_GR ;; nb) REGION=nb_NO ;; sv) REGION=sv_SE ;; vi) REGION=vi_VN ;;
  *) REGION="$(echo "$SHOT_LANG" | tr a-z A-Z | sed "s/^\(..\)$/$SHOT_LANG""_\1/")" ;;
esac
mkdir -p "$OUT"

xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

shoot() {   # <파일 이름> <장면> <기다릴 초>
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
  for s in camera photos; do xcrun simctl privacy "$UDID" grant "$s" "$BUNDLE" 2>/dev/null || true; done
  xcrun simctl launch "$UDID" "$BUNDLE" -ScreenshotSeed "$SEED" -ScreenshotScene "$2" \
    -AppleLanguages "($SHOT_LANG)" -AppleLocale "$REGION" >/dev/null
  i=0; while [ $i -lt "$3" ]; do sleep 1; i=$((i+1)); done
  xcrun simctl io "$UDID" screenshot "$OUT/$1" >/dev/null
  echo "✓ $1 ($2)"
}

shoot 01-pick.png    pick     ${WAIT:-25}
shoot 02-album.png   album    ${WAIT:-25}
# 상세는 시드에 움직임이 없어 "움직임을 담지 못했어요" 가 보여 뺐다
shoot 07-tags.png    tags     ${WAIT:-25}
shoot 08-map.png     map      ${WAIT:-30}
[ "${SETTINGS:-0}" = 1 ] && shoot 06-settings.png settings ${WAIT:-25}

xcrun simctl status_bar "$UDID" clear
