// 펀칭 웹 체험: 펀칭기를 꾹 눌렀다 떼면 스티커가 뜯겨 나온다.
// 우표 모양은 앱의 StampShape(톱니 6×8, biteRatio 0.196)를 그대로 옮겼다.
// 오려내기(Vision)와 색감(StampInk 의 CIFilter)은 site/demo-images.swift 가 앱과 같은 방법으로 미리 만든 그림이다.
(() => {
  const root = document.getElementById("demo");
  if (!root) return;
  const T = JSON.parse(root.dataset.text);
  const base = new URL("img/demo/", document.currentScript.src);
  const SCENES = [{ id: "corgi", subject: true }, { id: "cone", subject: true }, { id: "beach", subject: false }];
  const INKS = ["original", "sepia", "mono", "faded", "chrome", "process"];
  const W = 420, H = 560;
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const state = { scene: 0, ink: 0, cutout: true, punched: null, pressed: false };

  // StampShape.path(in:) — SwiftUI 의 clockwise 는 화면에서 반대로 돌므로 canvas 의 anticlockwise 와 값이 같다.
  function stampPath(w, h, tx = 6, ty = 8, bite = 0.196) {
    const p = new Path2D(), rad = d => d * Math.PI / 180;
    const sx = w / tx, sy = h / ty, r = Math.min(sx, sy) * bite, cr = Math.min(sx, sy) * 0.12;
    const gx = (w - 2 * cr - 2 * r * tx) / (tx + 1), gy = (h - 2 * cr - 2 * r * ty) / (ty + 1);
    const hx = i => cr + gx + r + i * (2 * r + gx), hy = j => cr + gy + r + j * (2 * r + gy);
    p.moveTo(cr, 0);
    for (let i = 0; i < tx; i++) { p.lineTo(hx(i) - r, 0); p.arc(hx(i), 0, r, rad(180), 0, true); }
    p.lineTo(w - cr, 0); p.arc(w - cr, cr, cr, rad(-90), 0, false);
    for (let j = 0; j < ty; j++) { p.lineTo(w, hy(j) - r); p.arc(w, hy(j), r, rad(-90), rad(90), true); }
    p.lineTo(w, h - cr); p.arc(w - cr, h - cr, cr, 0, rad(90), false);
    for (let i = tx - 1; i >= 0; i--) { p.lineTo(hx(i) + r, h); p.arc(hx(i), h, r, 0, rad(180), true); }
    p.lineTo(cr, h); p.arc(cr, h - cr, cr, rad(90), rad(180), false);
    for (let j = ty - 1; j >= 0; j--) { p.lineTo(0, hy(j) + r); p.arc(0, hy(j), r, rad(90), rad(270), true); }
    p.lineTo(0, cr); p.arc(cr, cr, cr, rad(180), rad(270), false);
    p.closePath();
    return p;
  }
  const STAMP = stampPath(W, H);

  const cache = {};
  const load = name => cache[name] || (cache[name] = new Promise((ok, fail) => {
    const img = new Image(); img.onload = () => ok(img); img.onerror = fail; img.src = new URL(name, base).href;
  }));
  // 마스크(흰색 = 대상)를 알파로 바꾸고, 앱처럼 대상이 있는 범위로 잘라낼 상자를 구한다.
  const masks = {};
  function mask(id) {
    return masks[id] || (masks[id] = load(`${id}-mask.png`).then(img => {
      const c = Object.assign(document.createElement("canvas"), { width: W, height: H }), x = c.getContext("2d");
      x.drawImage(img, 0, 0, W, H);
      const d = x.getImageData(0, 0, W, H), px = d.data;
      let l = W, t = H, r = 0, b = 0;
      for (let i = 0; i < px.length; i += 4) {
        const a = px[i]; px[i] = px[i + 1] = px[i + 2] = 0; px[i + 3] = a;
        if (a > 127) { const p = i / 4, cx = p % W, cy = (p / W) | 0; l = Math.min(l, cx); r = Math.max(r, cx); t = Math.min(t, cy); b = Math.max(b, cy); }
      }
      x.putImageData(d, 0, 0);
      return { canvas: c, box: [l, t, r - l + 1, b - t + 1] };
    }));
  }

  root.innerHTML = `
    <div class="pv-side">
      <div class="pv"><canvas class="pv-canvas" width="${W + 120}" height="${H + 120}" aria-hidden="true"></canvas></div>
      <div class="pv-scenes" role="group">
        ${SCENES.map((s, i) => `<button type="button" class="pv-scene" data-scene="${i}" aria-pressed="${i === 0}">
          <img src="${new URL(`${s.id}-original.jpg`, base).href}" alt="" width="44" height="44"><span>${T.scenes[i]}</span></button>`).join("")}
      </div>
      <button type="button" class="pv-punch">${T.hold}</button>
    </div>
    <div class="pv-out">
      <div class="pv-sticker"><canvas class="pv-result" width="${W}" height="${H}"></canvas><p class="muted pv-empty">${T.empty}</p></div>
      <p class="pv-status" aria-live="polite"></p>
      <div class="pv-tools" hidden>
        <div class="pv-row" role="group" aria-label="${T.shape}"><span class="pv-label">${T.shape}</span>
          <button type="button" class="pv-chip" data-cut="1">${T.cutout}</button><button type="button" class="pv-chip" data-cut="0">${T.stamp}</button></div>
        <div class="pv-row" role="group" aria-label="${T.look}"><span class="pv-label">${T.look}</span>
          ${INKS.map((k, i) => `<button type="button" class="pv-chip" data-ink="${i}">${T.inks[i]}</button>`).join("")}</div>
      </div>
      <p class="muted small pv-note">${T.note}</p>
    </div>`;

  const $ = s => root.querySelector(s);
  const view = $(".pv-canvas"), vx = view.getContext("2d"), out = $(".pv-result"), ox = out.getContext("2d");
  const punchBtn = $(".pv-punch"), status = $(".pv-status"), tools = $(".pv-tools");
  let cavity = false;

  // 펀칭기: 하늘색 플라스틱 몸체 가운데 우표 모양 창. 누르는 동안 조금 작아진다(앱의 pressDown).
  async function drawViewfinder() {
    const img = await load(`${SCENES[state.scene].id}-original.jpg`);
    const P = 60, s = state.pressed ? 0.96 : 1;
    vx.clearRect(0, 0, view.width, view.height);
    vx.save();
    vx.translate(view.width / 2, view.height / 2); vx.scale(s, s); vx.translate(-view.width / 2, -view.height / 2);
    const g = vx.createLinearGradient(0, 0, view.width, view.height);
    g.addColorStop(0, "#D8E6F2"); g.addColorStop(1, "#AFC9E0");
    vx.fillStyle = g; vx.beginPath(); vx.roundRect(0, 0, view.width, view.height, 64); vx.fill();
    vx.translate(P, P);
    vx.save(); vx.clip(STAMP);
    vx.drawImage(img, 0, 0, W, H);
    if (cavity) { vx.fillStyle = "rgb(0 0 0 / .82)"; vx.fillRect(0, 0, W, H); }
    vx.restore();
    vx.strokeStyle = "rgb(255 255 255 / .6)"; vx.lineWidth = 3; vx.stroke(STAMP);
    vx.restore();
  }

  async function drawSticker() {
    const p = state.punched;
    if (!p) return;
    const img = await load(`${SCENES[p.scene].id}-${INKS[state.ink]}.jpg`);
    const m = state.cutout && SCENES[p.scene].subject ? await mask(SCENES[p.scene].id) : null;
    if (m) {
      const [l, t, w, h] = m.box;
      out.width = w; out.height = h;
      ox.drawImage(img, -l, -t, W, H);
      ox.globalCompositeOperation = "destination-in"; ox.drawImage(m.canvas, -l, -t); ox.globalCompositeOperation = "source-over";
    } else {
      out.width = W; out.height = H;
      ox.save(); if (!state.cutout) ox.clip(STAMP); ox.drawImage(img, 0, 0, W, H); ox.restore();
    }
    tools.querySelectorAll("[data-cut]").forEach(b => b.setAttribute("aria-pressed", String(+b.dataset.cut === +state.cutout)));
    tools.querySelectorAll("[data-ink]").forEach(b => b.setAttribute("aria-pressed", String(+b.dataset.ink === state.ink)));
  }

  function press() {
    if (state.pressed) return;
    state.pressed = true; punchBtn.textContent = T.holding; punchBtn.classList.add("down");
    drawViewfinder();
  }
  async function release() {
    if (!state.pressed) return;
    state.pressed = false; punchBtn.textContent = T.hold; punchBtn.classList.remove("down");
    const scene = SCENES[state.scene];
    // 오려낼 대상이 없으면 알림으로 막지 않고 우표 모양으로 뜯는다(IDENTITY.md).
    state.punched = { scene: state.scene }; state.cutout = scene.subject; state.ink = 0;
    status.textContent = scene.subject ? T.arrived : T.noSubject;
    cavity = true; drawViewfinder();
    setTimeout(() => { cavity = false; drawViewfinder(); }, still ? 600 : 1800);
    await drawSticker();
    root.classList.add("has-sticker"); tools.hidden = false;
    out.classList.remove("pop"); void out.offsetWidth; out.classList.add("pop");
  }

  punchBtn.addEventListener("pointerdown", e => { punchBtn.setPointerCapture(e.pointerId); press(); });
  punchBtn.addEventListener("pointerup", release);
  punchBtn.addEventListener("pointercancel", release);
  punchBtn.addEventListener("keydown", e => { if ((e.key === " " || e.key === "Enter") && !e.repeat) { e.preventDefault(); press(); } });
  punchBtn.addEventListener("keyup", e => { if (e.key === " " || e.key === "Enter") release(); });
  punchBtn.addEventListener("click", e => { if (e.detail === 0 && !state.pressed) { press(); release(); } });   // 보조 기술의 한 번 누르기
  punchBtn.addEventListener("contextmenu", e => e.preventDefault());

  root.addEventListener("click", e => {
    const s = e.target.closest("[data-scene]"), c = e.target.closest("[data-cut]"), k = e.target.closest("[data-ink]");
    if (s) {
      state.scene = +s.dataset.scene;
      root.querySelectorAll("[data-scene]").forEach(b => b.setAttribute("aria-pressed", String(b === s)));
      drawViewfinder();
    }
    if (c) { state.cutout = c.dataset.cut === "1"; drawSticker(); }
    if (k) { state.ink = +k.dataset.ink; drawSticker(); }
  });

  drawViewfinder();
})();
