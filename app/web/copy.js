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

  // The old way, for a browser without the Clipboard API or one that
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
})();
