#!/usr/bin/env python3
"""App Store 크리에이티브 자산(제품 페이지 헤더 · 검색 결과) 생성: HTML → 헤드리스 Chrome.

사용법: python3 scripts/make_creative_assets.py [언어 ...]     (없으면 전부)

자리
  docs/screenshots/creative/<스토어 로케일>/header.png   3840x1646  제품 페이지 맨 위
  docs/screenshots/creative/<스토어 로케일>/search.png   3840x2560  검색 결과 (없으면 스크린샷이 대신 보인다)

⚠️ 안전 영역 밖은 기기에 따라 잘린다. 글은 **반드시** 안전 영역 안에 둔다(배경 · 기기 그림은 넘쳐도 된다).
   수치는 Apple 공식 PSD 템플릿에서 잰 값이다(https://developer.apple.com/app-store/asset-best-practices/).
   아이폰에서 헤더는 가운데만 남고, 검색 결과는 약 385pt 폭으로 줄어 보인다. 그래서 글이 크다.

⚠️ 가격 · 할인 · 주소(URL) · 수상 · 다른 플랫폼 이름은 넣지 않는다(Apple 가이드).
"""
import shutil, subprocess, sys, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw"
OUT = ROOT / "docs" / "screenshots" / "creative"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 앱 언어 코드 → App Store Connect 로케일 (make_marketing_screenshots.py 와 같다)
STORE = {c: c for c in (
    "ko", "en", "en-GB", "zh-Hans", "zh-Hant", "ja", "ru", "es", "de", "fr", "it", "pt-BR",
    "th", "vi", "cs", "da", "el", "fi", "id", "nb", "nl", "pl", "sv", "tr",
)}

# (가로, 세로, 안전 영역 left, top, right, bottom)
SPEC = {
    "header": (3840, 1646, (1097, 493, 2743, 1154)),
    "search": (3840, 2560, (836, 765, 3004, 1795)),
}

# 눈썹글 · 헤드라인 · 보조 문장은 검색 결과에 쓴다. 스크린샷 1장과 **같은 이야기**다
# (검색에서 본 말이 페이지에서도 이어져야 한다, docs/marketing/ASO_2026-10.md).
# 눈썹글은 그 나라 검색어다.
SEARCH = {
    "ko": ("스티커 만들기", "꾹 누르면<br>움직이는 스티커", "찍는 순간 대상만 쏙 오려 내요"),
    "en": ("Sticker Maker", "Hold for a<br>moving sticker", "Cuts out just your subject as you shoot"),
    "en-GB": ("Sticker Maker", "Press and hold for<br>a moving sticker", "Cuts out just your subject as you shoot"),
    "zh-Hans": ("贴纸制作", "长按一下<br>变成会动的贴纸", "拍下的瞬间，主体一键抠出"),
    "zh-Hant": ("貼圖製作", "長按一下<br>變成會動的貼圖", "拍下的瞬間，主體一鍵去背"),
    "ja": ("ステッカー作成", "長押しで<br>動くステッカーに", "撮った瞬間、被写体だけを切り抜き"),
    "ru": ("Создать стикер", "Удерживайте —<br>и стикер оживёт", "Камера сама вырежет главное в кадре"),
    "es": ("Crear stickers", "Mantén pulsado:<br>sticker animado", "Recorta solo lo importante al instante"),
    "de": ("Sticker erstellen", "Gedrückt halten:<br>bewegter Sticker", "Dein Motiv wird sofort freigestellt"),
    "fr": ("Créer autocollants", "Appui long :<br>autocollant animé", "Votre sujet est détouré dès la prise"),
    "it": ("Crea adesivi", "Tieni premuto:<br>adesivo animato", "Ritaglia solo il soggetto mentre scatti"),
    "pt-BR": ("Criar adesivos", "Segure e pronto:<br>adesivo animado", "Recorta só o que importa na hora"),
    "th": ("ทำสติกเกอร์", "กดค้างไว้<br>ได้สติกเกอร์ขยับได้", "ตัดเฉพาะตัวแบบออกมาทันทีที่ถ่าย"),
    "vi": ("Tạo nhãn dán", "Nhấn giữ là có<br>nhãn dán chuyển động", "Tự tách chủ thể ngay khi chụp"),
    "cs": ("Tvorba nálepek", "Podrž a máš<br>pohyblivou nálepku", "Vystřihne jen to hlavní hned při focení"),
    "da": ("Lav klistermærker", "Hold nede for et<br>bevægeligt mærke", "Klipper motivet fri, mens du fotograferer"),
    "el": ("Αυτοκόλλητα", "Κράτα πατημένο για<br>ζωντανό αυτοκόλλητο", "Κόβει μόνο το θέμα τη στιγμή της λήψης"),
    "fi": ("Tarrojen teko", "Pidä painettuna,<br>saat liikkuvan tarran", "Rajaa kohteen irti heti kuvatessa"),
    "id": ("Pembuat Stiker", "Tahan untuk bikin<br>stiker bergerak", "Langsung memotong objek saat memotret"),
    "nb": ("Lag klistremerker", "Hold inne for et<br>levende klistremerke", "Klipper ut motivet idet du tar bildet"),
    "nl": ("Stickers maken", "Houd ingedrukt voor<br>een bewegende sticker", "Knipt je onderwerp meteen uit"),
    "pl": ("Kreator naklejek", "Przytrzymaj,<br>a naklejka ożyje", "Wycina sam obiekt już przy zdjęciu"),
    "sv": ("Skapa klistermärken", "Håll inne för ett<br>rörligt klistermärke", "Klipper ut motivet direkt när du fotar"),
    "tr": ("Çıkartma yap", "Basılı tut,<br>hareketli çıkartma", "Çektiğin an konuyu kesip çıkarır"),
}

# 헤더는 처음 온 사람에게 **한 가지 약속**만 한다(Apple: 단일한 생각, 빽빽하지 않게).
# 앱이 무엇을 해 주는지를 한 문장으로: 한 번 써 두면 그다음은 누르기만 한다.
# ⚠️ 기계번역하지 않는다. 각 언어에서 짧게 읽히는 말로 따로 쓴다. 높임은 그 언어 스크린샷과 맞춘다.
HEADER = {
    "ko": ("스티커 카메라", "꾹 눌러 뜯은 순간을<br>대화에 붙여요"),
    "en": ("Sticker Camera", "Punch out a moment,<br>stick it in your chats"),
    "en-GB": ("Sticker Camera", "Punch out a moment,<br>pop it in your chats"),
    "zh-Hans": ("贴纸相机", "长按撕下的瞬间<br>直接贴进聊天"),
    "zh-Hant": ("貼圖相機", "長按撕下的瞬間<br>直接貼進聊天"),
    "ja": ("ステッカーカメラ", "長押しではがした瞬間を<br>トークに貼ろう"),
    "ru": ("Камера-стикер", "Оторвите кадр<br>и вставьте в чат"),
    "es": ("Cámara de stickers", "Arranca el momento<br>y pégalo en el chat"),
    "de": ("Sticker-Kamera", "Moment abtrennen,<br>in den Chat kleben"),
    "fr": ("Appareil autocollants", "Détachez l'instant,<br>collez-le dans vos chats"),
    "it": ("Fotocamera adesivi", "Stacca l'attimo<br>e incollalo in chat"),
    "pt-BR": ("Câmera de adesivos", "Destaque o momento<br>e cole na conversa"),
    "th": ("กล้องสติกเกอร์", "กดค้างฉีกช่วงเวลา<br>แปะลงแชตได้เลย"),
    "vi": ("Camera nhãn dán", "Bấm giữ khoảnh khắc<br>dán ngay vào trò chuyện"),
    "cs": ("Fotoaparát na nálepky", "Odtrhni okamžik<br>a vlep ho do chatu"),
    "da": ("Klistermærke-kamera", "Riv øjeblikket af<br>og sæt det i chatten"),
    "el": ("Κάμερα αυτοκόλλητων", "Απόσπασε τη στιγμή<br>και κόλλησέ τη στη συζήτηση"),
    "fi": ("Tarrakamera", "Irrota hetki<br>ja liimaa se chattiin"),
    "id": ("Kamera Stiker", "Sobek momennya,<br>tempel di obrolan"),
    "nb": ("Klistremerkekamera", "Riv av øyeblikket<br>og lim det i chatten"),
    "nl": ("Stickercamera", "Scheur het moment af<br>en plak het in je chat"),
    "pl": ("Aparat do naklejek", "Oderwij chwilę<br>i wklej ją do czatu"),
    "sv": ("Klistermärkeskamera", "Riv loss stunden<br>och klistra in i chatten"),
    "tr": ("Çıkartma Kamerası", "Anı kopar,<br>sohbete yapıştır"),
}

# ⚠️ 바탕 · 글자색은 기존 스크린샷(make_marketing_screenshots.py)과 같다. 다르면 페이지에서
#    헤더만 남의 앱처럼 보인다.
BASE_CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; }
body { background:linear-gradient(180deg,#FFF6E8 0%%,#FFE6CF 100%%); position:relative;
  font-family:-apple-system, "SF Pro Display", "Apple SD Gothic Neo", "Hiragino Sans", "PingFang SC", "Thonburi", sans-serif; }
.glow { position:absolute; border-radius:50%%; filter:blur(160px); pointer-events:none; }
.text { position:absolute; display:flex; flex-direction:column; justify-content:center; }
.eyebrow { font-weight:700; color:#F2703F; letter-spacing:-0.01em; line-height:1.15; }
.headline { font-weight:800; color:#2B2138; letter-spacing:-0.03em; line-height:1.12; text-wrap:balance; }
.sub { font-weight:500; color:#9A7B66; letter-spacing:-0.01em; line-height:1.35; text-wrap:balance; }
:lang(th) .headline, :lang(th) .eyebrow, :lang(th) .sub,
:lang(ja) .headline, :lang(zh) .headline { letter-spacing:0; }
:lang(th) .headline { line-height:1.3; }
/* 한국어는 낱말 중간에서 끊지 않는다("키 / 보드"). */
:lang(ko) .headline, :lang(ko) .sub, :lang(ko) .eyebrow { word-break:keep-all; }
.phone { position:absolute; background:#17171a; border:6px solid #3a3a3e; padding:40px; border-radius:190px;
  box-shadow: 0 60px 160px rgba(90,40,20,.30), 0 0 0 2px #232327 inset; }
.phone img { width:100%%; display:block; border-radius:152px; }
.key { position:absolute; filter:invert(1); mix-blend-mode:screen; opacity:.16; }
"""

# 글이 상자를 넘지 않을 때까지 줄인다. 잘리는 글은 없다 - 끝까지 안 맞으면 표시하고 멈춘다.
FIT_JS = """
<script>
// 문구에 적은 줄(<br>)보다 더 쪼개지면 "Rispondi / con un / tocco" 처럼 읽기가 끊긴다.
// 적은 줄 수를 지킬 때까지 줄인다.
function lines(el) {
  return Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
}
function fit(box, el, max, min) {
  const want = el.querySelectorAll('br').length + 1;
  let size = max;
  el.style.fontSize = size + 'px';
  while (size > min && (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 ||
         lines(el) > want)) {
    size -= 4; el.style.fontSize = size + 'px';
  }
  if (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 || lines(el) > want)
    document.body.dataset.overflow = '1';
}
document.fonts.ready.then(() => {
  const box = document.querySelector('.text');
  const h = document.querySelector('.headline');
  fit(box, h, +h.dataset.max, +h.dataset.min);
  document.body.dataset.done = '1';
});
</script>
"""


def phone(img, left, top, width, rotate=0):
    return (f'<div class="phone" style="left:{left}px;top:{top}px;width:{width}px;'
            f'transform:rotate({rotate}deg)"><img src="{img}"></div>')


def search_html(lang):
    W, H, (l, t, r, b) = SPEC["search"]
    eyebrow, headline, sub = SEARCH[lang]
    sw, sh = r - l, b - t
    col = int(sw * 0.56)
    # 기기는 안전 영역 오른쪽 몫에 서서, 위아래로 넘쳐 화면 밖까지 이어진다(기기 그림은 잘려도 된다).
    ph_w = 1040
    ph_left = l + col + int(sw * 0.04)
    img = (RAW / lang / "01-reveal.png").as_uri()
    return f"""
<div class="glow" style="left:{ph_left - 300}px;top:500px;width:1700px;height:1700px;background:rgba(255,160,90,.20)"></div>
<div class="glow" style="left:{l - 700}px;top:{t - 500}px;width:1400px;height:1000px;background:rgba(255,160,90,.07)"></div>
{phone(img, ph_left, t - 360, ph_w, 0)}
<div class="text" style="left:{l}px;top:{t}px;width:{col}px;height:{sh}px">
  <div class="eyebrow" style="font-size:96px">{eyebrow}</div>
  <div class="headline" data-max="250" data-min="140" style="margin-top:36px">{headline}</div>
  <div class="sub" style="font-size:84px;margin-top:52px">{sub}</div>
</div>"""


def header_html(lang):
    W, H, (l, t, r, b) = SPEC["header"]
    eyebrow, headline = HEADER[lang]
    sw, sh = r - l, b - t
    left_img = (RAW / lang / "02-album.png").as_uri()
    right_img = (RAW / lang / "06-chat.png").as_uri()
    return f"""
<div class="glow" style="left:{l - 200}px;top:{t - 400}px;width:{sw + 400}px;height:{sh + 800}px;background:rgba(255,160,90,.16)"></div>
{phone(left_img, 300, 360, 640, -9)}
{phone(right_img, 2900, 360, 640, 9)}
<div class="text" style="left:{l}px;top:{t}px;width:{sw}px;height:{sh}px;align-items:center;text-align:center">
  <div class="eyebrow" style="font-size:76px">{eyebrow}</div>
  <div class="headline" data-max="210" data-min="110" style="margin-top:22px">{headline}</div>
</div>"""


def html_lang(lang):
    return {"zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}.get(lang, lang)


def render(lang, kind):
    W, H, _ = SPEC[kind]
    body = search_html(lang) if kind == "search" else header_html(lang)
    page = (f'<!doctype html><html lang="{html_lang(lang)}"><head><meta charset="utf-8"><style>'
            f'{BASE_CSS % {"W": W, "H": H}}</style></head><body>{body}{FIT_JS}</body></html>')
    html_path = pathlib.Path(tempfile.gettempdir()) / f"punching-creative-{lang}-{kind}.html"
    html_path.write_text(page, encoding="utf-8")
    # 글이 끝까지 안 맞으면 그림을 만들지 않는다(잘린 글이 스토어에 올라가는 것보다 낫다).
    dom = subprocess.run([CHROME, "--headless=new", "--dump-dom", f"--window-size={W},{H}",
                          "--force-device-scale-factor=1", "--disable-gpu", "--virtual-time-budget=3000",
                          html_path.as_uri()], capture_output=True, text=True, timeout=90).stdout
    if 'data-done="1"' not in dom:
        raise SystemExit(f"글 맞추기가 끝나지 않았다: {lang} {kind}")
    if 'data-overflow="1"' in dom:
        raise SystemExit(f"글이 안전 영역을 넘는다: {lang} {kind} - 문구를 줄일 것")
    out_dir = OUT / STORE.get(lang, lang)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_png = out_dir / f"{kind}.png"
    # ⚠️ Chrome 은 가끔 아무것도 안 그리고 끝나거나 멈춘다. 세 번까지 한다.
    for _ in range(5):
        try:
            r = subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                                f"--window-size={W},{H}", "--force-device-scale-factor=1",
                                "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=3000",
                                "--allow-file-access-from-files", html_path.as_uri()],
                               capture_output=True, timeout=180)
        except subprocess.TimeoutExpired:
            continue
        if r.returncode == 0:
            break
    else:
        raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
    print(f"rendered {out_png}")


if __name__ == "__main__":
    langs = sys.argv[1:] or list(SEARCH)
    for lang in langs:
        if lang not in SEARCH:
            raise SystemExit(f"모르는 언어: {lang} (아는 것: {', '.join(SEARCH)})")
        for kind in ("header", "search"):
            render(lang, kind)
