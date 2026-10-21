#!/usr/bin/env python3
"""마케팅 스크린샷 목업 생성: HTML 생성 → 헤드리스 Chrome 렌더링.

슬라이드마다 layout 이 달라 배치가 다양함:
  hero-bleed  : 헤드라인 상단 중앙 + 정면 대형 폰, 하단 블리드
  left-text   : 좌측 정렬 텍스트 + 오른쪽으로 기운 폰
  text-bottom : 폰 상단 + 텍스트 하단
  flat-rotate : 평면 회전(-5°) 폰, 하단 블리드
  dark        : 다크 배경 반전 + 정면 폰
"""
import subprocess, sys, pathlib

# 펀칭 — 원본: docs/screenshots/raw/ko (펀칭 전용 iPhone 18 Pro Max 시뮬레이터 1320x2868)
# 01~05 는 scripts/capture_screenshots.sh(앱의 DEBUG 스크린샷 장면)로, 06-chat 은
# scripts/make_chat_scene.py 로 만든다. 바탕·글자색은 앱 아이콘(노랑→주황, 남색 렌즈)에서 왔다.
import tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "screenshots" / "raw" / "ko"
OUT = ROOT / "docs" / "screenshots" / "marketing" / "ko"
WORK = pathlib.Path(tempfile.gettempdir())
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1242, 2688   # 이 계정의 iPhone 제출 규격

SHOTS = [
    ("01-reveal.png",  "hero-bleed",  "꾹 누르면<br>움직이는 스티커", "찍는 순간 대상만 쏙 오려 내요"),
    ("06-chat.png",    "left-text",   "대화에<br>바로 붙여요", "메시지와 키보드에서 꺼내 써요"),
    ("02-album.png",   "text-bottom", "수집함마다<br>나만의 스티커 팩", "모은 스티커가 묶음으로 따라와요"),
    ("03-detail.png",  "flat-rotate", "오려낸 모양도<br>우표 모양도", "뜯은 뒤에도 모양과 색감을 바꿔요"),
    ("04-arrange.png", "left-text",   "속지 고르고<br>순서도 마음대로", "크라프트, 모눈, 양피지 속지 10가지"),
    ("05-camera.png",  "dark",        "펀칭기로<br>꾹 눌러 뜯어요", "창 안에 보이는 순간 그대로"),
]

BASE_CSS = f"""
* {{ margin:0; padding:0; box-sizing:border-box; }}
html,body {{ width:{W}px; height:{H}px; overflow:hidden; }}
body {{ background:linear-gradient(180deg,#FFF6E8 0%,#FFE6CF 100%); font-family:-apple-system, "Apple SD Gothic Neo", sans-serif; position:relative; }}
.headline {{ font-size:100px; font-weight:800; color:#2B2138; letter-spacing:-2px; line-height:1.2; word-break:keep-all; }}
.sub {{ font-size:52px; font-weight:500; color:#9A7B66; letter-spacing:-1px; word-break:keep-all; }}
.phone {{ background:#17171a; border-radius:116px; border:3px solid #3a3a3e; padding:25px;
  box-shadow: 60px 90px 120px rgba(0,0,0,.28), 20px 30px 50px rgba(0,0,0,.18); }}
.phone img {{ width:100%; display:block; border-radius:92px; }}
"""

LAYOUTS = {
    # 1) 정면 대형, 하단 블리드
    "hero-bleed": """
.headline { text-align:center; margin-top:290px; padding:0 70px; }
.sub { text-align:center; margin-top:52px; }
.wrap { display:flex; justify-content:center; margin-top:150px; }
.phone { width:1000px; }
""",
    # 2) 좌측 정렬 텍스트 + 오른쪽 기울기, 오른쪽 블리드
    "left-text": """
.headline { text-align:left; margin:300px 0 0 110px; }
.sub { text-align:left; margin:48px 0 0 114px; }
.wrap { perspective:2600px; perspective-origin:30% 30%; position:absolute; left:300px; top:990px; }
.phone { width:840px; transform:rotateY(16deg) rotateX(2deg); }
""",
    # 3) 폰 상단, 텍스트 하단
    "text-bottom": """
.wrap { perspective:2800px; perspective-origin:50% 40%; display:flex; justify-content:center; margin-top:170px; }
.phone { width:880px; transform:rotateY(-10deg) rotateX(2deg); }
.headline { text-align:center; margin-top:120px; padding:0 70px; }
.sub { text-align:center; margin-top:48px; }
""",
    # 4) 평면 회전, 좌측 치우침 + 하단 블리드
    "flat-rotate": """
.headline { text-align:center; margin-top:270px; padding:0 70px; }
.sub { text-align:center; margin-top:52px; }
.wrap { position:absolute; left:120px; top:1010px; }
.phone { width:1010px; transform:rotate(-6deg); }
""",
    # 5) 다크 배경 반전 + 정면
    "dark": """
body { background:linear-gradient(180deg,#2B2138 0%,#1A1424 100%); }
.headline { color:#f5f5f7; text-align:center; margin-top:290px; padding:0 70px; }
.sub { color:#C9A98F; text-align:center; margin-top:52px; }
.wrap { display:flex; justify-content:center; margin-top:150px; }
.phone { width:930px; border-color:#48484e;
  box-shadow: 0 0 160px rgba(255,150,80,.28), 40px 70px 110px rgba(0,0,0,.55); }
""",
}

# text-bottom 은 폰이 먼저 오는 DOM 순서
BODY_TEXT_FIRST = '<div class="headline">{headline}</div><div class="sub">{sub}</div><div class="wrap"><div class="phone"><img src="{img}"></div></div>'
BODY_PHONE_FIRST = '<div class="wrap"><div class="phone"><img src="{img}"></div></div><div class="headline">{headline}</div><div class="sub">{sub}</div>'

HTML = """<!doctype html><html><head><meta charset="utf-8"><style>
{base}{layout}
</style></head><body>{body}</body></html>"""

def main(only=None):
    OUT.mkdir(parents=True, exist_ok=True)
    for n, (fname, layout, headline, sub) in enumerate(SHOTS, 1):
        if only and fname != only:
            continue
        body_tpl = BODY_PHONE_FIRST if layout == "text-bottom" else BODY_TEXT_FIRST
        body = body_tpl.format(headline=headline, sub=sub, img=(SRC / fname).as_uri())
        html_path = WORK / (fname.replace(".png", ".html"))
        html_path.write_text(HTML.format(base=BASE_CSS, layout=LAYOUTS[layout], body=body), encoding="utf-8")
        # 파일 이름 순서 = 스토어 순서 → 원본 이름이 아니라 슬라이드 순서로 번호를 붙인다
        out_png = OUT / f"{n:02d}-{fname.split('-', 1)[1]}"
        # Chrome 은 다른 창과 겹치면 가끔 실패한다 — 따로 쓰는 프로필로 세 번까지
        for _ in range(3):
            try:
                r = subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                                    f"--window-size={W},{H}", "--force-device-scale-factor=1",
                                    "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=3000",
                                    "--allow-file-access-from-files", html_path.as_uri()],
                                   capture_output=True, timeout=120)
            except subprocess.TimeoutExpired:
                continue
            if r.returncode == 0:
                break
        else:
            raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
        print(f"rendered {out_png}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
