// The folding heart from the app (app/lib/ui/folding_heart.dart): every
// twenty seconds it folds in half three times, shuts about its last
// crease, and opens out again the same way. Held still for anyone who
// asks for less motion.
(() => {
  const canvas = document.querySelector('canvas.heart');
  const color = getComputedStyle(document.documentElement).getPropertyValue('--chrome').trim();
  const FIRST = 3000, TURN = 9000, EVERY = 20000;
  const folds = ['v', 'h', 'v'];
  const still = 0.14, foldFor = 0.09, shutFor = 0.09;
  const half = still + 3 * foldFor + shutFor;

  // Curves.easeInOut: cubic-bezier(0.42, 0, 0.58, 1).
  const ease = (x) => {
    if (x <= 0 || x >= 1) return x <= 0 ? 0 : 1;
    const bez = (t, a, b) => 3 * a * t * (1 - t) ** 2 + 3 * b * t * t * (1 - t) + t ** 3;
    let lo = 0, hi = 1, t = x;
    for (let i = 0; i < 30; i++) {
      t = (lo + hi) / 2;
      if (bez(t, 0.42, 0.58) < x) lo = t; else hi = t;
    }
    return bez(t, 0, 1);
  };

  const [r, g, b] = color.match(/[0-9a-f]{2}/gi).map((c) => parseInt(c, 16));
  const shade = (layers) => {
    const k = 1 - Math.min(0.13 * layers, 0.55);
    return `rgb(${r * k}, ${g * k}, ${b * k})`;
  };

  function heart(ctx, w, h) {
    ctx.beginPath();
    ctx.moveTo(w * 0.5, h * 0.92);
    ctx.bezierCurveTo(w * 0.06, h * 0.62, w * 0.02, h * 0.34, w * 0.20, h * 0.16);
    ctx.bezierCurveTo(w * 0.35, h * 0.02, w * 0.46, h * 0.12, w * 0.5, h * 0.26);
    ctx.bezierCurveTo(w * 0.54, h * 0.12, w * 0.65, h * 0.02, w * 0.80, h * 0.16);
    ctx.bezierCurveTo(w * 0.98, h * 0.34, w * 0.94, h * 0.62, w * 0.5, h * 0.92);
    ctx.closePath();
  }

  function packet(w, h) {
    let s = { l: 0, t: 0, r: w, b: h };
    for (const c of folds) {
      s = c === 'v' ? { ...s, r: (s.l + s.r) / 2 } : { ...s, b: (s.t + s.b) / 2 };
    }
    return s;
  }

  function sheet(ctx, s, depth, layers, made, making, w, h, flipX, flipY) {
    const over = depth >= folds.length || depth > made ? 0 : depth < made ? 1 : making;
    if (over <= 0) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(s.l, s.t, s.r - s.l, s.b - s.t);
      ctx.clip();
      heart(ctx, w, h);
      ctx.fillStyle = shade(layers);
      ctx.fill();
      ctx.restore();
      return;
    }
    const down = folds[depth] === 'v';
    const cx = (s.l + s.r) / 2, cy = (s.t + s.b) / 2;
    const near = down ? { ...s, r: cx } : { ...s, b: cy };
    const far = down ? { ...s, l: cx } : { ...s, t: cy };
    const flipped = down ? flipX : flipY;
    sheet(ctx, flipped ? far : near, depth + 1, layers, made, making, w, h, flipX, flipY);
    const k = Math.cos(over * Math.PI);
    ctx.save();
    if (down) { ctx.translate(cx, 0); ctx.scale(k, 1); ctx.translate(-cx, 0); }
    else { ctx.translate(0, cy); ctx.scale(1, k); ctx.translate(0, -cy); }
    sheet(ctx, flipped ? near : far, depth + 1, layers + 1, made, making, w, h,
      down ? !flipX : flipX, down ? flipY : !flipY);
    ctx.restore();
  }

  function paint(at) {
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const t = (at < 0.5 ? at : 1 - at) / 0.5 * half;
    let made = 0, making = 0, shut = 0;
    if (t > still) {
      const into = t - still;
      made = Math.min(Math.max(Math.floor(into / foldFor), 0), folds.length);
      making = made < folds.length ? (into - made * foldFor) / foldFor : 1;
      if (made >= folds.length) shut = Math.min(Math.max((into - folds.length * foldFor) / shutFor, 0), 1);
    }
    ctx.save();
    if (shut > 0) {
      const p = packet(w, h);
      const k = Math.cos(shut * Math.PI / 2);
      ctx.translate(p.r, 0); ctx.scale(k, 1); ctx.translate(-p.r, 0);
    }
    sheet(ctx, { l: 0, t: 0, r: w, b: h }, 0, 0, made, ease(Math.min(Math.max(making, 0), 1)), w, h, false, false);
    ctx.restore();
  }

  paint(0);
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  function turn() {
    const start = performance.now();
    const step = (now) => {
      const at = Math.min((now - start) / TURN, 1);
      paint(at);
      if (at < 1) requestAnimationFrame(step);
      else setTimeout(turn, EVERY - TURN);
    };
    requestAnimationFrame(step);
  }
  setTimeout(turn, FIRST);
})();
