#!/usr/bin/env python3
"""'쓰기' 장면 원본: 대화 화면에 펀칭으로 뜯은 스티커를 붙인 그림 → docs/screenshots/raw/<언어>/06-chat.png

시뮬레이터에서는 다른 앱(메시지)에 스티커를 붙이는 장면을 찍을 수 없어, 일반적인 대화 화면
(특정 앱을 흉내 내지 않는다)에 앱이 실제로 뜯은 스티커(docs/screenshots/seed/cut)를 얹어 그린다.
아래쪽은 펀칭 키보드의 모습(스티커 격자 + 수집함 칩)이다.

  python3 scripts/make_chat_scene.py [언어 ...]     (없으면 전부)

대화 · 칩 글은 그 언어로 따로 쓴다. 칩의 수집함 이름은 앱의 스크린샷 장면(ScreenshotScene.swift
SeedText)과 같아야 한다.
"""
import pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUT = ROOT / "docs" / "screenshots" / "seed" / "cut"
RAW = ROOT / "docs" / "screenshots" / "raw"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 440, 956          # pt — rendered at 3x → 1320×2868 (6.9" raw)

# 이름 · 대화 3줄 · 입력칸 · 칩(전체 + 수집함 두 개)
TEXT = {
    "ko": ("민지", "주말에 뭐 했어?", "우리 집 강아지랑 산책 🐾", "헐 귀여워 ㅠㅠ 나도 보낼래", "메시지", "전체", "일상 스티커", "카페 기록"),
    "en": ("Maddie", "How was your weekend?", "Walked the pup 🐾", "OMG so cute 😭 sending one", "Message", "All", "Everyday", "Café Diary"),
    "en-GB": ("Ellie", "Good weekend?", "Took the pup for a walk 🐾", "So cute 😭 sending one back", "Message", "All", "Everyday", "Café Diary"),
    "ja": ("ゆい", "週末なにしてた？", "うちの犬と散歩してた 🐾", "かわいすぎ😭 私も送る", "メッセージ", "すべて", "日常ステッカー", "カフェ日記"),
    "zh-Hans": ("小雨", "周末干嘛了？", "带我家狗狗去散步 🐾", "天哪好可爱😭 我也要发", "信息", "全部", "日常贴纸", "咖啡日记"),
    "zh-Hant": ("小雨", "週末做了什麼？", "帶我家狗狗去散步 🐾", "天啊好可愛😭 我也要傳", "訊息", "全部", "日常貼圖", "咖啡日記"),
    "ru": ("Аня", "Как выходные?", "Гуляли с собакой 🐾", "Какая милота 😭 тоже пришлю", "Сообщение", "Все", "Каждый день", "Кофейный дневник"),
    "es": ("Lucía", "¿Qué hiciste el finde?", "Paseo con mi perro 🐾", "Qué monada 😭 te mando uno", "Mensaje", "Todo", "Día a día", "Diario de cafés"),
    "de": ("Lena", "Was hast du am Wochenende gemacht?", "Mit dem Hund spazieren 🐾", "So süß 😭 ich schick auch einen", "Nachricht", "Alle", "Alltag", "Café-Tagebuch"),
    "fr": ("Léa", "Ça a été, ce week-end ?", "Balade avec mon chien 🐾", "Trop mignon 😭 j'en envoie un", "Message", "Tout", "Au quotidien", "Journal de cafés"),
    "it": ("Giulia", "Che hai fatto nel weekend?", "Passeggiata col cane 🐾", "Che tenero 😭 te ne mando uno", "Messaggio", "Tutti", "Ogni giorno", "Diario dei caffè"),
    "pt-BR": ("Bia", "Como foi o fim de semana?", "Passeei com meu cachorro 🐾", "Que fofo 😭 mando um também", "Mensagem", "Todos", "Dia a dia", "Diário de cafés"),
    "th": ("มายด์", "เสาร์อาทิตย์ทำอะไรมา", "พาน้องหมาไปเดินเล่น 🐾", "น่ารักมาก 😭 ส่งบ้างดีกว่า", "ข้อความ", "ทั้งหมด", "สติกเกอร์ทุกวัน", "บันทึกคาเฟ่"),
    "vi": ("Linh", "Cuối tuần làm gì đó?", "Dắt cún đi dạo 🐾", "Dễ thương quá 😭 gửi lại nè", "Tin nhắn", "Tất cả", "Thường ngày", "Nhật ký cà phê"),
    "cs": ("Tereza", "Co jsi dělala o víkendu?", "Procházka se psem 🐾", "Roztomilý 😭 taky jednu pošlu", "Zpráva", "Vše", "Všední dny", "Kavárenský deník"),
    "da": ("Freja", "Hvad lavede du i weekenden?", "Gåtur med hunden 🐾", "Så sød 😭 jeg sender også en", "Besked", "Alle", "Hverdag", "Café-dagbog"),
    "el": ("Μαρία", "Πώς πέρασες το Σ/Κ;", "Βόλτα με τον σκύλο 🐾", "Τι γλύκας 😭 στέλνω κι εγώ", "Μήνυμα", "Όλα", "Καθημερινά", "Ημερολόγιο καφέ"),
    "fi": ("Aino", "Mitä teit viikonloppuna?", "Lenkillä koiran kanssa 🐾", "Ihana 😭 lähetän kanssa yhden", "Viesti", "Kaikki", "Arki", "Kahvilapäiväkirja"),
    "id": ("Nadia", "Weekend ngapain aja?", "Jalan-jalan sama anjingku 🐾", "Lucu banget 😭 aku kirim juga", "Pesan", "Semua", "Sehari-hari", "Catatan Kafe"),
    "nb": ("Ingrid", "Hva gjorde du i helgen?", "Tur med hunden 🐾", "Så søt 😭 jeg sender en også", "Melding", "Alle", "Hverdag", "Kafédagbok"),
    "nl": ("Sanne", "Leuk weekend gehad?", "Wandelen met de hond 🐾", "Zo lief 😭 ik stuur er ook een", "Bericht", "Alles", "Alledaags", "Koffiedagboek"),
    "pl": ("Ola", "Co robiłaś w weekend?", "Spacer z psem 🐾", "Jaki słodki 😭 też ci wyślę", "Wiadomość", "Wszystkie", "Na co dzień", "Kawowy dziennik"),
    "sv": ("Elsa", "Vad gjorde du i helgen?", "Promenad med hunden 🐾", "Så gullig 😭 skickar en också", "Meddelande", "Alla", "Vardag", "Kafédagbok"),
    "tr": ("Elif", "Hafta sonu ne yaptın?", "Köpekle yürüyüşe çıktık 🐾", "Çok tatlı 😭 ben de göndereyim", "Mesaj", "Tümü", "Her gün", "Kahve günlüğü"),
}

def img(name):
    return (CUT / name).as_uri()

tray = ["a-02-kitten.png", "a-03-cavapoo.png", "a-04-coffee.png", "a-05-puppy.png",
        "a-06-daifuku.png", "a-07-ginger.png", "a-08-cone.png", "a-11-icecream.png"]

def render(lang):
    name, q, a, r, field, all_, chip_a, chip_b = TEXT[lang]
    html = f"""<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
html {{ width:{W*3}px; height:{H*3}px; overflow:hidden; background:#fff; }}
body {{ zoom:3; width:{W}px; height:{H}px; overflow:hidden; position:relative;
  font-family:-apple-system,"Apple SD Gothic Neo","Hiragino Sans","PingFang SC","Thonburi",sans-serif; color:#1c1c1e; }}
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
.chips {{ display:flex; gap:8px; padding:12px 14px 6px; white-space:nowrap; overflow:hidden; }}
.chip {{ padding:6px 13px; border-radius:16px; font-size:13px; font-weight:600; background:#fff; color:#555; }}
.chip.on {{ background:#2b2138; color:#fff; }}
.grid {{ display:grid; grid-template-columns:repeat(4,1fr); gap:8px; padding:8px 14px; }}
.cell {{ height:92px; background:#fff; border-radius:14px; display:flex; align-items:center; justify-content:center; }}
.cell img {{ max-width:78px; max-height:78px; }}
.input {{ position:absolute; left:14px; right:14px; bottom:330px; height:38px; border-radius:19px; border:1px solid #ddd;
  color:#aaa; font-size:16px; padding:8px 16px; }}
</style></head><body>
<div class="status"><span>9:41</span><span class="r">●●●● <span class="bat"></span></span></div>
<div class="head"><div class="av">{name[0]}</div><div class="name">{name}</div></div>
<div class="chat">
  <div class="b in">{q}</div>
  <div class="b out">{a}</div>
  <img class="stk" src="{img('a-01-corgi.png')}" style="height:178px">
  <div class="b in">{r}</div>
  <img class="stk l" src="{img('a-02-kitten.png')}" style="height:96px">
</div>
<div class="input">{field}</div>
<div class="kb">
  <div class="chips"><span class="chip on">{all_}</span><span class="chip">{chip_a}</span><span class="chip">{chip_b}</span></div>
  <div class="grid">{''.join(f'<div class="cell"><img src="{img(t)}"></div>' for t in tray)}</div>
</div>
</body></html>"""

    out = RAW / lang / "06-chat.png"
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
        f.write(html)
        page = f.name
    out.parent.mkdir(parents=True, exist_ok=True)
    # Chrome 은 다른 창과 겹치면 가끔 실패한다 — 세 번까지
    # 그림을 다 쓴 뒤 정리하다 죽기도 해서(종료 코드 ≠ 0) 파일이 새로 생겼는지로 판단한다.
    out.unlink(missing_ok=True)
    for _ in range(3):
        r = subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                            f"--user-data-dir={pathlib.Path(tempfile.gettempdir()) / ('punching-chat-' + lang)}",
                            f"--window-size={W*3},{H*3}", "--force-device-scale-factor=1", f"--screenshot={out}",
                            pathlib.Path(page).as_uri()], capture_output=True)
        if r.returncode == 0 or (out.exists() and out.stat().st_size > 0):
            break
    else:
        raise SystemExit(f"Chrome 이 그리지 못했다: {out}\n{r.stderr.decode()[-500:]}")
    print("wrote", out)


if __name__ == "__main__":
    for lang in sys.argv[1:] or list(TEXT):
        if lang not in TEXT:
            raise SystemExit(f"모르는 언어: {lang} (아는 것: {', '.join(TEXT)})")
        render(lang)
