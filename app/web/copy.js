// Copying, on Safari above all (app/lib/net/copy_web.dart).
//
// Safari lets a page write to the clipboard only while the user is
// touching or clicking it, and counts the app's own tap as over by the
// time the app has worked out that Copy was tapped. So the app hands the
// text here, and it is written twice over: at once, which is enough
// where the browser allows it, and again in the browser's own touchend
// and click, which Safari counts as the tap itself. Whichever is allowed
// wins; writing the same text twice is harmless.
(function () {
  var pending = null;

  function write(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).then(
        function () { return true; },
        function () { return legacy(text); }
      );
    }
    return Promise.resolve(legacy(text));
  }

  // The fallback, for a browser without the Clipboard API or one that
  // refuses it: a hidden text area, selected and copied.
  function legacy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.top = '0';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.focus();
    area.setSelectionRange(0, text.length);
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(area);
    return ok;
  }

  function flush() {
    if (pending === null) return;
    var text = pending;
    pending = null;
    write(text);
  }
  document.addEventListener('touchend', flush, true);
  document.addEventListener('click', flush, true);

  window.ohCopy = function (text) {
    pending = text;
    return write(text);
  };

  // Pasting is the other way round, and Safari holds it to the same
  // rule — above all in an app added to the home screen. So the app asks
  // here, and the clipboard is read in the tap's own touchend or click;
  // with no such event soon (a key pressed, a browser that allows it
  // anyway) it is read at once. Null when it cannot be read: the app then
  // leaves the person to paste by hand.
  var asked = null;
  function read() {
    var a = asked;
    asked = null;
    if (!a) return;
    clearTimeout(a.timer);
    if (!navigator.clipboard || !navigator.clipboard.readText) return a.resolve(null);
    navigator.clipboard.readText().then(
      function (text) { a.resolve(typeof text === 'string' ? text : null); },
      function () { a.resolve(null); }
    );
  }
  document.addEventListener('touchend', read, true);
  document.addEventListener('click', read, true);

  window.ohPaste = function () {
    return new Promise(function (resolve) {
      if (asked) {
        clearTimeout(asked.timer);
        asked.resolve(null);
      }
      asked = { resolve: resolve, timer: setTimeout(read, 400) };
    });
  };
})();
