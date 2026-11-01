// The device brought along from where the app used to be.
//
// The app was served at openhearts.game/play/ and is now served at
// play.openhearts.game (docs/explanation/service.md, "Where the app is"). What
// makes a device itself — its secret key, its licence, its name and
// picture, its records and settings — is in the browser's storage under
// `flutter.*`, and storage is per origin: at the new address a device
// that has played for a year would be a stranger, and a subscriber's
// device a device of nobody's account.
//
// So on a load with no key yet, before Dart reads anything, this asks
// the old origin for its `flutter.*` entries through a hidden frame of
// openhearts.game/carry (site/public/carry.html), which answers this
// origin and no other, and only when asked. The two are the same site,
// so the frame reads the old origin's own storage rather than a
// partitioned copy. What comes back is written only while there is
// still no key here, and never over an entry already here; the old
// origin's copy is left as it is, for a rollback. The answer is waited
// for a moment and no longer: the app boots whatever happens, and a
// device with nothing to bring along makes its key as it always did.
//
// window.ohCarried is the promise flutter_bootstrap.js waits on, and it
// resolves to what came of it: 'carried', 'nothing' (asked, and the old
// origin had nothing), 'kept' (a key is here already, the carry was done
// before, or the device was started afresh), 'timed out', 'not here' (no
// older origin to ask: a preview, a local run) or 'failed'.
(() => {
  'use strict';
  const KEY = 'flutter.identity_secret';
  const DONE = 'oh.carried';
  const AFRESH = 'flutter.device_started_afresh';
  // How long the old origin's page may take to arrive, and then how long
  // it may take to answer. Giving up early costs a subscriber their
  // device — the app makes a key of its own, and with a key here the
  // carry is never tried again — while waiting costs only a slow first
  // load: a page that has nothing to carry answers in a few dozen
  // milliseconds after it loads. So the network gets long, and the
  // answer, once the page is there, does not.
  const LOAD_MS = 10000;
  const ANSWER_MS = 2000;

  // Where the app used to be, for where it is now: production's own,
  // spelled out, and the browser rig's stand-in for it (e2e/drive.mjs).
  function siteOf(location) {
    if (location.hostname === 'play.openhearts.game' && location.protocol === 'https:') return 'https://openhearts.game';
    if (/^play\.[a-z0-9-]+\.localhost$/.test(location.hostname)) {
      return `${location.protocol}//${location.host.slice('play.'.length)}`;
    }
    return null;
  }

  function write(storage, entries) {
    // Another tab may have made a key while this one waited.
    if (storage.getItem(KEY) !== null) return 'kept';
    let carried = 0;
    for (const [k, v] of Object.entries(entries)) {
      if (!k.startsWith('flutter.') || typeof v !== 'string' || storage.getItem(k) !== null) continue;
      storage.setItem(k, v);
      carried++;
    }
    storage.setItem(DONE, JSON.stringify({ at: new Date().toISOString(), entries: carried }));
    return carried ? 'carried' : 'nothing';
  }

  function carry() {
    const site = siteOf(window.location);
    if (!site) return Promise.resolve('not here');
    const storage = window.localStorage;
    // A device started afresh after its account was deleted
    // (app/lib/start_afresh.dart) is not brought back from the old one.
    if (storage.getItem(KEY) !== null || storage.getItem(DONE) !== null || storage.getItem(AFRESH) !== null) return Promise.resolve('kept');
    return new Promise((resolve) => {
      const frame = document.createElement('iframe');
      let timer = null;
      const finish = (outcome) => {
        clearTimeout(timer);
        window.removeEventListener('message', heard);
        frame.remove();
        resolve(outcome);
      };
      const heard = (event) => {
        if (event.origin !== site || event.source !== frame.contentWindow) return;
        const data = event.data;
        if (!data || data.type !== 'oh-carry/entries' || typeof data.entries !== 'object' || data.entries === null) return;
        let outcome;
        try {
          outcome = write(storage, data.entries);
        } catch (_) {
          outcome = 'failed';
        }
        finish(outcome);
      };
      window.addEventListener('message', heard);
      // Asked once the frame has loaded, and addressed to the old
      // origin: a frame that ended up anywhere else is never told.
      frame.addEventListener('load', () => {
        clearTimeout(timer);
        timer = setTimeout(() => finish('timed out'), ANSWER_MS);
        frame.contentWindow?.postMessage({ type: 'oh-carry/ask' }, site);
      });
      frame.setAttribute('aria-hidden', 'true');
      frame.tabIndex = -1;
      frame.title = '';
      frame.style.display = 'none';
      frame.src = `${site}/carry`;
      timer = setTimeout(() => finish('timed out'), LOAD_MS);
      (document.body ?? document.documentElement).appendChild(frame);
    });
  }

  let started;
  try {
    started = carry();
  } catch (_) {
    started = Promise.resolve('failed');
  }
  window.ohCarried = started.catch(() => 'failed');
})();
