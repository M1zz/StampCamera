#!/bin/sh
# 구독 약관 게이트 — 심사 지침 3.1.2(c) 로 다시 반려되지 않게 배포 전에 잡는다.
#
# 1.0.5 (13) 반려 사유: "앱 안에 눌리는 이용약관(EULA) 링크가 없다".
# 링크는 페이월 맨 아래에만 있어 스크롤해야 보였고, 설정에는 없었다.
#
# 검사하는 것
#   1. 살 수 있는 화면(페이월 · 평생 전환 판 · StoreKit 뷰)마다 약관 링크가 붙어 있는가
#   2. 설정의 요금제 구역에 약관 링크가 있는가
#   3. 스토어 설명(APPSTORE.md)의 모든 언어에 EULA · 개인정보처리방침 주소가 있는가
#   4. 그 주소들이 실제로 열리는가
#
# 사용법: sh scripts/check_subscription_legal.sh   (predeploy.sh 가 부른다)
set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
APP="StampCamera"
fail=0
bad() { echo "❌ $1"; fail=1; }

# 1. 살 수 있는 화면마다 약관 링크
for f in $(grep -rlE 'LeeoGraduationOfferView\(|struct PaywallView|SubscriptionStoreView\(|StoreView\(|ProductView\(' "$APP" --include='*.swift'); do
  sells=$(grep -cE 'LeeoGraduationOfferView\(|struct PaywallView|SubscriptionStoreView\(|StoreView\(|ProductView\(' "$f")
  links=$(grep -cE '\.subscriptionLegalBar\(|SubscriptionLegalLinks\(' "$f")
  if [ "$links" -lt "$sells" ]; then
    bad "$f: 살 수 있는 화면 ${sells}곳 중 약관 링크는 ${links}곳 — 화면마다 .subscriptionLegalBar() 를 붙이세요"
  fi
done

# 2. 설정의 요금제 구역
grep -q 'SubscriptionLegalLinks(style: .rows)' "$APP/StampCameraSupportView.swift" \
  || bad "설정(StampCameraSupportView)에 SubscriptionLegalLinks(style: .rows) 가 없습니다"

# 링크 뷰가 진짜 Link 로 두 주소를 여는지
for want in 'Link(destination: SubscriptionLegal.termsURL)' 'Link(destination: SubscriptionLegal.privacyURL)'; do
  grep -qF "$want" "$APP/SubscriptionLegalLinks.swift" || bad "SubscriptionLegalLinks.swift 에 '$want' 가 없습니다"
done

# 3. 스토어 설명 — 언어마다 EULA · 개인정보처리방침 주소
EULA="$(sed -n 's/.*standardEULA = URL(string: "\([^"]*\)").*/\1/p' "$APP/SubscriptionLegalLinks.swift")"
[ -n "$EULA" ] || bad "SubscriptionLegalLinks.swift 에서 표준 EULA 주소를 읽지 못했습니다"
python3 - "$EULA" <<'PY' || fail=1
import re, sys
eula = sys.argv[1]
text = open("APPSTORE.md", encoding="utf-8").read()
sections = re.split(r"^## ", text, flags=re.M)[1:]
ok = True
checked = 0
for s in sections:
    locale = s.split("\n", 1)[0].strip()
    if "### 설명" not in s:      # 언어 구역이 아닌 절(손쉬운 사용 등)
        continue
    checked += 1
    desc = s.split("### 설명", 1)[1]
    if eula not in desc:
        print(f"❌ APPSTORE.md [{locale}] 설명에 이용약관(EULA) 주소가 없습니다"); ok = False
    if "privacy.html" not in desc:
        print(f"❌ APPSTORE.md [{locale}] 설명에 개인정보처리방침 주소가 없습니다"); ok = False
if not checked:
    print("❌ APPSTORE.md 에 설명이 있는 언어 구역이 없습니다"); ok = False
sys.exit(0 if ok else 1)
PY

# 4. 주소가 실제로 열리는가 (심사는 '눌리는' 링크를 본다)
PRIVACY="$(sed -n 's/.*privacyURL: URL(string: "\([^"]*\)").*/\1/p' "$APP/StampCameraSpec.swift")"
for url in "$EULA" "$PRIVACY"; do
  [ -n "$url" ] || continue
  code="$(curl -sL -o /dev/null -m 20 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  case "$code" in
    200) ;;
    000) echo "⚠️  $url — 연결하지 못해 확인을 건너뜁니다" ;;
    *)   bad "$url 이 열리지 않습니다 (HTTP $code)" ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "구독 약관 게이트 실패 — 심사 지침 3.1.2(c). 위 항목을 고친 뒤 다시 배포하세요."
  exit 1
fi
echo "✅ 구독 약관 게이트 통과 — 살 수 있는 화면 · 설정 · 스토어 설명에 이용약관(EULA) · 개인정보처리방침"
