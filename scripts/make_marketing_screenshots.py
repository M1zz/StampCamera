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

# 펀칭 — 원본: docs/screenshots/raw/<언어> (펀칭 전용 iPhone 18 Pro Max 시뮬레이터 1320x2868)
# 01~05 는 scripts/capture_screenshots.sh(앱의 DEBUG 스크린샷 장면, SHOT_LANG=<언어>)로, 06-chat 은
# scripts/make_chat_scene.py <언어> 로 만든다. 바탕·글자색은 앱 아이콘(노랑→주황, 남색 렌즈)에서 왔다.
#
# 사용법: python3 scripts/make_marketing_screenshots.py [언어 ...]   (없으면 전부)
#         → docs/screenshots/marketing/<언어>/
import tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw"
MARKETING = ROOT / "docs" / "screenshots" / "marketing"
WORK = pathlib.Path(tempfile.gettempdir())
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1242, 2688   # 이 계정의 iPhone 제출 규격

# 슬라이드 순서 = 스토어 순서. 1장은 make_creative_assets.py 의 검색 결과와 같은 이야기다.
SLIDES = [
    ("01-reveal.png",  "hero-bleed"),
    ("06-chat.png",    "left-text"),
    ("02-album.png",   "text-bottom"),
    ("03-detail.png",  "flat-rotate"),
    ("04-arrange.png", "left-text"),
    ("05-camera.png",  "dark"),
]

# ⚠️ 기계번역하지 않는다. 앱 화면의 낱말(수집함=Books/ブック/收藏册…, 뜯기, 색감)과 맞춘다.
COPY = {
    "ko": [
        ("꾹 누르면<br>움직이는 스티커", "찍는 순간 대상만 쏙 오려 내요"),
        ("대화에<br>바로 붙여요", "메시지와 키보드에서 꺼내 써요"),
        ("수집함마다<br>나만의 스티커 팩", "모은 스티커가 묶음으로 따라와요"),
        ("오려낸 모양도<br>우표 모양도", "뜯은 뒤에도 모양과 색감을 바꿔요"),
        ("속지 고르고<br>순서도 마음대로", "크라프트, 모눈, 양피지 속지 10가지"),
        ("펀칭기로<br>꾹 눌러 뜯어요", "창 안에 보이는 순간 그대로"),
    ],
    "en": [
        ("Hold for a<br>moving sticker", "Cuts out just your subject as you shoot"),
        ("Stick it right<br>in your chats", "Grab it from Messages or the keyboard"),
        ("Every book is<br>a sticker pack", "Your stickers travel as a set"),
        ("Cut-out<br>or stamp", "Change the shape and look anytime"),
        ("Pick the paper,<br>set the order", "10 papers, from kraft to parchment"),
        ("Hold the punch<br>to tear it off", "Exactly what's in the window"),
    ],
    "en-GB": [
        ("Press and hold for<br>a moving sticker", "Cuts out just your subject as you shoot"),
        ("Pop it straight<br>into your chats", "Grab it from Messages or the keyboard"),
        ("Every book is<br>a sticker pack", "Your stickers travel as a set"),
        ("Cut-out<br>or stamp", "Change the shape and colour any time"),
        ("Pick the paper,<br>sort the order", "10 papers, from kraft to parchment"),
        ("Hold the punch<br>to tear it off", "Exactly what's in the window"),
    ],
    "ja": [
        ("長押しで<br>動くステッカーに", "撮った瞬間、被写体だけを切り抜き"),
        ("トークに<br>そのまま貼れる", "メッセージとキーボードから使える"),
        ("ブックごとに<br>自分だけのパック", "集めたステッカーがセットで使える"),
        ("切り抜きも<br>切手の形も", "はがした後も形と色合いを変えられる"),
        ("台紙を選んで<br>並びも自由に", "クラフト、方眼、羊皮紙など10種類"),
        ("パンチャーを<br>長押ししてはがす", "窓に映った瞬間をそのまま"),
    ],
    "zh-Hans": [
        ("长按一下<br>变成会动的贴纸", "拍下的瞬间，主体一键抠出"),
        ("直接贴进<br>聊天里", "在信息和键盘里随手取用"),
        ("每本收藏册<br>都是专属贴纸包", "收集的贴纸整套跟着走"),
        ("抠图也行<br>邮票也行", "撕下后还能换形状和色调"),
        ("挑选内页<br>顺序随心排", "牛皮纸、方格、羊皮纸等10种内页"),
        ("对准打孔窗<br>长按撕下", "窗里看到的瞬间原样保留"),
    ],
    "zh-Hant": [
        ("長按一下<br>變成會動的貼圖", "拍下的瞬間，主體一鍵去背"),
        ("直接貼進<br>聊天裡", "在訊息和鍵盤裡隨手取用"),
        ("每本收藏冊<br>都是專屬貼圖包", "收集的貼圖整組帶著走"),
        ("去背也行<br>郵票也行", "撕下後還能換形狀和色調"),
        ("挑選內頁<br>順序隨心排", "牛皮紙、方格、羊皮紙等10種內頁"),
        ("對準打孔窗<br>長按撕下", "窗裡看到的瞬間原樣保留"),
    ],
    "ru": [
        ("Удерживайте —<br>и стикер оживёт", "Камера сама вырежет главное в кадре"),
        ("Сразу<br>в переписку", "Берите из Сообщений и с клавиатуры"),
        ("Каждый альбом —<br>свой стикерпак", "Собранные стикеры всегда под рукой"),
        ("Вырезанный<br>или марка", "Форму и стиль можно сменить потом"),
        ("Выберите бумагу<br>и порядок", "Крафт, клетка, пергамент — 10 видов"),
        ("Удерживайте —<br>и кадр оторван", "Ровно то, что видно в окошке"),
    ],
    "es": [
        ("Mantén pulsado:<br>sticker animado", "Recorta solo lo importante al instante"),
        ("Pégalo directo<br>en tus chats", "Desde Mensajes o el teclado"),
        ("Cada álbum es<br>un pack de stickers", "Tus stickers van juntos a todas partes"),
        ("Recortado<br>o sello", "Cambia la forma y el tono cuando quieras"),
        ("Elige el papel<br>y el orden", "10 papeles: kraft, cuadrícula, pergamino…"),
        ("Mantén pulsado<br>y arráncalo", "Justo lo que se ve en la ventana"),
    ],
    "de": [
        ("Gedrückt halten:<br>bewegter Sticker", "Dein Motiv wird sofort freigestellt"),
        ("Direkt<br>in den Chat", "Aus Nachrichten oder der Tastatur"),
        ("Jede Sammlung<br>ein Sticker-Pack", "Deine Sticker bleiben zusammen"),
        ("Ausgeschnitten<br>oder Briefmarke", "Form und Look jederzeit änderbar"),
        ("Papier wählen,<br>Reihenfolge frei", "10 Papiere, von Kraft bis Pergament"),
        ("Gedrückt halten<br>und abtrennen", "Genau das, was im Fenster ist"),
    ],
    "fr": [
        ("Appui long :<br>autocollant animé", "Votre sujet est détouré dès la prise"),
        ("Collez-le direct<br>dans vos chats", "Depuis Messages ou le clavier"),
        ("Chaque classeur,<br>un pack à vous", "Vos autocollants restent ensemble"),
        ("Détouré<br>ou timbre", "Forme et rendu modifiables à tout moment"),
        ("Choisissez le papier<br>et l'ordre", "10 papiers, du kraft au parchemin"),
        ("Appuyez longuement<br>pour détacher", "Exactement ce qu'on voit dans la fenêtre"),
    ],
    "it": [
        ("Tieni premuto:<br>adesivo animato", "Ritaglia solo il soggetto mentre scatti"),
        ("Incollalo subito<br>in chat", "Da Messaggi o dalla tastiera"),
        ("Ogni album è<br>un pacchetto tuo", "I tuoi adesivi sempre insieme"),
        ("Ritagliato<br>o francobollo", "Cambia forma e stile quando vuoi"),
        ("Scegli la carta<br>e l'ordine", "10 carte, dalla kraft alla pergamena"),
        ("Tieni premuto<br>e stacca", "Proprio ciò che vedi nella finestra"),
    ],
    "pt-BR": [
        ("Segure e pronto:<br>adesivo animado", "Recorta só o que importa na hora"),
        ("Cole direto<br>na conversa", "Pelo Mensagens ou pelo teclado"),
        ("Cada álbum é<br>um pacote seu", "Seus adesivos sempre juntos"),
        ("Recortado<br>ou selo", "Mude a forma e o estilo quando quiser"),
        ("Escolha o papel<br>e a ordem", "10 papéis, do kraft ao pergaminho"),
        ("Segure para<br>destacar", "Exatamente o que aparece na janela"),
    ],
    "th": [
        ("กดค้างไว้<br>ได้สติกเกอร์ขยับได้", "ตัดเฉพาะตัวแบบออกมาทันทีที่ถ่าย"),
        ("แปะลงแชต<br>ได้ทันที", "หยิบใช้จากข้อความและคีย์บอร์ด"),
        ("ทุกอัลบั้ม<br>คือแพ็กของคุณ", "สติกเกอร์ที่สะสมไว้มาเป็นชุด"),
        ("ตัดขอบ<br>หรือแสตมป์", "เปลี่ยนรูปทรงและโทนภาพได้ทีหลัง"),
        ("เลือกกระดาษ<br>เรียงลำดับเอง", "คราฟต์ ตาราง กระดาษหนัง 10 แบบ"),
        ("กดค้าง<br>แล้วฉีกออกมา", "ได้ภาพตามที่เห็นในช่องหน้าต่าง"),
    ],
    "vi": [
        ("Nhấn giữ là có<br>nhãn dán động", "Tự tách chủ thể ngay khi chụp"),
        ("Dán ngay<br>vào trò chuyện", "Lấy từ Tin nhắn hoặc bàn phím"),
        ("Mỗi bộ sưu tập<br>là một gói riêng", "Nhãn dán đi cùng nhau thành bộ"),
        ("Cắt viền<br>hay hình tem", "Đổi hình dáng và màu ảnh bất cứ lúc nào"),
        ("Chọn giấy nền<br>xếp tùy thích", "10 loại giấy: kraft, ô vuông, giấy da…"),
        ("Nhấn giữ<br>để bấm ra", "Đúng khoảnh khắc trong khung"),
    ],
    "cs": [
        ("Podrž a máš<br>pohyblivou nálepku", "Vystřihne jen to hlavní hned při focení"),
        ("Rovnou<br>do chatu", "Ze Zpráv nebo z klávesnice"),
        ("Každé album<br>je tvůj balíček", "Nálepky máš vždy pohromadě"),
        ("Vystřižená<br>nebo známka", "Tvar i styl změníš kdykoli"),
        ("Vyber papír<br>a pořadí", "10 papírů, od kraftu po pergamen"),
        ("Podrž<br>a odtrhni", "Přesně to, co je v okénku"),
    ],
    "da": [
        ("Hold nede for et<br>bevægeligt mærke", "Klipper motivet fri, mens du fotograferer"),
        ("Lige ind<br>i chatten", "Fra Beskeder eller tastaturet"),
        ("Hvert album er<br>din egen pakke", "Dine mærker følges ad"),
        ("Udskåret<br>eller frimærke", "Skift form og look når som helst"),
        ("Vælg papir<br>og rækkefølge", "10 papirer, fra kraft til pergament"),
        ("Hold nede<br>og riv af", "Præcis det, der er i vinduet"),
    ],
    "el": [
        ("Κράτησέ το<br>και ζωντανεύει", "Κόβει το θέμα με τη λήψη"),
        ("Κατευθείαν<br>στη συζήτηση", "Από τα Μηνύματα ή το πληκτρολόγιο"),
        ("Κάθε άλμπουμ<br>δικό σου πακέτο", "Τα αυτοκόλλητά σου μένουν μαζί"),
        ("Με περίγραμμα<br>ή γραμματόσημο", "Άλλαξε σχήμα και ύφος όποτε θες"),
        ("Διάλεξε χαρτί<br>και σειρά", "10 χαρτιά, από κραφτ ως περγαμηνή"),
        ("Κράτα πατημένο<br>και απόσπασε", "Ακριβώς ό,τι φαίνεται στο παράθυρο"),
    ],
    "fi": [
        ("Pidä painettuna:<br>liikkuva tarra", "Rajaa kohteen irti heti kuvatessa"),
        ("Suoraan<br>keskusteluun", "Viesteistä tai näppäimistöltä"),
        ("Jokainen albumi<br>on oma pakkaus", "Tarrasi pysyvät yhdessä"),
        ("Rajattu<br>tai postimerkki", "Vaihda muotoa ja ilmettä milloin vain"),
        ("Valitse paperi<br>ja järjestys", "10 paperia kraftista pergamenttiin"),
        ("Pidä painettuna<br>ja irrota", "Juuri se, mikä näkyy ikkunassa"),
    ],
    "id": [
        ("Tahan untuk bikin<br>stiker bergerak", "Langsung memotong objek saat memotret"),
        ("Tempel langsung<br>di obrolan", "Ambil dari Pesan atau papan ketik"),
        ("Tiap album jadi<br>paket stikermu", "Stikermu selalu terkumpul rapi"),
        ("Potongan<br>atau perangko", "Ganti bentuk dan gaya kapan saja"),
        ("Pilih kertas,<br>atur urutan", "10 kertas, dari kraft sampai perkamen"),
        ("Tahan lalu<br>sobek", "Persis seperti yang ada di jendela"),
    ],
    "nb": [
        ("Hold inne for<br>levende merker", "Klipper ut motivet idet du tar bildet"),
        ("Rett inn<br>i chatten", "Fra Meldinger eller tastaturet"),
        ("Hvert album er<br>din egen pakke", "Merkene dine holder sammen"),
        ("Utklippet<br>eller frimerke", "Bytt form og uttrykk når du vil"),
        ("Velg papir<br>og rekkefølge", "10 papirer, fra kraft til pergament"),
        ("Hold inne<br>og riv av", "Akkurat det som er i vinduet"),
    ],
    "nl": [
        ("Houd vast:<br>bewegende sticker", "Knipt je onderwerp meteen uit"),
        ("Zo in<br>je chat", "Vanuit Berichten of het toetsenbord"),
        ("Elke verzameling<br>een stickerpakket", "Je stickers blijven bij elkaar"),
        ("Uitgeknipt<br>of postzegel", "Wissel vorm en look wanneer je wilt"),
        ("Kies papier<br>en volgorde", "10 papiersoorten, van kraft tot perkament"),
        ("Houd ingedrukt<br>en scheur af", "Precies wat er in het venster staat"),
    ],
    "pl": [
        ("Przytrzymaj,<br>a naklejka ożyje", "Wycina sam obiekt już przy zdjęciu"),
        ("Prosto<br>do czatu", "Z Wiadomości lub z klawiatury"),
        ("Każdy album<br>to twój zestaw", "Naklejki trzymają się razem"),
        ("Wycięta<br>albo znaczek", "Zmieniaj kształt i styl, kiedy chcesz"),
        ("Wybierz papier<br>i kolejność", "10 papierów, od kraftu po pergamin"),
        ("Przytrzymaj<br>i oderwij", "Dokładnie to, co widać w okienku"),
    ],
    "sv": [
        ("Håll inne för<br>rörliga märken", "Klipper ut motivet direkt när du fotar"),
        ("Rakt in<br>i chatten", "Från Meddelanden eller tangentbordet"),
        ("Varje album är<br>ditt eget paket", "Märkena håller ihop"),
        ("Urklippt<br>eller frimärke", "Byt form och look när du vill"),
        ("Välj papper<br>och ordning", "10 papper, från kraft till pergament"),
        ("Håll inne<br>och riv loss", "Precis det som syns i fönstret"),
    ],
    "tr": [
        ("Basılı tut,<br>hareketli çıkartma", "Çektiğin an konuyu kesip çıkarır"),
        ("Doğrudan<br>sohbete", "Mesajlar'dan ya da klavyeden"),
        ("Her koleksiyon<br>kendi paketin", "Çıkartmaların hep bir arada"),
        ("Kesilmiş<br>ya da pul", "Şekli ve görünümü dilediğinde değiştir"),
        ("Kâğıdı seç,<br>sırayı belirle", "Kraft, kareli, parşömen: 10 kâğıt"),
        ("Basılı tut<br>ve kopar", "Pencerede ne görünüyorsa o"),
    ],
}

BASE_CSS = f"""
* {{ margin:0; padding:0; box-sizing:border-box; }}
html,body {{ width:{W}px; height:{H}px; overflow:hidden; }}
body {{ background:linear-gradient(180deg,#FFF6E8 0%,#FFE6CF 100%); font-family:-apple-system, "SF Pro Display", "Apple SD Gothic Neo", "Hiragino Sans", "PingFang SC", "Thonburi", sans-serif; position:relative; }}
:lang(ja) .headline, :lang(zh) .headline, :lang(th) .headline, :lang(th) .sub {{ letter-spacing:0; }}
:lang(th) .headline {{ line-height:1.35; }}
.headline {{ font-size:100px; font-weight:800; color:#2B2138; letter-spacing:-2px; line-height:1.2; word-break:keep-all; }}
.sub {{ font-size:52px; font-weight:500; color:#9A7B66; letter-spacing:-1px; word-break:keep-all; line-height:1.3; }}
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

# 글이 적은 줄(<br>)보다 더 쪼개지거나 화면 밖으로 나가면 글자를 줄인다.
FIT_JS = """<script>
function fit(el, max, min, lines) {
  let size = max;
  const avail = document.body.clientWidth - 140;
  for (;;) {
    el.style.fontSize = size + 'px';
    const h = el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight);
    if ((Math.round(h) <= lines && el.scrollWidth <= avail) || size <= min) break;
    size -= 2;
  }
}
const hl = document.querySelector('.headline');
fit(hl, 100, 60, hl.querySelectorAll('br').length + 1);
fit(document.querySelector('.sub'), 52, 34, 1);
</script>"""

HTML = """<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>
{base}{layout}
.headline, .sub {{ max-width:calc(100% - 140px); }}
</style></head><body>{body}{fit}</body></html>"""

def render(lang):
    src = RAW / lang
    out = MARKETING / lang
    out.mkdir(parents=True, exist_ok=True)
    for n, ((fname, layout), (headline, sub)) in enumerate(zip(SLIDES, COPY[lang]), 1):
        body_tpl = BODY_PHONE_FIRST if layout == "text-bottom" else BODY_TEXT_FIRST
        body = body_tpl.format(headline=headline, sub=sub, img=(src / fname).as_uri())
        html_path = WORK / f"punching-mkt-{lang}-{fname.replace('.png', '.html')}"
        html_path.write_text(HTML.format(lang=lang, base=BASE_CSS, layout=LAYOUTS[layout], body=body, fit=FIT_JS),
                             encoding="utf-8")
        # 파일 이름 순서 = 스토어 순서 → 원본 이름이 아니라 슬라이드 순서로 번호를 붙인다
        out_png = out / f"{n:02d}-{fname.split('-', 1)[1]}"
        # Chrome 은 다른 창과 겹치면 가끔 실패한다 — 따로 쓰는 프로필로 다섯 번까지
        # 그림을 다 쓴 뒤 정리하다 죽기도 해서(종료 코드 ≠ 0) 파일이 새로 생겼는지로 판단한다.
        out_png.unlink(missing_ok=True)
        for _ in range(5):
            try:
                r = subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                                    f"--window-size={W},{H}", "--force-device-scale-factor=1",
                                    "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=3000",
                                    f"--user-data-dir={WORK / ('punching-chrome-' + lang)}",
                                    "--allow-file-access-from-files", html_path.as_uri()],
                                   capture_output=True, timeout=400)
            except subprocess.TimeoutExpired:
                continue
            if r.returncode == 0 or (out_png.exists() and out_png.stat().st_size > 0):
                break
        else:
            raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
        print(f"rendered {out_png}")

if __name__ == "__main__":
    langs = sys.argv[1:] or list(COPY)
    for lang in langs:
        if lang not in COPY:
            raise SystemExit(f"모르는 언어: {lang} (아는 것: {', '.join(COPY)})")
        render(lang)
