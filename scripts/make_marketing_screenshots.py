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
# 01 · 02 · 07 · 08 은 scripts/capture_screenshots.sh(앱의 DEBUG 스크린샷 장면, SHOT_LANG=<언어>)로, 06-chat 은
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
    ("01-pick.png",  "hero-bleed"),    # 찍으면 대상이 골라진다 · 둘러 그리기
    ("06-chat.png",  "left-text"),     # 대화에 붙이기
    ("07-tags.png",  "flat-rotate"),   # 저절로 분류
    ("08-map.png",   "text-bottom"),   # 지도
    ("02-album.png", "dark"),          # 수집함 = 스티커 팩
]

# ⚠️ 기계번역하지 않는다. 앱 화면의 낱말(수집함=Books/ブック/收藏册…, 뜯기, 색감)과 맞춘다.
COPY = {
    "ko": [
        ("찍으면<br>스티커가 쏙", "알아서 찾고, 원하는 곳은 둘러 그려요"),
        ("대화에<br>바로 붙여요", "메시지와 키보드에서 꺼내 써요"),
        ("저절로<br>분류돼요", "강아지, 고양이, 음식끼리 모아 봐요"),
        ("찍은 자리에<br>스티커가 남아요", "지도에서 그날의 스티커를 다시 봐요"),
        ("수집함마다<br>나만의 스티커 팩", "모은 스티커가 묶음으로 따라와요"),
    ],
    "en": [
        ("Snap it,<br>sticker it", "It finds the subject. Circle the rest."),
        ("Stick it right<br>in your chats", "Grab it from Messages or the keyboard"),
        ("Sorted<br>for you", "Dogs, cats, food, all in one tap"),
        ("Stickers stay<br>where you took them", "Revisit the day on a map"),
        ("Every book is<br>a sticker pack", "Your stickers travel as a set"),
    ],
    "en-GB": [
        ("Snap it,<br>sticker it", "It finds the subject. Circle the rest."),
        ("Pop it straight<br>into your chats", "Grab it from Messages or the keyboard"),
        ("Sorted<br>for you", "Dogs, cats, food, all in one tap"),
        ("Stickers stay<br>where you took them", "Revisit the day on a map"),
        ("Every book is<br>a sticker pack", "Your stickers travel as a set"),
    ],
    "ja": [
        ("撮れば<br>ステッカーに", "被写体を自動で検出、指で囲んでもOK"),
        ("トークに<br>そのまま貼れる", "メッセージとキーボードから使える"),
        ("自動で<br>仕分け", "犬、猫、食べ物ごとにまとめて見られる"),
        ("撮った場所に<br>ステッカーが残る", "地図であの日のステッカーを見返そう"),
        ("ブックごとに<br>自分だけのパック", "集めたステッカーがセットで使える"),
    ],
    "zh-Hans": [
        ("一拍<br>就成贴纸", "自动找出主体，想要的再圈一圈"),
        ("直接贴进<br>聊天里", "在信息和键盘里随手取用"),
        ("自动<br>分好类", "狗狗、猫咪、美食，一键查看"),
        ("贴纸留在<br>拍下的地方", "在地图上重温那一天"),
        ("每本收藏册<br>都是专属贴纸包", "收集的贴纸整套跟着走"),
    ],
    "zh-Hant": [
        ("一拍<br>就成貼圖", "自動找出主體，想要的再圈一圈"),
        ("直接貼進<br>聊天裡", "在訊息和鍵盤裡隨手取用"),
        ("自動<br>分好類", "狗狗、貓咪、美食，一鍵查看"),
        ("貼圖留在<br>拍下的地方", "在地圖上重溫那一天"),
        ("每本收藏冊<br>都是專屬貼圖包", "收集的貼圖整組帶著走"),
    ],
    "ru": [
        ("Снял —<br>и стикер готов", "Сам находит объект, остальное обведите"),
        ("Сразу<br>в переписку", "Берите из Сообщений и с клавиатуры"),
        ("Сами<br>по полочкам", "Собаки, кошки, еда — в один тап"),
        ("Стикеры там,<br>где вы снимали", "Вспомните тот день на карте"),
        ("Каждый альбом —<br>свой стикерпак", "Собранные стикеры всегда под рукой"),
    ],
    "es": [
        ("Haz la foto,<br>ten el sticker", "Encuentra el sujeto; rodea lo demás"),
        ("Pégalo directo<br>en tus chats", "Desde Mensajes o el teclado"),
        ("Ordenados<br>solos", "Perros, gatos, comida, a un toque"),
        ("Tus stickers,<br>donde los tomaste", "Revive ese día en el mapa"),
        ("Cada álbum es<br>un pack de stickers", "Tus stickers van juntos a todas partes"),
    ],
    "de": [
        ("Knipsen,<br>Sticker fertig", "Findet das Motiv. Den Rest umkreist du."),
        ("Direkt<br>in den Chat", "Aus Nachrichten oder der Tastatur"),
        ("Von selbst<br>sortiert", "Hunde, Katzen, Essen – mit einem Tipp"),
        ("Sticker bleiben,<br>wo sie entstanden", "Erlebe den Tag auf der Karte neu"),
        ("Jede Sammlung<br>ein Sticker-Pack", "Deine Sticker bleiben zusammen"),
    ],
    "fr": [
        ("Une photo,<br>un sticker", "Il trouve le sujet, entourez le reste"),
        ("Collez-le direct<br>dans vos chats", "Depuis Messages ou le clavier"),
        ("Triés<br>tout seuls", "Chiens, chats, plats, d’un seul geste"),
        ("Vos stickers,<br>là où ils sont nés", "Revivez la journée sur la carte"),
        ("Chaque classeur,<br>un pack à vous", "Vos autocollants restent ensemble"),
    ],
    "it": [
        ("Scatta,<br>ed è uno sticker", "Trova il soggetto, il resto lo cerchi tu"),
        ("Incollalo subito<br>in chat", "Da Messaggi o dalla tastiera"),
        ("Ordinati<br>da soli", "Cani, gatti, cibo, con un tocco"),
        ("Sticker dove<br>li hai scattati", "Rivivi quel giorno sulla mappa"),
        ("Ogni album è<br>un pacchetto tuo", "I tuoi adesivi sempre insieme"),
    ],
    "pt-BR": [
        ("Tirou a foto,<br>virou figurinha", "Acha o objeto; o resto você contorna"),
        ("Cole direto<br>na conversa", "Pelo Mensagens ou pelo teclado"),
        ("Organizadas<br>sozinhas", "Cães, gatos, comida, num toque"),
        ("Figurinhas onde<br>você tirou", "Reviva o dia no mapa"),
        ("Cada álbum é<br>um pacote seu", "Seus adesivos sempre juntos"),
    ],
    "th": [
        ("ถ่ายปุ๊บ<br>ได้สติกเกอร์", "หาวัตถุให้เอง ที่เหลือวาดล้อมได้"),
        ("แปะลงแชต<br>ได้ทันที", "หยิบใช้จากข้อความและคีย์บอร์ด"),
        ("แยกหมวด<br>ให้เอง", "หมา แมว อาหาร ดูรวมได้ในแตะเดียว"),
        ("สติกเกอร์อยู่<br>ตรงที่ถ่าย", "ย้อนดูวันนั้นบนแผนที่"),
        ("ทุกอัลบั้ม<br>คือแพ็กของคุณ", "สติกเกอร์ที่สะสมไว้มาเป็นชุด"),
    ],
    "vi": [
        ("Chụp là có<br>nhãn dán", "Tự tìm chủ thể, phần còn lại thì khoanh"),
        ("Dán ngay<br>vào trò chuyện", "Lấy từ Tin nhắn hoặc bàn phím"),
        ("Tự động<br>phân loại", "Chó, mèo, đồ ăn, xem gọn một chạm"),
        ("Nhãn dán ở lại<br>nơi bạn chụp", "Xem lại ngày ấy trên bản đồ"),
        ("Mỗi bộ sưu tập<br>là một gói riêng", "Nhãn dán đi cùng nhau thành bộ"),
    ],
    "cs": [
        ("Vyfoť<br>a máš nálepku", "Najde hlavní motiv, zbytek obkresli"),
        ("Rovnou<br>do chatu", "Ze Zpráv nebo z klávesnice"),
        ("Samy<br>roztříděné", "Psi, kočky, jídlo jedním klepnutím"),
        ("Nálepky tam,<br>kde vznikly", "Vrať se k tomu dni na mapě"),
        ("Každé album<br>je tvůj balíček", "Nálepky máš vždy pohromadě"),
    ],
    "da": [
        ("Tag et billede,<br>få et mærke", "Finder motivet – resten tegner du om"),
        ("Lige ind<br>i chatten", "Fra Beskeder eller tastaturet"),
        ("Sorteret<br>af sig selv", "Hunde, katte, mad med ét tryk"),
        ("Mærker der,<br>hvor du tog dem", "Genoplev dagen på kortet"),
        ("Hvert album er<br>din egen pakke", "Dine mærker følges ad"),
    ],
    "el": [
        ("Τράβα φωτό,<br>πάρε αυτοκόλλητο", "Βρίσκει το θέμα, τα άλλα τα κυκλώνεις"),
        ("Κατευθείαν<br>στη συζήτηση", "Από τα Μηνύματα ή το πληκτρολόγιο"),
        ("Ταξινομούνται<br>μόνα τους", "Σκύλοι, γάτες, φαγητό με ένα άγγιγμα"),
        ("Μένουν εκεί<br>που τα τράβηξες", "Ξαναζήσε τη μέρα στον χάρτη"),
        ("Κάθε άλμπουμ<br>δικό σου πακέτο", "Τα αυτοκόλλητά σου μένουν μαζί"),
    ],
    "fi": [
        ("Kuvaa,<br>ja tarra on valmis", "Löytää kohteen, muun voit ympyröidä"),
        ("Suoraan<br>keskusteluun", "Viesteistä tai näppäimistöltä"),
        ("Lajiteltu<br>valmiiksi", "Koirat, kissat, ruoka yhdellä napautuksella"),
        ("Tarrat jäävät<br>kuvauspaikalle", "Palaa siihen päivään kartalla"),
        ("Jokainen albumi<br>on oma pakkaus", "Tarrasi pysyvät yhdessä"),
    ],
    "id": [
        ("Foto langsung<br>jadi stiker", "Objek ditemukan otomatis, sisanya lingkari"),
        ("Tempel langsung<br>di obrolan", "Ambil dari Pesan atau papan ketik"),
        ("Terurut<br>otomatis", "Anjing, kucing, makanan, sekali ketuk"),
        ("Stiker tetap<br>di tempat difoto", "Kenang hari itu di peta"),
        ("Tiap album jadi<br>paket stikermu", "Stikermu selalu terkumpul rapi"),
    ],
    "nb": [
        ("Ta bilde,<br>få et merke", "Finner motivet – resten tegner du rundt"),
        ("Rett inn<br>i chatten", "Fra Meldinger eller tastaturet"),
        ("Sortert<br>av seg selv", "Hunder, katter, mat med ett trykk"),
        ("Merkene blir<br>der du tok dem", "Opplev dagen igjen på kartet"),
        ("Hvert album er<br>din egen pakke", "Merkene dine holder sammen"),
    ],
    "nl": [
        ("Klik, en je<br>hebt een sticker", "Vindt het onderwerp, de rest omcirkel je"),
        ("Zo in<br>je chat", "Vanuit Berichten of het toetsenbord"),
        ("Vanzelf<br>gesorteerd", "Honden, katten, eten met één tik"),
        ("Stickers blijven<br>waar je ze nam", "Beleef die dag opnieuw op de kaart"),
        ("Elke verzameling<br>een stickerpakket", "Je stickers blijven bij elkaar"),
    ],
    "pl": [
        ("Zrób zdjęcie,<br>masz naklejkę", "Sam znajduje obiekt, resztę obrysuj"),
        ("Prosto<br>do czatu", "Z Wiadomości lub z klawiatury"),
        ("Same się<br>sortują", "Psy, koty, jedzenie jednym dotknięciem"),
        ("Naklejki tam,<br>gdzie je zrobiono", "Wróć do tego dnia na mapie"),
        ("Każdy album<br>to twój zestaw", "Naklejki trzymają się razem"),
    ],
    "sv": [
        ("Ta en bild,<br>få ett märke", "Hittar motivet – resten ringar du in"),
        ("Rakt in<br>i chatten", "Från Meddelanden eller tangentbordet"),
        ("Sorterade<br>av sig själva", "Hundar, katter, mat med ett tryck"),
        ("Märkena stannar<br>där du tog dem", "Upplev dagen igen på kartan"),
        ("Varje album är<br>ditt eget paket", "Märkena håller ihop"),
    ],
    "tr": [
        ("Çek,<br>çıkartma olsun", "Konuyu kendi bulur, gerisini çevrele"),
        ("Doğrudan<br>sohbete", "Mesajlar'dan ya da klavyeden"),
        ("Kendiliğinden<br>sıralanır", "Köpek, kedi, yemek tek dokunuşta"),
        ("Çıkartmalar<br>çekildiği yerde", "O günü haritada yeniden yaşa"),
        ("Her koleksiyon<br>kendi paketin", "Çıkartmaların hep bir arada"),
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
