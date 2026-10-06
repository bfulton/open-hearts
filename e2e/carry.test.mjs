// app/web/carry.js, in a pretend page: who it asks, whose answer it
// takes, and what it writes. e2e/move.mjs drives the real thing in
// Chromium; this holds the edges a browser run does not reach.
//
//   node --test e2e/carry.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../app/web/carry.js', import.meta.url), 'utf8');

class Storage {
  constructor(entries = {}) {
    this.map = new Map(Object.entries(entries));
  }
  getItem(k) {
    return this.map.has(k) ? this.map.get(k) : null;
  }
  setItem(k, v) {
    this.map.set(k, String(v));
  }
}

/// Runs carry.js at [href] with [storage]; returns the page's pieces and
/// what the frame was asked.
function load(href, storage, { wait = 1500 } = {}) {
  const listeners = new Set();
  const frames = [];
  const timers = [];
  const window = {
    location: new URL(href),
    localStorage: storage,
    addEventListener: (type, fn) => type === 'message' && listeners.add(fn),
    removeEventListener: (type, fn) => type === 'message' && listeners.delete(fn),
  };
  const document = {
    body: {
      appendChild(frame) {
        frames.push(frame);
        frame.contentWindow = { asked: [], postMessage: (data, origin) => frame.contentWindow.asked.push({ data, origin }) };
        frame.onload?.();
      },
    },
    createElement: () => {
      const frame = {
        style: {},
        setAttribute() {},
        remove() {
          frame.removed = true;
        },
        addEventListener(type, fn) {
          if (type === 'load') frame.onload = fn;
        },
      };
      return frame;
    },
  };
  const context = {
    window,
    document,
    setTimeout: (fn, ms) => (timers.push({ fn, ms }), timers.length),
    clearTimeout: (id) => id && (timers[id - 1].fn = null),
    Promise,
    JSON,
    Date,
    Object,
  };
  vm.runInNewContext(source, context);
  const say = (origin, source, data) => {
    for (const fn of [...listeners]) fn({ origin, source, data });
  };
  const expire = () => timers.forEach((t) => t.fn?.());
  return { window, frames, say, expire, timers, listeners };
}

const KEY = 'flutter.identity_secret';
const key = JSON.stringify('cd'.repeat(32));

test('at play.openhearts.game with no key: asks openhearts.game/carry, and only it', async () => {
  const page = load('https://play.openhearts.game/room/ABCD2345', new Storage());
  assert.equal(page.frames.length, 1);
  const [frame] = page.frames;
  assert.equal(frame.src, 'https://openhearts.game/carry');
  assert.equal(frame.style.display, 'none');
  assert.deepEqual(JSON.parse(JSON.stringify(frame.contentWindow.asked)), [{ data: { type: 'oh-carry/ask' }, origin: 'https://openhearts.game' }]);
  assert.equal(page.timers[0].ms, 1500);
  page.expire();
  assert.equal(await page.window.ohCarried, 'timed out');
});

test("an answer from anyone but that frame at that origin is not taken", async () => {
  const storage = new Storage();
  const page = load('https://play.openhearts.game/', storage);
  const [frame] = page.frames;
  const entries = { [KEY]: key };
  page.say('https://evil.example', frame.contentWindow, { type: 'oh-carry/entries', entries });
  page.say('https://openhearts.game', {}, { type: 'oh-carry/entries', entries });
  page.say('https://openhearts.game.evil.example', frame.contentWindow, { type: 'oh-carry/entries', entries });
  page.say('https://openhearts.game', frame.contentWindow, { type: 'something else', entries });
  assert.equal(storage.getItem(KEY), null);
  page.say('https://openhearts.game', frame.contentWindow, { type: 'oh-carry/entries', entries });
  assert.equal(await page.window.ohCarried, 'carried');
  assert.equal(storage.getItem(KEY), key);
  assert.equal(frame.removed, true);
  assert.equal(page.listeners.size, 0);
});

test('only flutter.* strings are written, never over what is here, and the carry is marked', async () => {
  const storage = new Storage({ 'flutter.language': '"de"' });
  const page = load('https://play.openhearts.game/', storage);
  page.say('https://openhearts.game', page.frames[0].contentWindow, {
    type: 'oh-carry/entries',
    entries: { [KEY]: key, 'flutter.language': '"fr"', 'flutter.licence': 'L', other: 'x', 'flutter.n': 5 },
  });
  assert.equal(await page.window.ohCarried, 'carried');
  assert.equal(storage.getItem(KEY), key);
  assert.equal(storage.getItem('flutter.language'), '"de"');
  assert.equal(storage.getItem('flutter.licence'), 'L');
  assert.equal(storage.getItem('other'), null);
  assert.equal(storage.getItem('flutter.n'), null);
  assert.equal(JSON.parse(storage.getItem('oh.carried')).entries, 2);
});

test('a key made here while the answer was on its way is kept', async () => {
  const storage = new Storage();
  const page = load('https://play.openhearts.game/', storage);
  storage.setItem(KEY, JSON.stringify('ef'.repeat(32)));
  page.say('https://openhearts.game', page.frames[0].contentWindow, { type: 'oh-carry/entries', entries: { [KEY]: key, 'flutter.identity_name': '"M"' } });
  assert.equal(await page.window.ohCarried, 'kept');
  assert.equal(storage.getItem(KEY), JSON.stringify('ef'.repeat(32)));
  assert.equal(storage.getItem('flutter.identity_name'), null);
});

test('nothing asked with a key here, after a carry, on a preview, or anywhere else', async () => {
  for (const [href, storage, outcome] of [
    ['https://play.openhearts.game/', new Storage({ [KEY]: key }), 'kept'],
    ['https://play.openhearts.game/', new Storage({ 'oh.carried': '{}' }), 'kept'],
    ['https://dev.open-hearts.pages.dev/play/', new Storage(), 'not here'],
    ['https://openhearts.game/play/', new Storage(), 'not here'],
    ['http://play.openhearts.game/', new Storage(), 'not here'],
    ['https://play.evil.example/', new Storage(), 'not here'],
  ]) {
    const page = load(href, storage);
    assert.equal(page.frames.length, 0, href);
    assert.equal(await page.window.ohCarried, outcome, href);
  }
});

test("the rig's stand-in asks its own site's stand-in, port and all", () => {
  const page = load('http://play.openhearts.localhost:8123/', new Storage());
  assert.equal(page.frames[0].src, 'http://openhearts.localhost:8123/carry');
  assert.equal(page.frames[0].contentWindow.asked[0].origin, 'http://openhearts.localhost:8123');
});
