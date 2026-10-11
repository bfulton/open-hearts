{{flutter_js}}
{{flutter_build_config}}

// The browser's languages as Intl can read them. Flutter's engine makes
// an Intl.Locale of each as it starts, and one it cannot read stops the
// app before it draws anything: Chromium on Linux with no language set
// (LANG=C) says en-US@posix, which Intl refuses. The part from @ on is
// a POSIX locale's modifier, which a browser's language never needs.
(() => {
  const readable = (tag) => {
    try {
      new Intl.Locale(tag);
      return true;
    } catch (_) {
      return false;
    }
  };
  const languages = [...(navigator.languages ?? [navigator.language])];
  if (languages.every(readable)) return;
  const fixed = languages.map((tag) => (readable(tag) ? tag : tag.split('@')[0])).filter(readable);
  if (fixed.length === 0) fixed.push('en');
  Object.defineProperty(navigator, 'languages', { get: () => Object.freeze([...fixed]) });
  Object.defineProperty(navigator, 'language', { get: () => fixed[0] });
})();

// Flutter's own loader, without Flutter's service worker: that one is
// a stub, which unregisters whatever is registered where it is —
// ours included. Once the device has been brought along from where the
// app used to be, if it is to be (carry.js): the app reads its key as
// it starts, and would make a new one.
(window.ohCarried ?? Promise.resolve()).finally(() => _flutter.loader.load());

// The app kept for a load with no network (offline_worker.js): once
// the first frame is up, so that it never competes with the app for a
// slow connection, and with the list of what this load fetched, which
// a service worker registered now did not see go by. Not for `flutter
// run`, whose every reload is served afresh by the tool anyway, and
// whose thousands of modules kept on every load would only slow it.
const developing = _flutter.buildConfig.builds.some((build) => build.compileTarget === 'dartdevc');
if ('serviceWorker' in navigator && !developing) {
  window.addEventListener(
    'flutter-first-frame',
    () => {
      navigator.serviceWorker
        .register('offline_worker.js')
        .then(() => navigator.serviceWorker.ready)
        .then((registration) => {
          const loaded = performance.getEntriesByType('resource').map((entry) => entry.name);
          registration.active?.postMessage({ loaded });
        })
        .catch((e) => console.warn(`offline: the app is not kept for a load with no network (${e})`));
    },
    { once: true },
  );
}
