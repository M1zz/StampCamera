#!/usr/bin/env python3
"""'쓰기' 장면 원본: 대화 화면에 펀칭으로 뜯은 스티커를 붙인 그림 → docs/screenshots/raw/ko/06-chat.png

시뮬레이터에서는 다른 앱(메시지)에 스티커를 붙이는 장면을 찍을 수 없어, 일반적인 대화 화면
(특정 앱을 흉내 내지 않는다)에 앱이 실제로 뜯은 스티커(docs/screenshots/seed/cut)를 얹어 그린다.
아래쪽은 펀칭 키보드의 모습(스티커 격자 + 수집함 칩)이다.

  python3 scripts/make_chat_scene.py
"""
import pathlib, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUT = ROOT / "docs" / "screenshots" / "seed" / "cut"
OUT = ROOT / "docs" / "screenshots" / "raw" / "ko" / "06-chat.png"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 440, 956          # pt — rendered at 3x → 1320×2868 (6.9" raw)

def img(name):
    return (CUT / name).as_uri()

tray = ["a-02-kitten.png", "a-03-cavapoo.png", "a-04-coffee.png", "a-05-puppy.png",
        "a-06-daifuku.png", "a-07-ginger.png", "a-08-cone.png", "a-11-icecream.png"]

html = f"""<!doctype html><html><head><meta charset="utf-8"><style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
html {{ width:{W*3}px; height:{H*3}px; overflow:hidden; background:#fff; }}
body {{ zoom:3; width:{W}px; height:{H}px; overflow:hidden; position:relative;
  font-family:-apple-system,"Apple SD Gothic Neo",sans-serif; color:#1c1c1e; }}
.status {{ height:54px; display:flex; align-items:flex-end; justify-content:space-between; padding:0 34px 8px 50px;
  font-weight:600; font-size:17px; }}
.status .r {{ display:flex; gap:7px; align-items:center; font-size:13px; }}
.bat {{ width:27px; height:13px; border-radius:4px; background:#34c759; }}
.head {{ display:flex; flex-direction:column; align-items:center; gap:4px; padding:10px 0 12px;
  border-bottom:1px solid #eee; }}
.av {{ width:52px; height:52px; border-radius:50%; background:linear-gradient(135deg,#FFD65C,#FF7A59);
  display:flex; align-items:center; justify-content:center; color:#fff; font-weight:800; font-size:22px; }}
.name {{ font-size:13px; color:#555; }}
.chat {{ padding:14px 16px 0; display:flex; flex-direction:column; gap:8px; }}
.b {{ max-width:70%; padding:9px 14px; border-radius:20px; font-size:17px; line-height:1.3; }}
.in {{ align-self:flex-start; background:#ececf0; }}
.out {{ align-self:flex-end; background:#2b2138; color:#fff; }}
.stk {{ align-self:flex-end; margin:-2px 6px 0 0; transform:rotate(6deg);
  filter:drop-shadow(0 6px 10px rgba(0,0,0,.18)); }}
.stk.l {{ align-self:flex-start; transform:rotate(-7deg); margin-left:10px; }}
.kb {{ position:absolute; left:0; right:0; bottom:0; height:318px; background:#f2f0ed; border-top:1px solid #e2ded8; }}
.chips {{ display:flex; gap:8px; padding:12px 14px 6px; }}
.chip {{ padding:6px 13px; border-radius:16px; font-size:13px; font-weight:600; background:#fff; color:#555; }}
.chip.on {{ background:#2b2138; color:#fff; }}
.grid {{ display:grid; grid-template-columns:repeat(4,1fr); gap:8px; padding:8px 14px; }}
.cell {{ height:92px; background:#fff; border-radius:14px; display:flex; align-items:center; justify-content:center; }}
.cell img {{ max-width:78px; max-height:78px; }}
.input {{ position:absolute; left:14px; right:14px; bottom:330px; height:38px; border-radius:19px; border:1px solid #ddd;
  color:#aaa; font-size:16px; padding:8px 16px; }}
</style></head><body>
<div class="status"><span>9:41</span><span class="r">●●●● <span class="bat"></span></span></div>
<div class="head"><div class="av">민</div><div class="name">민지</div></div>
<div class="chat">
  <div class="b in">주말에 뭐 했어?</div>
  <div class="b out">우리 집 강아지랑 산책 🐾</div>
  <img class="stk" src="{img('a-01-corgi.png')}" style="height:178px">
  <div class="b in">헐 귀여워 ㅠㅠ 나도 보낼래</div>
  <img class="stk l" src="{img('a-02-kitten.png')}" style="height:96px">
</div>
<div class="input">메시지</div>
<div class="kb">
  <div class="chips"><span class="chip on">전체</span><span class="chip">일상 스티커</span><span class="chip">카페 기록</span></div>
  <div class="grid">{''.join(f'<div class="cell"><img src="{img(t)}"></div>' for t in tray)}</div>
</div>
</body></html>"""

with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
    f.write(html)
    page = f.name
OUT.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                f"--window-size={W*3},{H*3}", "--force-device-scale-factor=1", f"--screenshot={OUT}",
                pathlib.Path(page).as_uri()], check=True, capture_output=True)
print("wrote", OUT)
