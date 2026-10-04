// The page never scrolls: the app fills it. An iPhone's Home Screen app
// turned on its side and back can be left scrolled past the top by the
// status bar's height (scrollY -62), drawn where it was but hit-tested
// that much lower, so every tap lands above the finger. Put back at the
// top whenever it moves or the screen changes shape.
(function () {
  window.ohSettled = 0;
  function settle() {
    if (window.scrollX !== 0 || window.scrollY !== 0) {
      window.scrollTo(0, 0);
      window.ohSettled++;
    }
  }
  // Once now, and again once a turn has finished moving things.
  function soon() {
    settle();
    setTimeout(settle, 100);
    setTimeout(settle, 500);
  }
  window.addEventListener('scroll', settle, { passive: true });
  window.addEventListener('resize', soon);
  window.addEventListener('orientationchange', soon);
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', soon);
    window.visualViewport.addEventListener('scroll', settle);
  }
})();
