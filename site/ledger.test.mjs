// The terms and the privacy policy say what the newest entry in
// ledger.json says they do, and the ledger only grows (ledger.mjs).
//
//   node --test site/*.test.mjs
//
// Comparing with main needs main: `git fetch origin main` (CI does).
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

import { config, dayIn, languages, ledger, priceIn, render, strings } from './build.mjs';
import { DOCUMENTS, fingerprintOf, formatLedger, ledgerProblems, rewritten, textOf } from './ledger.mjs';

const root = new URL('..', import.meta.url).pathname;
const english = languages.find((l) => l.code === 'en');

test('the ledger is whole: each document begins with a first entry, and every entry is dated in order and complete', () => {
  assert.deepEqual(ledgerProblems(ledger()), []);
  const file = readFileSync(join(root, 'site/ledger.json'), 'utf8');
  assert.equal(file, formatLedger(JSON.parse(file)), 'written as ./oh terms writes it');
});

test('each document is word for word what its newest entry in the ledger fingerprints', () => {
  for (const doc of DOCUMENTS) {
    const newest = ledger()[doc].at(-1);
    assert.equal(
      fingerprintOf(doc),
      newest.fingerprint,
      `the ${doc} changed since their newest entry in site/ledger.json (${newest.date}): ./oh terms record ${doc} adds an entry for the change, or undo it`,
    );
  }
});

test('the terms state the price in config/openhearts.json, the one the shop sells at, and the app shows it', () => {
  assert.deepEqual(ledger().terms.at(-1).price, config().price);
  // The app's own, shown before a store's is known, and on the web.
  const buying = readFileSync(join(root, 'app/lib/net/buying.dart'), 'utf8');
  assert.equal(/^const priceAmount = r'([^']*)';$/m.exec(buying)?.[1], priceIn(english, config().price), 'app/lib/net/buying.dart, priceAmount');
});

test("no entry main has is taken out or changed, but a store's notice may be filled in", () => {
  let before;
  try {
    before = execFileSync('git', ['show', 'origin/main:site/ledger.json'], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    const said = String(e.stderr ?? '');
    // Main without a ledger yet: nothing to keep.
    if (/exists on disk, but not in|does not exist in/.test(said)) return;
    assert.fail(`cannot read main's ledger (git fetch origin main): ${said.trim()}`);
  }
  assert.deepEqual(rewritten(JSON.parse(before), ledger()), []);
});

test('"Last updated" is the newest entry\'s day, in each language', () => {
  const published = {
    terms: [{ date: '2026-03-01' }],
    privacy: [{ date: '2025-12-31' }],
  };
  const page = (doc, code) => render(doc, languages.find((l) => l.code === code), strings(code), { published });
  assert.match(page('terms', 'en'), /Last updated 1 March 2026/);
  assert.match(page('privacy', 'en'), /Last updated 31 December 2025/);
  assert.match(page('terms', 'de'), /Zuletzt aktualisiert am 1\. März 2026/);
  assert.match(page('terms', 'fr'), /Dernière mise à jour : 1er mars 2026/);
  assert.match(page('terms', 'es'), /1 de marzo de 2026/);
  assert.match(page('terms', 'pt'), /1 de março de 2026/);
});

test('the price is written as each language writes dollars, and only dollars', () => {
  const said = Object.fromEntries(languages.map((l) => [l.code, priceIn(l, { amount: 1205, currency: 'usd' })]));
  assert.deepEqual(said, { en: '$12.05', es: '12,05 US$', pt: 'US$ 12,05', de: '12,05 US$', fr: '12,05 $ US' });
  assert.throws(() => priceIn(english, { amount: 599, currency: 'eur' }), /currency/);
  assert.throws(() => priceIn(english, { amount: 5.99, currency: 'usd' }), /cents/);
  const home = render('index', english, strings('en'), { price: { amount: 1205, currency: 'usd' } });
  assert.match(home, /\$12\.05 a year/);
  const terms = render('terms', english, strings('en'), { price: { amount: 1205, currency: 'usd' } });
  assert.match(terms, /costs \$12\.05 a year/);
  assert.equal(dayIn(english, '2026-10-16'), '16 October 2026');
});

test('a price in the config is a change to the terms', () => {
  const now = fingerprintOf('terms');
  assert.notEqual(fingerprintOf('terms', { price: { amount: 699, currency: 'usd' } }), now);
  assert.equal(fingerprintOf('terms', { price: config().price }), now);
});

test("the text is what is read and where its links go, not how it looks", () => {
  const page = (main) => `<html><head><title>x</title></head><body><header>Last updated today</header><main id="main" class="wrap">${main}</main></body></html>`;
  const said = textOf(page('<!-- an icon --><section><h2>Refunds</h2>\n  <p>See <a href="/support#cancel" class="x">how to cancel</a>.</p><svg viewBox="0 0 1 1"><path d="M0"/></svg></section>'));
  assert.equal(said, 'Refunds See [/support#cancel] how to cancel .');
  assert.equal(textOf(page('<section><h3>Refunds</h3><p>See <a class="y" href="/support#cancel">how to cancel</a>.</p></section>')), said, 'markup and order of attributes aside');
  assert.notEqual(textOf(page('<p>See <a href="/support#refund">how to cancel</a>.</p>')), said, 'a link moved is a change');
  assert.throws(() => textOf('<html><body>no main</body></html>'), /no <main>/);
});

/// A whole entry, for the tests below to spoil.
const entry = (date, change, more = {}) => ({
  date,
  fingerprint: 'a'.repeat(64),
  change,
  price: { amount: 599, currency: 'usd' },
  storesNotified: null,
  summary: Object.fromEntries(languages.map((l) => [l.code, 'What changed.'])),
  ...more,
});
const privacyEntry = (date, change, more = {}) => {
  const { price, ...rest } = entry(date, change, more);
  return rest;
};

test('an entry out of order, or not whole, or mislabelled, is said', () => {
  const good = { terms: [entry('2026-10-16', 'first'), entry('2026-11-01', 'material')], privacy: [privacyEntry('2026-10-13', 'first')] };
  assert.deepEqual(ledgerProblems(good), []);
  const spoilt = (doc, i, more) => {
    const l = structuredClone(good);
    l[doc][i] = { ...l[doc][i], ...more };
    return ledgerProblems(l);
  };
  assert.match(spoilt('terms', 1, { date: '2026-10-16' }).join(), /not after the entry before/);
  assert.match(spoilt('terms', 1, { date: '2026-02-30' }).join(), /not a day/);
  assert.match(spoilt('terms', 1, { change: 'first' }).join(), /only the first entry/);
  assert.match(spoilt('terms', 0, { change: 'minor' }).join(), /only the first entry/);
  assert.match(spoilt('terms', 1, { change: 'big' }).join(), /change is one of/);
  assert.match(spoilt('terms', 1, { fingerprint: 'abc' }).join(), /64 hex/);
  assert.match(spoilt('terms', 1, { storesNotified: 'soon' }).join(), /storesNotified/);
  assert.match(spoilt('terms', 1, { summary: { en: 'x' } }).join(), /no summary in es/);
  assert.match(spoilt('terms', 1, { summary: { ...good.terms[1].summary, de: '<b>neu</b>' } }).join(), /plain text/);
  assert.match(spoilt('terms', 1, { summary: { ...good.terms[1].summary, fr: 'x'.repeat(281) } }).join(), /fr summary is 281 characters; the app shows 280/);
  assert.deepEqual(spoilt('terms', 1, { summary: { ...good.terms[1].summary, fr: 'x'.repeat(280) } }), []);
  assert.match(spoilt('terms', 1, { price: { amount: 699, currency: 'usd' } }).join(), /the price changed, so the change is "price"/);
  assert.match(spoilt('terms', 1, { change: 'price' }).join(), /the price is the one before/);
  assert.deepEqual(spoilt('terms', 1, { change: 'price', price: { amount: 699, currency: 'usd' } }), []);
  const priceless = structuredClone(good);
  delete priceless.terms[1].price;
  assert.match(ledgerProblems(priceless).join(), /has change, date, fingerprint, storesNotified, summary/);
  assert.match(spoilt('privacy', 0, { price: { amount: 599, currency: 'usd' } }).join(), /wants change, date, fingerprint, storesNotified, summary/);
  assert.match(ledgerProblems({ ...good, privacy: [] }).join(), /privacy: no entries/);
  assert.match(ledgerProblems({ ...good, cookies: [] }).join(), /no such document as cookies/);
});

test('the ledger only grows: an entry may be added, and a store notice filled in once, and nothing else', () => {
  const main = { terms: [entry('2026-10-16', 'first'), entry('2026-11-01', 'material')], privacy: [privacyEntry('2026-10-13', 'first')] };
  const now = structuredClone(main);
  now.terms.push(entry('2026-12-01', 'minor'));
  now.terms[1].storesNotified = '2026-10-30';
  assert.deepEqual(rewritten(main, now), []);
  const notified = structuredClone(now);
  const again = structuredClone(now);
  again.terms[1].storesNotified = '2026-10-31';
  assert.deepEqual(rewritten(notified, again), ['terms 2026-11-01: changed'], 'filled in once');
  assert.deepEqual(rewritten(notified, notified), [], 'and then kept');
  const edited = structuredClone(main);
  edited.terms[1].fingerprint = 'b'.repeat(64);
  assert.deepEqual(rewritten(main, edited), ['terms 2026-11-01: changed']);
  const shortened = structuredClone(main);
  shortened.terms.pop();
  assert.deepEqual(rewritten(main, shortened), ['terms 2026-11-01: taken out']);
});
