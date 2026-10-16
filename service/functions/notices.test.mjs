// A change to the terms or the privacy policy that subscribers are told
// of (notices.mjs): shown at the front door for a while after it is
// published, and emailed to each web subscriber once, in their
// language, at the address Stripe has.
// node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker from './worker.mjs';
import { Household } from './household.mjs';
import { NOTICES_OBJECT, NOTICES_PER_ORDER, carryOutNotice, languageOf, noticeMail, noticeRow, noticesOf, sendNotice } from './notices.mjs';
import { memoryStore } from './rows.mjs';
import { orderRow } from './suspension.mjs';

const DAY = 86400000;
const now = Date.parse('2026-11-20T12:00:00Z');
const summary = (what) => ({ en: `${what}.`, es: `${what} (es).`, pt: `${what} (pt).`, de: `${what} (de).`, fr: `${what} (fr).` });
const entry = (date, change, what = `the ${change} change of ${date}`) => ({ date, change, fingerprint: 'a'.repeat(64), storesNotified: null, summary: summary(what) });

const LEDGER = {
  terms: [entry('2026-10-16', 'first'), entry('2026-11-01', 'material', 'Refunds end the subscription'), entry('2026-11-10', 'minor')],
  privacy: [entry('2026-10-13', 'first'), entry('2026-08-01', 'material')].sort((a, b) => a.date.localeCompare(b.date)),
};

test('the front door shows each document\'s newest change subscribers are told of, for sixty days', () => {
  assert.deepEqual(noticesOf(LEDGER, now), [{ document: 'terms', date: '2026-11-01', summary: summary('Refunds end the subscription') }], 'not a minor change, and not one older than sixty days');
  assert.equal(noticesOf(LEDGER, Date.parse('2026-12-30T23:00:00Z')).length, 1, 'on the sixtieth day, 1 November the first');
  assert.deepEqual(noticesOf(LEDGER, Date.parse('2026-12-31T00:00:00Z')), [], 'and not after');
  assert.deepEqual(noticesOf(LEDGER, Date.parse('2026-10-31T00:00:00Z')), [], 'not before it is published');
  assert.deepEqual(noticesOf(undefined, now), []);
  const priced = { ...LEDGER, terms: [...LEDGER.terms, { ...entry('2026-11-15', 'price'), price: { amount: 699, currency: 'usd' } }] };
  assert.equal(noticesOf(priced, now)[0].date, '2026-11-15', 'a new price is told too');
});

test('the config route serves the notices of the ledger this deploy published', async () => {
  const day = (ago) => new Date(Date.now() - ago * DAY).toISOString().slice(0, 10);
  const ledger = { terms: [entry(day(40), 'first'), entry(day(3), 'material', 'Refunds end the subscription')], privacy: [entry(day(40), 'first')] };
  const answer = await worker.fetch(new Request('https://play.openhearts.game/api/config'), { OH_LEDGER: ledger });
  const body = await answer.json();
  assert.deepEqual(body.notices, [{ document: 'terms', date: day(3), summary: summary('Refunds end the subscription') }]);
});

test('the email: what changed, where to read it, and when it applies, in the subscriber\'s language', () => {
  const told = LEDGER.terms[1];
  const en = noticeMail('en', 'terms', told, { renews: '2027-03-04' });
  assert.equal(en.subject, 'Changes to the Open Hearts terms of use');
  assert.match(en.text, /^We have changed the Open Hearts terms of use, on 2026-11-01\.\n\nRefunds end the subscription\.\n\nRead them in full: https:\/\/openhearts\.game\/terms\n\n/);
  assert.match(en.text, /from its next renewal, on 2027-03-04, except where they say a change applies sooner/);
  assert.match(en.text, /You are getting this email because you subscribe to Open Hearts on the web\.$/);
  assert.match(noticeMail('en', 'terms', told).text, /from its next renewal, except/, 'one that does not renew');
  const de = noticeMail('de', 'terms', told, { renews: '2027-03-04' });
  assert.match(de.text, /Refunds end the subscription \(de\)\./);
  assert.match(de.text, /https:\/\/openhearts\.game\/de\/terms/);
  assert.match(de.text, /Verlängerung am 2027-03-04,/);
  const privacy = noticeMail('fr', 'privacy', { ...told, summary: summary('Reports are kept') });
  assert.equal(privacy.subject, "Modifications de la politique de confidentialité d'Open Hearts");
  assert.match(privacy.text, /https:\/\/openhearts\.game\/fr\/privacy/);
  assert.doesNotMatch(privacy.text, /renouvellement/, 'a privacy policy is not renewed into');
  assert.equal(noticeMail('xx', 'terms', told).subject, en.subject, 'an unknown language is English');
});

test('the language: the one the subscription was bought in, else Stripe\'s for the customer, else English', () => {
  assert.equal(languageOf({ metadata: { lang: 'fr' }, customer: { preferred_locales: ['de'] } }), 'fr');
  assert.equal(languageOf({ metadata: {}, customer: { preferred_locales: ['pt-BR'] } }), 'pt');
  assert.equal(languageOf({ metadata: { lang: 'xx' }, customer: { preferred_locales: ['ja'] } }), 'en');
  assert.equal(languageOf(null), 'en');
});

/// Stripe's subscriptions, by id, with their customers.
function stripeWith(subs) {
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push({ url: String(url), auth: init.headers.authorization });
    const id = decodeURIComponent(/\/v1\/subscriptions\/([^?]+)\?expand\[\]=customer$/.exec(String(url))?.[1] ?? '');
    const sub = subs[id];
    if (sub === 'down') return new Response('no', { status: 500 });
    return sub ? Response.json({ id, ...sub }) : Response.json({ error: {} }, { status: 404 });
  };
  fetchImpl.asked = asked;
  return fetchImpl;
}

const order = (subscriptions, more = {}) => ({ act: 'notice', document: 'terms', date: '2026-11-01', subscriptions, at: new Date(now).toISOString(), ...more });
const env = { OH_LEDGER: LEDGER, OH_STRIPE_SECRET: 'rk_live_x' };

test('an order tells each subscription once; one with no address is noted, and one whose mail did not go is tried again', async () => {
  const store = memoryStore();
  await store.put(...noticeRow('terms', '2026-11-01', 'sub_told'), { at: '2026-11-01T10:00:00.000Z', lang: 'en' });
  const subs = {
    sub_told: { customer: { email: 'a@example.com' } },
    sub_fr: { metadata: { lang: 'fr' }, customer: { email: 'b@example.com' }, items: { data: [{ current_period_end: Date.parse('2027-02-01T00:00:00Z') / 1000 }] } },
    sub_none: { customer: { email: null } },
    sub_bounce: { customer: { email: 'c@example.com' } },
  };
  const fetchImpl = stripeWith(subs);
  const sent = [];
  const send = async (mail) => (mail.to === 'c@example.com' ? false : (sent.push(mail), true));
  const said = await carryOutNotice(order(['sub_told', 'sub_fr', 'sub_none', 'sub_bounce', 'sub_gone']), store, env, { fetchImpl, send, now });
  assert.deepEqual(said, { status: 200, body: { act: 'notice', document: 'terms', date: '2026-11-01', told: 1, already: 1, unsent: { 'no address': 1, 'no such subscription': 1 }, failed: 1 } });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, 'b@example.com');
  assert.equal(sent[0].subject, "Modifications des conditions d'utilisation d'Open Hearts");
  assert.match(sent[0].text, /renouvellement, le 2027-02-01,/);
  assert.ok(fetchImpl.asked.every((a) => a.auth === 'Bearer rk_live_x'), 'with the service\'s own key');
  assert.ok(!fetchImpl.asked.some((a) => a.url.includes('sub_told')), 'one told already is not asked about');
  assert.deepEqual(await store.get(...noticeRow('terms', '2026-11-01', 'sub_fr')), { at: new Date(now).toISOString(), lang: 'fr' });
  assert.deepEqual(await store.get(...noticeRow('terms', '2026-11-01', 'sub_none')), { at: new Date(now).toISOString(), unsent: 'no address' });
  assert.equal(await store.get(...noticeRow('terms', '2026-11-01', 'sub_bounce')), null, 'not noted, so tried again');
  assert.ok(!JSON.stringify([...store.rows]).includes('@example.com'), 'no address is kept');

  const again = await carryOutNotice(order(['sub_fr', 'sub_none', 'sub_bounce']), store, env, { fetchImpl, send: async (m) => (sent.push(m), true), now });
  assert.deepEqual(again.body, { act: 'notice', document: 'terms', date: '2026-11-01', told: 1, already: 2, unsent: {}, failed: 0 });
  assert.equal(sent.at(-1).to, 'c@example.com');

  const down = await carryOutNotice(order(['sub_down']), store, env, { fetchImpl: stripeWith({ sub_down: 'down' }), send, now });
  assert.equal(down.body.failed, 1, 'Stripe not saying is tried again');
  assert.equal(await store.get(...noticeRow('terms', '2026-11-01', 'sub_down')), null);
});

test('an order for a change nobody is told of, run out, or naming anything but a few web subscriptions, is refused', async () => {
  const store = memoryStore();
  const fetchImpl = stripeWith({});
  const send = async () => assert.fail('nothing is sent');
  const refused = async (o, e = env) => (await carryOutNotice(o, store, e, { fetchImpl, send, now })).status;
  assert.equal(await refused(order(['sub_1'], { date: '2026-11-10' })), 400, 'a minor change');
  assert.equal(await refused(order(['sub_1'], { date: '2026-10-16' })), 400, 'the first entry');
  assert.equal(await refused(order(['sub_1'], { document: 'cookies' })), 400);
  assert.equal(await refused(order(['sub_1'], { at: new Date(now - 11 * 60000).toISOString() })), 410);
  assert.equal(await refused(order([])), 400);
  assert.equal(await refused(order(['apple:1000'])), 400, 'a store\'s subscription has no address of ours');
  assert.equal(await refused(order(Array.from({ length: NOTICES_PER_ORDER + 1 }, (_, i) => `sub_${i}`))), 400);
  assert.equal(await refused(order(['sub_1']), { OH_LEDGER: LEDGER }), 503, 'no Stripe key');
  assert.equal(await refused(order(['sub_1']), { OH_STRIPE_SECRET: 'x' }), 400, 'no ledger, no change to tell');
});

test('the order route carries a notice order out, and the mail goes through the relay\'s own object', async () => {
  const store = memoryStore();
  const kv = {
    get: async (at, kind) => {
      const [pk, sk] = at.split('|');
      const row = await store.get(pk, sk);
      return kind === 'json' ? row : row && JSON.stringify(row);
    },
    put: async (at, raw) => {
      const [pk, sk] = at.split('|');
      await store.put(pk, sk, JSON.parse(raw));
    },
  };
  const sent = [];
  const objects = [];
  const relayEnv = { EMAIL: { send: async (m) => sent.push(m) }, OH_MAIL_FROM: 'noreply@openhearts.game' };
  const HOUSEHOLD = {
    idFromName: (name) => name,
    get: (name) => (objects.push(name), { fetch: (url, init) => new Household({}, relayEnv).fetch(new Request(url, init)) }),
  };
  const id = 'ab'.repeat(16);
  await store.put(...orderRow(id), order(['sub_1'], { at: new Date().toISOString() }));
  const realFetch = globalThis.fetch;
  globalThis.fetch = stripeWith({ sub_1: { customer: { email: 'ada@example.com', preferred_locales: ['es'] } } });
  try {
    const res = await worker.fetch(new Request('https://play.openhearts.game/api/order', { method: 'POST', body: JSON.stringify({ order: id }) }), {
      ...env,
      OH_STORE: kv,
      HOUSEHOLD,
    });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).told, 1);
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(objects, [NOTICES_OBJECT]);
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].from, { email: 'noreply@openhearts.game', name: 'Open Hearts' });
  assert.equal(sent[0].to, 'ada@example.com');
  assert.equal(sent[0].subject, 'Cambios en las condiciones de uso de Open Hearts');
});

test('the relay\'s side sends to an address, from ours, and says when it cannot', async () => {
  const sent = [];
  const env = { EMAIL: { send: async (m) => sent.push(m) }, OH_MAIL_FROM: 'noreply@openhearts.game' };
  const mail = { to: 'ada@example.com', subject: 's', text: 't' };
  assert.deepEqual(await sendNotice(mail, env), { status: 200, body: { sent: true } });
  assert.equal(sent[0].to, 'ada@example.com');
  for (const bad of [{ ...mail, to: 'not an address' }, { ...mail, to: 7 }, { ...mail, text: null }]) assert.equal((await sendNotice(bad, env)).status, 400);
  assert.equal((await sendNotice(mail, { OH_MAIL_FROM: 'noreply@openhearts.game' })).status, 503);
  const failing = { ...env, EMAIL: { send: async () => { throw Object.assign(new Error('no'), { code: 'E_RECIPIENT' }); } } };
  assert.deepEqual(await sendNotice(mail, failing), { status: 502, body: { error: 'not sent: E_RECIPIENT' } });
});
