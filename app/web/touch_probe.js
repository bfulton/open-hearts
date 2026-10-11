// The touch probe (lib/ui/touch_probe.dart): where the browser says a
// finger came down, and the sizes it gives the page, so that a tap the
// app never sees can be told from one it sees in the wrong place. Off
// until the app asks; nothing is sent anywhere.
(function () {
  var last = {};
  var started = false;
  function note(e) {
    var t = e.touches && e.touches.length ? e.touches[0] : e;
    last[e.type] = { x: t.clientX, y: t.clientY, at: Date.now() };
  }
  window.ohTouchProbe = function () {
    if (!started) {
      started = true;
      window.addEventListener('pointerdown', note, true);
      window.addEventListener('touchstart', note, { capture: true, passive: true });
    }
    var probe = document.createElement('div');
    probe.style.cssText = 'position:fixed;visibility:hidden;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';
    document.body.appendChild(probe);
    var cs = getComputedStyle(probe);
    var safe = [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft].map(parseFloat);
    probe.remove();
    var view = document.querySelector('flutter-view') || document.querySelector('flt-glass-pane');
    var r = view ? view.getBoundingClientRect() : null;
    var v = window.visualViewport;
    return JSON.stringify({
      last: last,
      inner: [innerWidth, innerHeight],
      client: [document.documentElement.clientWidth, document.documentElement.clientHeight],
      visual: v ? [v.width, v.height, v.offsetLeft, v.offsetTop, v.scale] : null,
      screen: [screen.width, screen.height],
      orientation: (screen.orientation && screen.orientation.type) || String(window.orientation),
      dpr: devicePixelRatio,
      view: r ? [r.left, r.top, r.width, r.height] : null,
      scroll: [scrollX, scrollY],
      safe: safe,
      settled: window.ohSettled,
      standalone: navigator.standalone === true || matchMedia('(display-mode: standalone)').matches,
    });
  };
})();
