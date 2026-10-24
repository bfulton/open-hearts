// oh terms, and what a production deploy is held to by the ledger
// (ops/terms.mjs): which version the site serves, read off the site; a
// change recorded, and the stores' notice; and web subscribers told of
// a published change, once each, when the operator says so and never
// by a deploy.
//
//   node --test ops/*.test.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { main } from './oh.mjs';
import { releaseProblems } from './gate.mjs';
import { plainTextOf, termsProblems, untold } from './terms.mjs';
import { config, languages, origin, render, stores, strings } from '../site/build.mjs';
import { fingerprintOf, fingerprintOfTexts, formatLedger, textOf } from '../site/ledger.mjs';
import { memoryStore } from '../service/functions/rows.mjs';

const DAY = 86400000;
const now = Date.parse('2026-11-02T15:00:00Z');
const price = config().price;
const summary = (what) => Object.fromEntries(languages.map((l) => [l.code, `${what} (${l.code}).`]));

/// [doc] as the site would serve it in [code]: this checkout's, or
/// with an old clause in it, which is another version.
const page = (doc, code, old = false) => {
  const html = render(doc, languages.find((l) => l.code === code), strings(code));
  return old ? html.replace('</main>', '<p>An old clause.</p></main>') : html;
};
const fingerprintServed = (doc, old) => fingerprintOfTexts(Object.fromEntries(languages.map((l) => [l.code, textOf(page(doc, l.code, old))])));

/// A ledger whose terms were [old] before their newest entry, a
/// [change] of [date]; the privacy policy has the one entry.
function ledgerWith({ change = 'material', date = '2026-11-02', storesNotified = null } = {}) {
  return {
    terms: [
      { date: '2026-10-16', fingerprint: fingerprintServed('terms', true), change: 'first', price, storesNotified: null, summary: summary('Where it begins') },
      { date, fingerprint: fingerprintOf('terms'), change, price, storesNotified, summary: summary('Refunds end the subscription') },
    ],
    privacy: [{ date: '2026-10-13', fingerprint: fingerprintOf('privacy'), change: 'first', storesNotified: null, summary: summary('Where it begins') }],
  };
}

const ledgerFile = (ledger) => {
  const file = join(mkdtempSync(join(tmpdir(), 'ledger-')), 'ledger.json');
  writeFileSync(file, formatLedger(ledger));
  return file;
};

/// The site, serving the terms as old ([old]) and the privacy policy as
/// this checkout has it unless [oldPrivacy]; the service, answering notice orders with
/// [answer]; Stripe, with [subs].
function context({ ledger, old = true, oldPrivacy = false, subs = [], answer = null, env = { STRIPE_API_KEY: 'rk', CLOUDFLARE_API_TOKEN: 't', CLOUDFLARE_ACCOUNT_ID: 'a' }, mainLedger = null, store = memoryStore() }) {
  const said = [];
  const orders = [];
  const file = ledgerFile(ledger);
  return {
    said,
    orders,
    file,
    env,
    ledgerFile: file,
    log: (line) => said.push(line),
    warn: (line) => said.push(`oh: ${line}`),
    now: () => now,
    config: async () => config(),
    store: async () => Object.assign(store, { under: async (pk, prefix) => [...store.rows.keys()].filter((k) => k.startsWith(`${pk}|${prefix}`)).map((k) => k.slice(pk.length + 1)) }),
    stripe: () => ({
      get: async (path) => {
        assert.match(path, /^\/subscriptions\?status=all&limit=100/);
        return { data: subs, has_more: false };
      },
    }),
    capture: async (command, args) => (mainLedger && args[1] === 'origin/main:site/ledger.json' ? { code: 0, out: JSON.stringify(mainLedger) } : { code: 128, out: '' }),
    carryOptions: { tries: 3, wait: 0 },
    fetch: async (url, init) => {
      if (String(url).endsWith('/api/order')) {
        const id = JSON.parse(init.body).order;
        const order = await store.get(`ORDER#${id}`, 'META');
        orders.push(order);
        for (const s of order.subscriptions) {
          for (const c of order.changes) for (const version of [c.version, ...c.covers]) await store.put(`NOTICE#${c.document}@${version}`, `SUB#${s}`, { at: 'now' });
        }
        return Response.json(answer ?? { act: 'notice', told: order.subscriptions.length, already: 0, unsent: {}, failed: 0 });
      }
      const m = new RegExp(`^${origin}(?:/(es|pt|de|fr))?/(terms|privacy)$`).exec(String(url));
      if (!m) return new Response('no', { status: 404 });
      const [, code = 'en', doc] = m;
      return new Response(page(doc, code, doc === 'terms' ? old : oldPrivacy));
    },
  };
}

test('the site serves the version it serves: a deploy publishes what comes after it, dated today', async () => {
  const ctx = context({ ledger: ledgerWith() });
  const { problems, publishing } = await termsProblems(ctx);
  assert.deepEqual(problems, []);
  assert.deepEqual(publishing.map(({ document, entry }) => `${document} ${entry.date} ${entry.change}`), ['terms 2026-11-02 material']);

  const stale = await termsProblems(context({ ledger: ledgerWith({ date: '2026-10-30' }) }));
  assert.match(stale.problems.join('\n'), /would go live today \(2026-11-02\) saying they were last updated 2026-10-30: date their newest entry today/);
  assert.deepEqual((await termsProblems(context({ ledger: ledgerWith({ date: '2026-11-01' }) }))).problems, [], 'yesterday, in UTC, is today west of it');

  const nothing = await termsProblems(context({ ledger: ledgerWith(), old: false }));
  assert.deepEqual(nothing, { problems: [], publishing: [] }, 'what is live is the newest: nothing to publish, and no date to hold to');
});

test('an entry that repeats the text of the one before it, to publish it on a later day: the live one is the one the page is dated by', async () => {
  const ledger = ledgerWith({ date: '2026-10-19' });
  ledger.terms.push({ ...ledger.terms[1], date: '2026-11-02', change: 'minor', summary: summary('Published later, unchanged') });
  // The site, serving the terms as built when [newest] was their newest
  // entry; Stripe, with [subs].
  const dated = (newest, subs = []) => {
    const ctx = context({ ledger, old: false, subs });
    const served = ctx.fetch;
    ctx.fetch = async (url, init) => {
      const m = new RegExp(`^${origin}(?:/(es|pt|de|fr))?/terms$`).exec(String(url));
      if (!m) return served(url, init);
      const code = m[1] ?? 'en';
      return new Response(render('terms', languages.find((l) => l.code === code), strings(code), { published: { ...ledger, terms: ledger.terms.slice(0, newest + 1) } }));
    };
    return ctx;
  };
  const before = await termsProblems(dated(1));
  assert.deepEqual(before.problems, []);
  assert.deepEqual(before.publishing.map(({ document, entry }) => `${document} ${entry.date} ${entry.change}`), ['terms 2026-11-02 minor']);
  assert.deepEqual(await termsProblems(dated(2)), { problems: [], publishing: [] }, 'published: nothing left to publish');
  // Subscribers are told of the change of 2026-10-19, as published on
  // 2026-11-02, which its page says.
  const [told] = await untold(dated(2));
  assert.deepEqual([told.entry.date, told.day], ['2026-10-19', '2026-11-02']);
  const ctx = dated(2, subscriptions(['sub_1', 'active', 30]));
  await main(['terms', 'notify'], ctx);
  assert.match(ctx.said.join('\n'), /We have changed the Open Hearts terms of use, on 2026-11-02\./);
});

test('no deploy emails anyone: a change subscribers are told of is published without Stripe, and no deploy script tells them', async () => {
  const ctx = context({ ledger: ledgerWith(), env: {} });
  assert.deepEqual((await termsProblems(ctx)).problems, []);
  for (const script of ['deploy.sh', 'service/bench/build.sh']) {
    assert.doesNotMatch(readFileSync(new URL(`../${script}`, import.meta.url), 'utf8'), /terms\s+notify/, script);
  }
});

test('while an app is in its store, a material change goes out only once the stores were told of it', async () => {
  assert.deepEqual((await termsProblems(context({ ledger: ledgerWith() }))).problems, [], 'no app listed: nobody to tell');
  stores.appStore = 'https://apps.apple.com/app/open-hearts/id1';
  try {
    assert.match((await termsProblems(context({ ledger: ledgerWith() }))).problems.join('\n'), /the terms of 2026-11-02 are a material change: tell the App Store and Google Play first, and record the day \(\.\/oh terms notified terms\)/);
    assert.deepEqual((await termsProblems(context({ ledger: ledgerWith({ storesNotified: '2026-10-30' }) }))).problems, []);
    assert.deepEqual((await termsProblems(context({ ledger: ledgerWith({ change: 'minor' }) }))).problems, [], 'a minor change is not theirs to hear of');
  } finally {
    stores.appStore = null;
  }
});

test('a site serving what the ledger never had, or not answering, stops the deploy', async () => {
  const ledger = ledgerWith();
  ledger.terms[0].fingerprint = 'f'.repeat(64);
  assert.match((await termsProblems(context({ ledger }))).problems.join('\n'), /which terms are live cannot be told: the site serves a version \([0-9a-f]{12}…\) that is no entry in site\/ledger\.json/);
  const down = context({ ledger: ledgerWith() });
  down.fetch = async () => new Response('down', { status: 503 });
  assert.match((await termsProblems(down)).problems.join('\n'), /cannot be told: https:\/\/openhearts\.game\/terms: answered 503/);
});

test('this checkout is held to the ledger: its newest entry, and the price in the config', async () => {
  const ledger = ledgerWith();
  ledger.terms[1].fingerprint = 'e'.repeat(64);
  assert.match((await termsProblems(context({ ledger }))).problems.join('\n'), /the terms here are not what their newest entry in site\/ledger\.json says/);
  const priced = ledgerWith({ change: 'price' });
  priced.terms[1].price = { amount: price.amount + 100, currency: 'usd' };
  assert.match((await termsProblems(context({ ledger: priced }))).problems.join('\n'), /another price than config\/openhearts\.json/);
  const broken = ledgerWith();
  broken.terms[1].summary.de = '';
  assert.match((await termsProblems(context({ ledger: broken }))).problems.join('\n'), /site\/ledger\.json: terms 2026-11-02: no summary in de/);
});

test('the gate holds the site to the ledger and the relay not', async () => {
  const ctx = context({ ledger: ledgerWith({ date: '2026-10-20' }) });
  ctx.capture = async (command, args) => ({ code: 0, out: args[0] === 'rev-parse' ? 'abc\n' : '' });
  assert.match((await releaseProblems(ctx, 'site')).join('\n'), /saying they were last updated 2026-10-20/);
  assert.deepEqual(await releaseProblems(ctx, 'relay'), []);
});

test('record: a new entry for what this checkout says, the summaries left to write; then that entry kept up to date', async () => {
  const before = ledgerWith({ change: 'minor', date: '2026-10-20' });
  before.terms[1].fingerprint = 'c'.repeat(64);
  const ctx = context({ ledger: before, mainLedger: before });
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'material'], ctx), 0);
  assert.deepEqual(JSON.parse(readFileSync(ctx.file, 'utf8')), before, 'a dry run writes nothing');
  assert.match(ctx.said.join('\n'), /would add the terms' entry of 2026-11-02: material, [0-9a-f]{12}…, 599 usd/);
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'material', '--apply'], ctx), 0);
  const written = JSON.parse(readFileSync(ctx.file, 'utf8'));
  assert.equal(written.terms.length, 3);
  assert.deepEqual(written.terms[2], { date: '2026-11-02', fingerprint: fingerprintOf('terms'), change: 'material', price, storesNotified: null, summary: Object.fromEntries(languages.map((l) => [l.code, ''])) });
  assert.match(ctx.said.join('\n'), /now write what changed, in each language/);

  // Main has two entries, so the third is this branch's: the text
  // unchanged, there is nothing to record; dated again, it is brought up
  // to date rather than another added.
  written.terms[2].summary = summary('Refunds end the subscription');
  const again = context({ ledger: written, mainLedger: before });
  again.now = () => now + DAY;
  assert.equal(await main(['terms', 'record', 'terms', '--apply'], again), 0);
  assert.match(again.said.join('\n'), /nothing to record/);
  assert.equal(await main(['terms', 'record', 'terms', '--date', '2026-11-03', '--apply'], again), 0);
  const kept = JSON.parse(readFileSync(again.file, 'utf8'));
  assert.equal(kept.terms.length, 3);
  assert.equal(kept.terms[2].date, '2026-11-03');
  assert.equal(kept.terms[2].change, 'material', 'its kind kept');
  assert.deepEqual(kept.terms[2].summary, summary('Refunds end the subscription'), 'and what was written of it');
});

test('record: where the ledger begins is never rewritten, even before main has a ledger', async () => {
  const first = ledgerWith();
  first.terms = [{ ...first.terms[0], fingerprint: 'c'.repeat(64) }];
  const ctx = context({ ledger: first, mainLedger: null });
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'material', '--date', '2026-11-02', '--apply'], ctx), 0);
  const written = JSON.parse(readFileSync(ctx.file, 'utf8')).terms;
  assert.equal(written.length, 2, 'added after the first, not in its place');
  assert.deepEqual(written[0], first.terms[0]);
});

test('record: says what is missing, and never dates an entry before the one it follows', async () => {
  const ledger = ledgerWith({ change: 'minor', date: '2026-11-02' });
  ledger.terms[1].fingerprint = 'c'.repeat(64);
  const ctx = context({ ledger, mainLedger: ledger });
  assert.equal(await main(['terms', 'record', 'terms'], ctx), 2, 'no kind of change');
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'material', '--date', '2026-11-01'], ctx), 1, 'the day before the one before');
  assert.match(ctx.said.join('\n'), /the entry would be dated 2026-11-01, before the one it follows \(2026-11-02\): --date/);
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'big'], ctx), 2);
  assert.equal(await main(['terms', 'record', 'cookies', '--change', 'minor'], ctx), 2);
  const same = context({ ledger: ledgerWith(), mainLedger: ledgerWith() });
  assert.equal(await main(['terms', 'record', 'privacy'], same), 0);
  assert.match(same.said.join('\n'), /the privacy are as their newest entry \(2026-10-13\) says: nothing to record/);
});

test("record: a second version the same day is the day's next revision, on main's entry or on this branch's own", async () => {
  const before = ledgerWith({ change: 'minor' });
  before.terms[1].fingerprint = 'c'.repeat(64);
  const ctx = context({ ledger: before, mainLedger: before });
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'material'], ctx), 0);
  assert.match(ctx.said.join('\n'), /would add the terms' entry of 2026-11-02\.2 \(the day's revision 2\): material/);
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'material', '--apply'], ctx), 0);
  const written = JSON.parse(readFileSync(ctx.file, 'utf8'));
  assert.deepEqual(written.terms.slice(0, 2), before.terms, 'the day\'s first kept as main has it');
  assert.deepEqual(written.terms[2], { date: '2026-11-02', revision: 2, fingerprint: fingerprintOf('terms'), change: 'material', price, storesNotified: null, summary: Object.fromEntries(languages.map((l) => [l.code, ''])) });

  // This branch's own entry, of a later day, dated again to the day of
  // main's newest: brought up to date as that day's revision.
  const later = structuredClone(before);
  later.terms.push({ date: '2026-11-03', fingerprint: fingerprintOf('terms'), change: 'material', price, storesNotified: null, summary: summary('Refunds end the subscription') });
  const own = context({ ledger: later, mainLedger: before });
  assert.equal(await main(['terms', 'record', 'terms', '--date', '2026-11-02', '--apply'], own), 0);
  const kept = JSON.parse(readFileSync(own.file, 'utf8'));
  assert.equal(kept.terms.length, 3);
  assert.deepEqual([kept.terms[2].date, kept.terms[2].revision, kept.terms[2].change], ['2026-11-02', 2, 'material']);
  assert.deepEqual(kept.terms[2].summary, summary('Refunds end the subscription'), 'what was written of it kept');

  // And the day's next after that one is on main.
  const third = context({ ledger: { ...written, terms: [...written.terms.slice(0, 2), { ...written.terms[2], fingerprint: 'd'.repeat(64) }] }, mainLedger: written });
  assert.equal(await main(['terms', 'record', 'terms', '--change', 'minor'], third), 0);
  assert.match(third.said.join('\n'), /would add the terms' entry of 2026-11-02\.3 \(the day's revision 3\): minor/);
});

test('notified: the stores\' day on the newest material change, once, and never a day to come', async () => {
  const ctx = context({ ledger: ledgerWith() });
  assert.equal(await main(['terms', 'notified', 'terms', '--on', '2026-11-01', '--apply'], ctx), 0);
  assert.equal(JSON.parse(readFileSync(ctx.file, 'utf8')).terms[1].storesNotified, '2026-11-01');
  assert.equal(await main(['terms', 'notified', 'terms', '--on', '2026-11-02', '--apply'], context({ ledger: JSON.parse(readFileSync(ctx.file, 'utf8')) })), 0);
  assert.equal(await main(['terms', 'notified', 'terms', '--on', '2026-11-03', '--apply'], context({ ledger: ledgerWith() })), 2, 'not yet');
  assert.equal(await main(['terms', 'notified', 'privacy', '--apply'], context({ ledger: ledgerWith() })), 1, 'nothing material to tell of');
  const revised = ledgerWith();
  revised.terms[1].fingerprint = 'c'.repeat(64);
  revised.terms.push({ ...revised.terms[1], revision: 2, fingerprint: fingerprintOf('terms') });
  const day = context({ ledger: revised });
  assert.equal(await main(['terms', 'notified', 'terms', '--on', '2026-11-01', '--apply'], day), 0);
  assert.match(day.said.join('\n'), /told of the terms of 2026-11-02\.2 on 2026-11-01/);
  assert.deepEqual(JSON.parse(readFileSync(day.file, 'utf8')).terms.map((e) => e.storesNotified), [null, null, '2026-11-01'], "on the day's newest version, not its first");
});

/// Stripe's subscriptions: [id, status, start (days before the change)].
const subscriptions = (...rows) => rows.map(([id, status, before]) => ({ id, status, start_date: Date.parse('2026-11-02T00:00:00Z') / 1000 - before * 86400 }));

test('notify: each subscription begun before a published change is told once, a few to an order; a dry run tells nobody', async () => {
  const subs = subscriptions(
    ...Array.from({ length: 12 }, (_, i) => [`sub_${i}`, 'active', 30]),
    ['sub_trial', 'trialing', 1],
    ['sub_late', 'past_due', 200],
    ['sub_gone', 'canceled', 30],
    ['sub_new', 'active', -1],
  );
  const store = memoryStore();
  await store.put('NOTICE#terms@2026-11-02', 'SUB#sub_0', { at: 'before' });
  const ctx = context({ ledger: ledgerWith(), old: false, subs, store });
  assert.equal(await main(['terms', 'notify'], ctx), 0);
  assert.deepEqual(ctx.orders, []);
  assert.match(ctx.said.join('\n'), /the terms of 2026-11-02 \(material\): 14 web subscription\(s\) to tell, 1 told already/);

  assert.equal(await main(['terms', 'notify', '--apply'], ctx), 0);
  assert.deepEqual(ctx.orders.map((o) => o.subscriptions.length), [10, 3]);
  const named = ctx.orders.flatMap((o) => o.subscriptions);
  assert.ok(!named.includes('sub_0'), 'told already');
  assert.ok(!named.includes('sub_gone') && !named.includes('sub_new'), 'ended, or begun after the change');
  assert.ok(named.includes('sub_trial') && named.includes('sub_late'));
  assert.deepEqual(Object.keys(ctx.orders[0]).sort(), ['act', 'at', 'changes', 'subscriptions']);
  assert.equal(ctx.orders[0].act, 'notice');
  assert.deepEqual(ctx.orders[0].changes, [{ document: 'terms', version: '2026-11-02', covers: [] }]);

  const twice = context({ ledger: ledgerWith(), old: false, subs, store });
  assert.equal(await main(['terms', 'notify', '--apply'], twice), 0);
  assert.deepEqual(twice.orders, [], 'run again, nobody is told twice');
});

test('notify: one email to each subscriber, of every change they are owed, each document\'s newest saying the earlier too; the dry run shows it', async () => {
  const ledger = ledgerWith();
  ledger.privacy = [
    { date: '2026-10-13', fingerprint: fingerprintServed('privacy', true), change: 'first', storesNotified: null, summary: summary('Where it begins') },
    { date: '2026-10-20', fingerprint: 'c'.repeat(64), change: 'material', storesNotified: null, summary: summary('Pictures are checked') },
    { date: '2026-11-02', fingerprint: fingerprintOf('privacy'), change: 'material', storesNotified: null, summary: summary('Pictures are checked and kept') },
  ];
  const store = memoryStore();
  await store.put('NOTICE#terms@2026-11-02', 'SUB#sub_t', { at: 'before' });
  const subs = subscriptions(['sub_a', 'active', 30], ['sub_b', 'active', 30], ['sub_t', 'active', 30]);
  const ctx = context({ ledger, old: false, subs, store });
  assert.equal(await main(['terms', 'notify'], ctx), 0);
  assert.deepEqual(ctx.orders, [], 'a dry run tells nobody');
  const said = ctx.said.join('\n');
  assert.match(said, /the terms of 2026-11-02 \(material\): 3 web subscription\(s\) to tell, 1 told already/);
  assert.match(said, /the privacy of 2026-11-02 \(material\), saying what changed on 2026-10-20 too: 3 web subscription\(s\) to tell, 0 told already/);
  assert.match(said, /the email to 2 of them, as it reads in English .*\n\nSubject: Changes to the Open Hearts terms of use and privacy policy\n\nWe have changed the Open Hearts terms of use and privacy policy, on 2026-11-02\.\n\nTerms of use: Refunds end the subscription \(en\)\.\n/);
  assert.match(said, /Privacy policy: Pictures are checked and kept \(en\)\./);
  assert.doesNotMatch(said, /Pictures are checked \(en\)/, 'the earlier change is said by the newest');
  assert.match(said, /the email to 1 of them, as it reads in English .*\n\nSubject: Changes to the Open Hearts privacy policy\n/, 'told of the terms already');

  assert.equal(await main(['terms', 'notify', '--apply'], ctx), 0);
  const privacy = { document: 'privacy', version: '2026-11-02', covers: ['2026-10-20'] };
  assert.deepEqual(
    ctx.orders.map((o) => [o.changes, o.subscriptions]),
    [
      [[{ document: 'terms', version: '2026-11-02', covers: [] }, privacy], ['sub_a', 'sub_b']],
      [[privacy], ['sub_t']],
    ],
  );
  const twice = context({ ledger, old: false, subs, store });
  assert.equal(await main(['terms', 'notify', '--apply'], twice), 0);
  assert.deepEqual(twice.orders, [], 'run again, nobody is told twice');
});

test("notify: a day's later version is told to everyone, those told of the day's first too, saying what the earlier ones did", async () => {
  const ledger = ledgerWith({ change: 'minor' });
  ledger.privacy = [
    { date: '2026-10-13', fingerprint: fingerprintServed('privacy', true), change: 'first', storesNotified: null, summary: summary('Where it begins') },
    { date: '2026-11-02', fingerprint: 'c'.repeat(64), change: 'material', storesNotified: null, summary: summary('Pictures are checked') },
    { date: '2026-11-02', revision: 2, fingerprint: 'd'.repeat(64), change: 'material', storesNotified: null, summary: summary('Pictures are checked, and kept') },
    { date: '2026-11-02', revision: 3, fingerprint: fingerprintOf('privacy'), change: 'material', storesNotified: null, summary: summary('Pictures are checked, and by whom') },
  ];
  const store = memoryStore();
  await store.put('NOTICE#privacy@2026-11-02', 'SUB#sub_first', { at: 'before' });
  const subs = subscriptions(['sub_first', 'active', 30], ['sub_new', 'active', 30]);
  const ctx = context({ ledger, old: false, subs, store });
  assert.equal(await main(['terms', 'notify'], ctx), 0);
  const said = ctx.said.join('\n');
  assert.match(said, /the privacy of 2026-11-02\.3 \(material\), saying what changed on 2026-11-02 and 2026-11-02\.2 too: 2 web subscription\(s\) to tell, 0 told already/);
  assert.match(said, /the email to 2 of them, as it reads in English .*\n\nSubject: Changes to the Open Hearts privacy policy\n\nWe have changed the Open Hearts privacy policy, on 2026-11-02\.\n\nPrivacy policy: Pictures are checked, and by whom \(en\)\./);
  assert.equal(await main(['terms', 'notify', '--apply'], ctx), 0);
  assert.deepEqual(ctx.orders.map((o) => [o.changes, o.subscriptions]), [[[{ document: 'privacy', version: '2026-11-02.3', covers: ['2026-11-02', '2026-11-02.2'] }], ['sub_first', 'sub_new']]]);
  const twice = context({ ledger, old: false, subs, store });
  assert.equal(await main(['terms', 'notify', '--apply'], twice), 0);
  assert.deepEqual(twice.orders, [], 'run again, nobody is told twice');
});

test("status: each version as it stands, and how many were told of each, a day's second apart from its first", async () => {
  const ledger = ledgerWith({ change: 'minor' });
  ledger.privacy = [
    { date: '2026-10-13', fingerprint: fingerprintServed('privacy', true), change: 'first', storesNotified: null, summary: summary('Where it begins') },
    { date: '2026-11-02', fingerprint: 'c'.repeat(64), change: 'material', storesNotified: null, summary: summary('Pictures are checked') },
    { date: '2026-11-02', revision: 2, fingerprint: fingerprintOf('privacy'), change: 'material', storesNotified: null, summary: summary('Pictures are checked, and by whom') },
  ];
  const store = memoryStore();
  for (const s of ['sub_1', 'sub_2']) await store.put('NOTICE#privacy@2026-11-02', `SUB#${s}`, { at: 'before' });
  await store.put('NOTICE#privacy@2026-11-02.2', 'SUB#sub_1', { at: 'now' });
  const ctx = context({ ledger, old: false, store });
  assert.equal(await main(['terms', 'status'], ctx), 0);
  const said = ctx.said.join('\n');
  assert.match(said, /privacy\n  newest entry: privacy 2026-11-02\.2 \(material; stores not told\)\n  this checkout: as the newest entry says\n  live: 2026-11-02\.2\n/);
  assert.match(said, /  published: privacy 2026-11-02 \(material; stores not told\); 2 web subscription\(s\) told\n  published: privacy 2026-11-02\.2 \(material; stores not told\); 1 web subscription\(s\) told/);
});

test('notify: nothing published to tell of is no failure; a notice that did not go is', async () => {
  const unpublished = context({ ledger: ledgerWith(), subs: subscriptions(['sub_1', 'active', 3]) });
  assert.equal(await main(['terms', 'notify', '--apply'], unpublished), 0);
  assert.match(unpublished.said.join('\n'), /no published change to tell subscribers of/);
  assert.deepEqual(unpublished.orders, [], 'not live yet: nobody is told of it');

  const old = ledgerWith({ date: '2026-08-01' });
  const long = context({ ledger: old, old: false, subs: subscriptions(['sub_1', 'active', 200]) });
  assert.equal(await main(['terms', 'notify', '--apply'], long), 0);
  assert.deepEqual(long.orders, [], 'past sixty days');

  const bounced = context({ ledger: ledgerWith(), old: false, subs: subscriptions(['sub_1', 'active', 3]), answer: { act: 'notice', told: 0, already: 0, unsent: {}, failed: 1 } });
  assert.equal(await main(['terms', 'notify', '--apply'], bounced), 1);
  assert.match(bounced.said.join('\n'), /1 notice\(s\) did not go: run \.\/oh terms notify --apply again/);
});

test('what is left to tell: each published change\'s web subscriptions, and those not told yet', async () => {
  const store = memoryStore();
  await store.put('NOTICE#terms@2026-11-02', 'SUB#sub_1', { at: 'before' });
  const subs = subscriptions(['sub_1', 'active', 3], ['sub_2', 'active', 3], ['sub_new', 'active', -1]);
  const [terms, ...rest] = await untold(context({ ledger: ledgerWith(), old: false, subs, store }));
  assert.deepEqual(rest, [], 'the privacy policy has no change to tell');
  assert.deepEqual([terms.document, terms.entry.date, terms.covers, terms.subscriptions, terms.left], ['terms', '2026-11-02', [], ['sub_1', 'sub_2'], ['sub_2']]);
  assert.deepEqual(await untold(context({ ledger: ledgerWith(), subs, store })), [], 'not published yet: nothing to tell');
  const unknown = context({ ledger: ledgerWith(), subs, store });
  unknown.fetch = async () => new Response('down', { status: 503 });
  await assert.rejects(untold(unknown), /which terms are live cannot be told: .*answered 503/);
});

test('oh verify fails while a published change has a web subscriber it was not emailed to', async () => {
  const store = memoryStore();
  await store.put('NOTICE#terms@2026-11-02', 'SUB#sub_1', { at: 'before' });
  const ctx = context({ ledger: ledgerWith(), old: false, subs: subscriptions(['sub_1', 'active', 3], ['sub_2', 'active', 3]), store });
  const site = ctx.fetch;
  // Production's other answers are no matter here.
  ctx.fetch = async (url, init) => (/\/(terms|privacy)$/.test(String(url)) ? site(url, init) : new Response('{}'));
  const line = () => ctx.said.find((l) => / the terms of 2026-11-02: /.test(l));
  assert.equal(await main(['verify'], ctx), 1);
  assert.equal(line(), 'FAILED the terms of 2026-11-02: 1 of 2 web subscription(s) told (./oh terms notify --apply)');
  await store.put('NOTICE#terms@2026-11-02', 'SUB#sub_2', { at: 'now' });
  ctx.said.length = 0;
  await main(['verify'], ctx);
  assert.equal(line(), 'ok     the terms of 2026-11-02: 2 of 2 web subscription(s) told');
  const without = context({ ledger: ledgerWith(), old: false, env: {} });
  without.fetch = ctx.fetch;
  await main(['verify'], without);
  assert.ok(without.said.includes('skipped the notices of changes to the terms: needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID and STRIPE_API_KEY'));
});

test('the licence agreement for the App Store: the terms as plain text, every word and every address', async () => {
  const ctx = context({ ledger: ledgerWith() });
  assert.equal(await main(['terms', 'eula'], ctx), 0);
  const text = ctx.said.join('\n');
  assert.doesNotMatch(text, /<[a-z/]|&amp;|\{\{/, 'no markup left');
  assert.match(text, /^Open Hearts — Terms of Use\nLast updated /);
  assert.match(text, /\n- Playing alone is free: No account,/);
  assert.match(text, /Apple and its subsidiaries are third-party beneficiaries of these terms/);
  assert.match(text, /the privacy policy \(https:\/\/openhearts\.game\/privacy\)/, 'a link on the site, written out');
  assert.match(text, /\nEmail help@openhearts\.game, or write to:\n\nBright Fulton LLC\nOpen Hearts\n/, 'an address as its words, lines as lines');
  assert.match(text, /under Contact \("Open Hearts"/, 'a link within the page, as its words');
  // Each of the page's words is in it, in order.
  const page = render('terms', languages.find((l) => l.code === 'en'), strings('en'));
  const words = (s) => s.replace(/\([^)]*\)|\[[^\]]*\]/g, ' ').match(/[A-Za-z]{4,}/g);
  const missing = words(textOf(page)).filter((w) => !text.includes(w));
  assert.deepEqual(missing, [], 'nothing dropped');
  assert.equal(plainTextOf('<h1>T</h1><p class="updated">U</p><main><p>A &amp; <a href="https://x.example/y">B</a></p></main>'), 'T\nU\n\nA & B (https://x.example/y)\n');
});
