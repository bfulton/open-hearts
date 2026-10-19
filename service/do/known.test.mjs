// Known images of child sexual abuse (known.mjs): each new picture asked
// about once, from the United States, as an account sets it; and a match
// acted on with nobody waiting on the operator — withheld, held,
// terminated, reported to NCMEC, and the operator told — each step tried
// again until it is done.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { KNOWN_OBJECT, KnownPictures, REPORT_KEPT_S, knownAsker, knownReport, retryAfter } from './known.mjs';
import { PICTURES_ROW, allowedOf, allowing, pictureDigest, withheldOf } from '../functions/pictures.mjs';

const A = '0123456789abcdef0123456789abcdef';
const B = 'fedcba9876543210fedcba9876543210';
const C = 'abcdefabcdefabcdefabcdefabcdefab';
const KEY = 'cd'.repeat(32);
const ORIGIN = 'https://play.example';
const PHOTODNA = 'https://photodna.example/Match';
const NCMEC = 'https://report.cybertip.org/ispws';

const bytes = (n) => Uint8Array.from([0xff, 0xd8, 0xff, n]);
const b64 = (u8) => Buffer.from(u8).toString('base64');

/// Cloudflare KV, as storeOf reads it (rows.mjs).
function kv() {
  const m = new Map();
  return {
    m,
    row: (pk, sk) => (m.has(`${pk}|${sk}`) ? JSON.parse(m.get(`${pk}|${sk}`)) : null),
    async get(k, type) {
      const v = m.get(k);
      return v === undefined ? null : type === 'json' ? JSON.parse(v) : v;
    },
    async put(k, v) {
      m.set(k, v);
    },
    async delete(k) {
      m.delete(k);
    },
    async list({ prefix }) {
      return { keys: [...m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true };
    },
  };
}

/// An R2 bucket binding.
function r2(seed = {}) {
  const m = new Map(Object.entries(seed).map(([k, v]) => [k, { bytes: v, type: 'image/jpeg' }]));
  return {
    m,
    async get(k) {
      const v = m.get(k);
      return v ? { arrayBuffer: async () => v.bytes.slice().buffer } : null;
    },
    async put(k, body, opts) {
      m.set(k, { bytes: new Uint8Array(body), type: opts?.httpMetadata?.contentType });
    },
    async delete(k) {
      m.delete(k);
    },
    async list({ prefix }) {
      return { objects: [...m.keys()].filter((k) => k.startsWith(prefix)).sort().map((key) => ({ key })), truncated: false };
    },
  };
}

/// A Durable Object's state: its storage, and its alarm, which the
/// runtime clears as it rings.
function doState() {
  const m = new Map();
  const st = {
    m,
    alarm: null,
    storage: {
      async get(k) {
        return structuredClone(m.get(k));
      },
      async put(k, v) {
        m.set(k, structuredClone(v));
      },
      async delete(k) {
        m.delete(k);
      },
      async list({ prefix }) {
        return new Map([...m].filter(([k]) => k.startsWith(prefix)).map(([k, v]) => [k, structuredClone(v)]));
      },
      async getAlarm() {
        return st.alarm;
      },
      async setAlarm(t) {
        st.alarm = t;
      },
    },
  };
  return st;
}

/// Everything the object reaches: PhotoDNA, which matches the pictures
/// in [known] (and, while [photoDnaDown], answers nothing); the
/// service's order route; and NCMEC, each answering as told.
function world({ known = new Set() } = {}) {
  const w = {
    known,
    photoDnaDown: false,
    photoDnaAsked: 0,
    order: () => ({ status: 200, body: { act: 'terminate' } }),
    ncmecFails: null,
    orders: [],
    ncmec: [],
    store: null,
    async fetchImpl(url, init) {
      if (url === PHOTODNA) {
        w.photoDnaAsked++;
        if (w.photoDnaDown) return new Response('{"Status":{"Code":3004}}', { status: 500 });
        const digest = Buffer.from(await crypto.subtle.digest('SHA-256', init.body)).toString('hex');
        return Response.json({ Status: { Code: 3000 }, IsMatch: w.known.has(digest) });
      }
      if (url === `${ORIGIN}/api/order`) {
        const { order } = JSON.parse(init.body);
        w.orders.push(w.store.row(`ORDER#${order}`, 'META'));
        const { status, body } = w.order();
        return Response.json(body, { status });
      }
      if (url.startsWith(NCMEC) || url.startsWith('https://exttest.cybertip.org/ispws')) {
        const path = new URL(url).pathname.replace('/ispws', '');
        w.ncmec.push({ path, body: init.body, auth: init.headers.authorization });
        if (w.ncmecFails === path) return new Response('down', { status: 500 });
        const extra = path === '/submit' ? '<reportId>4564654</reportId>' : path === '/upload' ? '<fileId>f1</fileId>' : '';
        return new Response(`<reportResponse><responseCode>0</responseCode>${extra}</reportResponse>`);
      }
      throw new Error(`not faked: ${url}`);
    },
  };
  return w;
}

/// The object over a fresh deployment: account A has a web
/// subscription, a name and an earlier picture the relay copied.
async function setUp({ ncmec = true, endpoint = NCMEC, known = new Set(), key = 'k' } = {}) {
  const store = kv();
  store.m.set(`ACCOUNT#${A}|META`, JSON.stringify({ subscription: 'sub_1' }));
  store.m.set(`ACCOUNT#${A}|PROFILE`, JSON.stringify({ name: 'Ada' }));
  const earlier = bytes(9);
  const earlierDigest = await pictureDigest(b64(earlier));
  const pictures = r2({ [`account/${A}/${earlierDigest}`]: new Uint8Array(), [`review/${earlierDigest}.jpg`]: earlier });
  const records = r2();
  const sent = [];
  const w = world({ known });
  w.store = store;
  const env = {
    OH_STORE: store,
    OH_PICTURES: pictures,
    OH_RECORDS: records,
    EMAIL: { send: async (m) => sent.push(m) },
    OH_MAIL_FROM: 'noreply@openhearts.game',
    OH_ALERTS_TO: 'alerts@openhearts.game',
    OH_PHOTODNA_KEY: key,
    OH_PHOTODNA_ENDPOINT: PHOTODNA,
    OH_APP_ORIGIN: ORIGIN,
    OH_NCMEC_ENDPOINT: endpoint,
    OH_NCMEC_EMAIL: 'help@openhearts.game',
    OH_NCMEC_FIRST_NAME: 'Bright',
    OH_NCMEC_LAST_NAME: 'Fulton',
    ...(ncmec ? { OH_NCMEC_USERNAME: 'user', OH_NCMEC_PASSWORD: 'pass' } : {}),
  };
  // Problems go out as alerts, through the operator-alerts object
  // (alerts.mjs, tell).
  const alerts = [];
  env.HOUSEHOLD = {
    idFromName: (n) => n,
    get: () => ({ fetch: async (url, init) => (alerts.push(JSON.parse(init.body)), Response.json({ status: 200 })) }),
  };
  const state = doState();
  let now = Date.parse('2026-10-19T20:00:00Z');
  const clock = { tick: (ms) => (now += ms) };
  const obj = new KnownPictures(state, env, { fetchImpl: (u, i) => w.fetchImpl(u, i), now: () => now, log: () => {} });
  // As the runtime does: the alarm cleared as it rings.
  const ring = async () => {
    state.alarm = null;
    await obj.alarm();
  };
  return { obj, state, env, store, pictures, records, sent, alerts, w, clock, ring, earlierDigest, now: () => now };
}

test('asked as each picture is set: a match opens a case for the account that set it, shown as it says, from when it was set', async () => {
  const jpeg = bytes(5);
  const digest = await pictureDigest(b64(jpeg));
  const t = await setUp({ known: new Set([digest]) });
  const caseOf = async (account) => t.state.storage.get(`case:${digest}:${account}`);
  // Set from a device: never shown, from now.
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY }), 'match');
  assert.deepEqual([(await caseOf(A)).shown, (await caseOf(A)).at, (await caseOf(A)).key], [false, new Date(t.now()).toISOString(), KEY]);
  // The daily run asking again of a picture another account had kept
  // meanwhile: shown, from when it was set; PhotoDNA not asked again.
  const earlier = new Date(t.now() - 3 * 60 * 60 * 1000).toISOString();
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: B, key: null, shown: true, at: earlier }), 'match');
  assert.deepEqual([(await caseOf(B)).shown, (await caseOf(B)).at], [true, earlier]);
  assert.equal(t.w.photoDnaAsked, 1);
  // A time yet to come, or none that reads as one, is now.
  for (const at of [new Date(t.now() + 60 * 1000).toISOString(), 'soon']) {
    const account = at === 'soon' ? 'dd'.repeat(16) : C;
    await t.obj.check({ jpeg: b64(jpeg), account, key: null, shown: true, at });
    assert.equal((await caseOf(account)).at, new Date(t.now()).toISOString(), at);
  }

  // Let through while PhotoDNA did not answer: the case, when it
  // matches, is from when it was first let through.
  const other = bytes(6);
  const late = await pictureDigest(b64(other));
  const u = await setUp({ known: new Set([late]) });
  u.w.photoDnaDown = true;
  const first = new Date(u.now()).toISOString();
  assert.equal(await u.obj.check({ jpeg: b64(other), account: A, key: KEY }), 'failed');
  u.clock.tick(60 * 1000);
  assert.equal(await u.obj.check({ jpeg: b64(other), account: B, key: KEY }), 'failed');
  assert.equal((await u.state.storage.get(`retry:${late}`)).at, first, 'the first time kept');
  u.w.photoDnaDown = false;
  u.clock.tick(retryAfter(2));
  await u.ring();
  for (const account of [A, B]) assert.equal((await u.state.storage.get(`case:${late}:${account}`)).at, first, account);
});

test('asked of one object, in the "us" jurisdiction, and only with the key', async () => {
  const calls = [];
  const KNOWN = {
    jurisdiction: (j) => (calls.push(['jurisdiction', j]), { idFromName: (n) => (calls.push(['name', n]), `id:${n}`), get: (id) => ({ fetch: async (url, init) => (calls.push(['fetch', id, url, JSON.parse(init.body)]), Response.json({ said: 'clear' })) }) }),
  };
  assert.equal(knownAsker({ KNOWN }), null, 'no key, nothing asked');
  assert.equal(knownAsker({ OH_PHOTODNA_KEY: 'k' }), null);
  assert.equal(knownAsker({ OH_PHOTODNA_KEY: 'k', KNOWN: { get() {}, idFromName() {} } }), null, 'nowhere it can be kept in the United States');
  const ask = knownAsker({ KNOWN, OH_PHOTODNA_KEY: 'k' });
  assert.equal(await ask({ jpeg: 'x', account: A, key: KEY }), 'clear');
  assert.deepEqual(calls, [['jurisdiction', 'us'], ['name', KNOWN_OBJECT], ['fetch', `id:${KNOWN_OBJECT}`, 'https://known/check', { jpeg: 'x', account: A, key: KEY }]]);
});

test('a match at upload: withheld, held with its pictures, terminated with its web subscription, reported, and the operator told; nothing left', async () => {
  const jpeg = bytes(1);
  const digest = await pictureDigest(b64(jpeg));
  const t = await setUp({ known: new Set([digest]) });
  const clear = b64(bytes(2));
  assert.equal(await t.obj.check({ jpeg: clear, account: A, key: KEY }), 'clear');
  assert.equal(await t.obj.check({ jpeg: clear, account: B, key: KEY }), 'clear');
  assert.equal(t.w.photoDnaAsked, 1, 'a picture is asked about once');

  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY }), 'match');
  assert.equal(t.state.alarm, t.now(), 'acted on at once');
  await t.ring();

  assert.ok(withheldOf(t.store.row(...PICTURES_ROW), t.now()).has(digest), 'withheld at the relay');
  const hold = t.store.row(`ACCOUNT#${A}`, 'HOLD');
  assert.deepEqual(hold, { since: '2026-10-19', until: '2027-10-19', ref: '4564654', deleteAsked: null });
  assert.deepEqual(t.records.m.get(`held/${A}/${digest}.jpg`), { bytes: jpeg, type: 'image/jpeg' });
  assert.deepEqual(t.records.m.get(`held/${A}/${t.earlierDigest}.jpg`), { bytes: bytes(9), type: 'image/jpeg' }, 'and its other pictures');
  assert.equal(t.w.orders.length, 1);
  assert.deepEqual({ ...t.w.orders[0], at: null }, { account: A, act: 'terminate', at: null, endWeb: true });
  assert.deepEqual(t.w.ncmec.map((c) => c.path), ['/submit', '/upload', '/fileinfo', '/finish']);
  assert.equal(t.w.ncmec[0].auth, `Basic ${btoa('user:pass')}`);
  assert.match(t.w.ncmec[0].body, new RegExp(`<espIdentifier>${A}</espIdentifier>`));
  assert.match(t.w.ncmec[0].body, /<screenName>Ada<\/screenName>/);
  assert.match(t.w.ncmec[2].body, /<publiclyAvailable>false<\/publiclyAvailable>/);

  assert.equal(t.sent.length, 1);
  const [mail] = t.sent;
  assert.equal(mail.to, 'alerts@openhearts.game');
  assert.equal(mail.subject, 'Open Hearts: a known child abuse image was blocked');
  assert.match(mail.text, /withheld before any other player was shown it/);
  assert.match(mail.text, /reported to NCMEC's CyberTipline, report 4564654/);
  assert.match(mail.text, /Nothing needs you\./);
  assert.ok(!mail.text.includes(b64(jpeg)), 'never the picture');

  const [[, c]] = [...(await t.state.storage.list({ prefix: 'case:' }))];
  assert.equal(c.closed, true);
  assert.equal(c.jpeg, undefined, 'the picture kept only while a step needs it');
  assert.equal(t.state.alarm, null, 'nothing left to do');

  // Another account putting it out: withheld, and acted on, without
  // asking PhotoDNA again.
  const asked = t.w.photoDnaAsked;
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: B, key: KEY }), 'match');
  assert.equal(t.w.photoDnaAsked, asked);
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY }), 'match');
  await t.ring();
  assert.equal((await t.state.storage.list({ prefix: 'case:' })).size, 2, 'one case an account');
  assert.equal(t.w.ncmec.filter((c) => c.path === '/finish').length, 2, 'and one report an account');
});

test("PhotoDNA not answering lets a picture through, asks again, and a match then is acted on for each account that put it out, its public copy deleted", async () => {
  const jpeg = bytes(1);
  const digest = await pictureDigest(b64(jpeg));
  const t = await setUp({ known: new Set([digest]) });
  t.w.photoDnaDown = true;
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY }), 'failed');
  assert.equal(t.state.alarm, t.now() + retryAfter(1));
  // Carried meanwhile: the relay copied it, and C put it out too.
  t.pictures.m.set(`review/${digest}.jpg`, { bytes: jpeg, type: 'image/jpeg' });
  t.pictures.m.set(`account/${C}/${digest}`, { bytes: new Uint8Array(), type: '' });

  t.clock.tick(retryAfter(1));
  await t.ring();
  assert.equal(t.state.alarm, t.now() + retryAfter(2), 'still down: asked again later');
  t.w.photoDnaDown = false;
  t.clock.tick(retryAfter(2));
  await t.ring();

  const cases = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual(cases.map((c) => c.account).sort(), [A, C].sort());
  assert.ok(cases.every((c) => c.shown));
  assert.equal(t.pictures.m.has(`review/${digest}.jpg`), false, 'its public copy deleted');
  assert.deepEqual(t.records.m.get(`held/${C}/${digest}.jpg`)?.bytes, jpeg, 'and the hold has it');
  assert.equal((await t.state.storage.list({ prefix: 'retry:' })).size, 0);
  assert.ok(t.w.ncmec.filter((c) => c.path === '/fileinfo').every((c) => /<publiclyAvailable>true<\/publiclyAvailable>/.test(c.body)));
  assert.match(t.sent[0].text, /shown to other players before the match was known/);
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: B, key: KEY }), 'match', 'known from then on');
});

test('a match found as another account puts out a picture let through earlier: a case for each account, and none for nobody', async () => {
  const jpeg = bytes(1);
  const t = await setUp({ known: new Set([await pictureDigest(b64(jpeg))]) });
  t.w.photoDnaDown = true;
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: null, key: null }), 'failed', 'set by no account the object knows');
  t.w.photoDnaDown = false;
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: B, key: KEY }), 'match');
  await t.ring();
  const cases = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual(cases.map((c) => [c.account, c.shown]), [[B, false]]);
  assert.equal(t.w.ncmec.filter((c) => c.path === '/finish').length, 1, 'one report');
});

test('a step that fails is tried again until it is done, and the operator told what is still to do, then that it is done', async () => {
  const jpeg = bytes(1);
  const t = await setUp({ known: new Set([await pictureDigest(b64(jpeg))]) });
  t.w.order = () => ({ status: 503, body: { error: 'the service is not configured' } });
  t.w.ncmecFails = '/submit';
  await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY });
  await t.ring();
  let [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.closed, false);
  assert.deepEqual(Object.keys(c.failed).sort(), ['ended', 'reported']);
  assert.ok(c.jpeg, 'kept while the report needs it');
  assert.equal(t.state.alarm, t.now() + retryAfter(1));
  assert.equal(t.sent[0].subject, 'Open Hearts: a known child abuse image was blocked, and an automatic step failed');
  assert.match(t.sent[0].text, new RegExp(`terminate it \\(the service said 503: the service is not configured; tried again by itself\\): \\./oh account terminate ${A} --serious --apply`));
  assert.match(t.sent[0].text, /report it to NCMEC \(NCMEC \/submit: 500.*tried again by itself\)/);

  // Nothing changed: tried again, and the operator not told twice.
  t.clock.tick(retryAfter(1));
  await t.ring();
  assert.equal(t.sent.length, 1);
  assert.equal(t.state.alarm, t.now() + retryAfter(2));

  t.w.order = () => ({ status: 200, body: {} });
  t.w.ncmecFails = null;
  t.clock.tick(retryAfter(2));
  await t.ring();
  [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.closed, true);
  assert.equal(t.sent.length, 2);
  assert.match(t.sent[1].text, /Nothing needs you\./);
  assert.equal(t.state.alarm, null);
});

test("without NCMEC's credentials the rest is done, the operator told to report it, and the report filed once they are set", async () => {
  const jpeg = bytes(1);
  const t = await setUp({ ncmec: false, known: new Set([await pictureDigest(b64(jpeg))]) });
  await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY });
  await t.ring();
  let [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.done.hidden && c.done.held && c.done.ended, true);
  assert.equal(c.closed, false);
  assert.equal(t.state.alarm, null, 'nothing to try again by itself');
  assert.match(t.sent[0].text, new RegExp(`report it to NCMEC yourself, at https://report.cybertip.org/ \\(docs/how-to/handle-abuse-material.md\\), then \\./oh account hold ${A} --ref <number> --apply`));
  assert.deepEqual(t.w.ncmec, []);

  t.env.OH_NCMEC_USERNAME = 'user';
  t.env.OH_NCMEC_PASSWORD = 'pass';
  const woke = await t.obj.fetch(new Request('https://known/wake', { method: 'POST' }));
  assert.equal(woke.status, 200);
  [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.done.reported, '4564654');
  assert.equal(c.closed, true);
  assert.equal(t.store.row(`ACCOUNT#${A}`, 'HOLD').ref, '4564654');
});

test("NCMEC's test service: the report goes there and nowhere else, and the operator is told to report it", async () => {
  const jpeg = bytes(1);
  const t = await setUp({ endpoint: 'https://exttest.cybertip.org/ispws', known: new Set([await pictureDigest(b64(jpeg))]) });
  await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY });
  await t.ring();
  const [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.done.reported, '4564654');
  assert.equal(c.closed, false);
  assert.equal(t.store.row(`ACCOUNT#${A}`, 'HOLD').ref, null, "a test report's number is no report's");
  assert.match(t.sent[0].text, /filed to NCMEC's test service only, report 4564654: nothing went to NCMEC/);
  assert.equal(t.sent[0].subject, 'Open Hearts: a known child abuse image was blocked (something for you to do)');
  assert.match(t.sent[0].text, /report it to NCMEC yourself/);
});

test("an order the service did not carry out is ordered again, and the case stays open until it is: only an account no longer there has nothing to end", async () => {
  const jpeg = bytes(1);
  const t = await setUp({ known: new Set([await pictureDigest(b64(jpeg))]) });
  // KV not yet showing the order to the service, then the order run out.
  const answers = [{ status: 404, body: { error: 'no such order' } }, { status: 410, body: { error: 'that order has run out' } }, { status: 200, body: {} }];
  t.w.order = () => answers.shift();
  await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY });
  await t.ring();
  let [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual([c.done.ended, c.closed, Object.keys(c.failed)], [undefined, false, ['ended']], 'reported, held, and not closed while not ended');
  assert.equal(c.done.reported, '4564654');
  t.clock.tick(retryAfter(1));
  await t.ring();
  [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual([c.done.ended, c.closed], [undefined, false]);
  t.clock.tick(retryAfter(2));
  await t.ring();
  [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual([c.done.ended, c.closed], [true, true]);
  assert.equal(t.w.orders.length, 3, 'a fresh order each time');
});

test("an account no longer there has nothing to end; a picture allowed after the check is withheld all the same", async () => {
  const jpeg = bytes(1);
  const digest = await pictureDigest(b64(jpeg));
  const t = await setUp({ known: new Set([digest]) });
  t.store.m.set(PICTURES_ROW.join('|'), JSON.stringify(allowing(null, digest, t.now())));
  t.w.order = () => ({ status: 404, body: { error: 'no such account' } });
  await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY });
  await t.ring();
  const [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.done.ended, 'no such account');
  assert.equal(c.closed, true);
  const row = t.store.row(...PICTURES_ROW);
  assert.ok(withheldOf(row, t.now()).has(digest));
  assert.ok(!allowedOf(row, t.now()).has(digest));
});

test('every failure of the automatic handling emails the operator, once in a while for each kind', async () => {
  const jpeg = bytes(1);
  const t = await setUp({ known: new Set([await pictureDigest(b64(jpeg))]) });
  t.w.photoDnaDown = true;
  await t.obj.check({ jpeg: b64(jpeg), account: A, key: KEY });
  await t.obj.check({ jpeg: b64(bytes(2)), account: A, key: KEY });
  assert.equal(t.alerts.length, 1, 'one email for one outage');
  assert.equal(t.alerts[0].op, 'alert');
  assert.equal(t.alerts[0].to, 'alerts@openhearts.game');
  assert.equal(t.alerts[0].subject, 'Open Hearts: the automatic handling of abuse images failed (photodna)');
  assert.match(t.alerts[0].text, /a picture was let through unchecked, to be asked about again: PhotoDNA said 500, status 3004/);

  // A key and no address: nothing is checked, and the operator is told.
  const config = await setUp();
  config.env.OH_PHOTODNA_ENDPOINT = undefined;
  assert.equal(await config.obj.check({ jpeg: b64(jpeg), account: A, key: KEY }), 'off');
  assert.match(config.alerts[0].subject, /\(config\)/);
  assert.match(config.alerts[0].text, /OH_PHOTODNA_KEY is set but photodna.endpoint/);

  // Anything else that throws: told, the picture let through, and the
  // alarm set to try again.
  const broken = await setUp();
  broken.state.storage.get = async () => {
    throw new Error('storage down');
  };
  const said = await broken.obj.fetch(new Request('https://known/check', { method: 'POST', body: JSON.stringify({ jpeg: b64(jpeg), account: A }) }));
  assert.deepEqual(await said.json(), { said: 'failed' });
  assert.match(broken.alerts[0].subject, /\(error\)/);
  assert.match(broken.alerts[0].text, /storage down/);
  broken.state.storage.list = async () => {
    throw new Error('list down');
  };
  broken.store.m.clear();
  await broken.ring();
  assert.match(broken.alerts.at(-1).text, /list down/);
  assert.equal(broken.state.alarm, broken.now() + retryAfter(4));

});

/// The relay worker's `POST /known` (knownReport) over [t]'s object,
/// with [body] (a string as it is, anything else as JSON); t.reached
/// counts what got as far as the object.
async function askRelay(t, body, env = t.env) {
  t.reached ??= 0;
  const KNOWN = {
    jurisdiction: (where) => ({
      idFromName: (name) => `${where}/${name}`,
      get: (id) => {
        assert.equal(id, `us/${KNOWN_OBJECT}`, 'the one object, in the United States');
        return { fetch: async (url, init) => (t.reached++, t.obj.fetch(new Request(url, init))) };
      },
    }),
  };
  const request = new Request('https://relay.example/known', { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) });
  const res = await knownReport(request, { KNOWN, ...env });
  return { status: res.status, body: await res.json() };
}

/// A report as `oh picture report` writes it, [row] under [id], and
/// named to the relay.
async function reportIt(t, row, id = 'a'.repeat(32)) {
  t.store.m.set(`KNOWN#${id}|META`, JSON.stringify(row));
  return askRelay(t, { report: id });
}

test('a picture the operator reports is handled as a match: each account that put it out, the report saying they looked, and the picture known from then on', async () => {
  const jpeg = bytes(5);
  const digest = await pictureDigest(b64(jpeg));
  const t = await setUp();
  t.pictures.m.set(`review/${digest}.jpg`, { bytes: jpeg, type: 'image/jpeg' });
  t.pictures.m.set(`account/${A}/${digest}`, { bytes: new Uint8Array(), type: '' });
  const said = await reportIt(t, { digest, accounts: [C], how: '  a player reported it  ' });
  assert.deepEqual(said, { status: 200, body: { reported: digest, accounts: [C, A] } });
  assert.equal(t.w.photoDnaAsked, 0, 'PhotoDNA not asked');
  await t.ring();

  const cases = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual(cases.map((c) => [c.account, c.viewed, c.how, c.shown]).sort(), [[A, true, 'a player reported it', true], [C, true, 'a player reported it', true]].sort());
  assert.ok(cases.every((c) => c.closed));
  assert.ok(withheldOf(t.store.row(...PICTURES_ROW), t.now()).has(digest));
  assert.equal(t.pictures.m.has(`review/${digest}.jpg`), false, 'its public copy deleted');
  assert.deepEqual(t.records.m.get(`held/${A}/${digest}.jpg`)?.bytes, jpeg);
  const submits = t.w.ncmec.filter((c) => c.path === '/submit');
  assert.equal(submits.length, 2);
  assert.ok(submits.every((c) => /Found by the operator, who looked at it: a player reported it\./.test(c.body)));
  assert.ok(t.w.ncmec.filter((c) => c.path === '/fileinfo').every((c) => /<fileViewedByEsp>true<\/fileViewedByEsp>/.test(c.body)));
  assert.equal(t.sent[0].subject, 'Open Hearts: a picture you reported was taken down');
  assert.match(t.sent[0].text, /^You reported a picture account .* set as child sexual abuse material \(a player reported it\)/);

  // Known from then on: whoever puts it out again is acted on too.
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: B, key: KEY }), 'match');
  assert.equal(t.w.photoDnaAsked, 0);
});

test("a reported picture's copy is found wherever one is kept, and without one nothing is done", async () => {
  const jpeg = bytes(6);
  const digest = await pictureDigest(b64(jpeg));
  const t = await setUp();
  assert.deepEqual(await reportIt(t, { digest, accounts: [A] }), { status: 404, body: { error: 'no copy of that picture is kept: report it by hand' } });
  assert.equal((await t.state.storage.list({ prefix: 'case:' })).size, 0);

  // A's profile picture taken off, but another one: not this picture.
  t.store.m.set(`ACCOUNT#${A}|HELD`, JSON.stringify({ picture: b64(bytes(8)) }));
  assert.equal((await reportIt(t, { digest, accounts: [A] })).status, 404, 'never another picture in its place');

  // Taken off A's profile, and held there.
  t.store.m.set(`ACCOUNT#${A}|HELD`, JSON.stringify({ picture: b64(jpeg) }));
  assert.equal((await reportIt(t, { digest, accounts: [A] })).status, 200);
  let [c] = [...(await t.state.storage.list({ prefix: 'case:' })).values()];
  assert.equal(c.jpeg, b64(jpeg));

  // Kept by a hold.
  const u = await setUp();
  u.records.m.set(`held/${B}/${digest}.jpg`, { bytes: jpeg, type: 'image/jpeg' });
  assert.equal((await reportIt(u, { digest, accounts: [B] })).status, 200);
  [c] = [...(await u.state.storage.list({ prefix: 'case:' })).values()];
  assert.deepEqual([c.account, c.jpeg], [B, b64(jpeg)]);
});

test('a report reaches the object only when the tool wrote it, and is answered the same when asked again', async () => {
  const t = await setUp();
  const jpeg = bytes(7);
  const digest = await pictureDigest(b64(jpeg));
  t.pictures.m.set(`review/${digest}.jpg`, { bytes: jpeg, type: 'image/jpeg' });

  // Nothing the tool wrote: answered by the relay worker, the object
  // every picture is checked through never asked.
  const refused = [
    ['not json', 400, 'a report, 32 hex'],
    [{ report: 'not one' }, 400, 'a report, 32 hex'],
    [{ report: 'b'.repeat(32), more: 'x'.repeat(256) }, 400, 'a report, 32 hex'],
    [{ report: 'b'.repeat(32) }, 404, 'no such report'],
  ];
  for (const [body, status, error] of refused) assert.deepEqual(await askRelay(t, body), { status, body: { error } }, JSON.stringify(body).slice(0, 40));
  assert.deepEqual(await askRelay(t, { report: 'b'.repeat(32) }, { ...t.env, OH_STORE: undefined }), { status: 503, body: { error: 'not configured: KNOWN or the store' } });
  assert.equal(t.reached, 0);
  const bare = await t.obj.fetch(new Request('https://known/report', { method: 'POST', body: JSON.stringify({ digest, accounts: [] }) }));
  assert.deepEqual([bare.status, await bare.json()], [400, { error: 'a report, 32 hex' }], 'the object asks for the report too');
  assert.deepEqual(await reportIt(t, { digest: 'not a digest', accounts: [] }), { status: 400, body: { error: 'a picture, its SHA-256' } });
  assert.equal((await t.state.storage.list({ prefix: 'case:' })).size, 0);

  // Reported, and acted on: its relay copy is deleted, and it is
  // nobody's to hold. The tool asking again, its answer lost, is told
  // the same, and nothing is done twice.
  const id = 'c'.repeat(32);
  const said = await reportIt(t, { digest, accounts: [] }, id);
  assert.deepEqual(said, { status: 200, body: { reported: digest, accounts: [] } });
  await t.ring();
  assert.equal(t.pictures.m.has(`review/${digest}.jpg`), false);
  const filed = t.w.ncmec.length;
  assert.deepEqual(await askRelay(t, { report: id }), said);
  await t.ring();
  assert.equal(t.w.ncmec.length, filed, 'NCMEC not asked again');
  assert.equal((await t.state.storage.list({ prefix: 'case:' })).size, 1);

  // Another report since, and the first still answered; once the first
  // has run out, the next report forgets it.
  const other = await pictureDigest(b64(bytes(8)));
  t.pictures.m.set(`review/${other}.jpg`, { bytes: bytes(8), type: 'image/jpeg' });
  assert.equal((await reportIt(t, { digest: other, accounts: [] }, 'd'.repeat(32))).status, 200);
  assert.deepEqual(await askRelay(t, { report: id }), said);
  t.clock.tick(REPORT_KEPT_S * 1000);
  assert.equal((await reportIt(t, { digest: other, accounts: [] }, 'e'.repeat(32))).status, 200);
  assert.deepEqual([...(await t.state.storage.list({ prefix: 'report:' })).keys()], [`report:${'e'.repeat(32)}`]);
});

test('off without the key, and the object answers only its own calls', async () => {
  const t = await setUp({ key: '' });
  assert.equal(await t.obj.check({ jpeg: b64(bytes(1)), account: A, key: KEY }), 'off');
  assert.equal(t.w.photoDnaAsked, 0);
  const said = await t.obj.fetch(new Request('https://known/check', { method: 'POST', body: JSON.stringify({ jpeg: b64(bytes(1)) }) }));
  assert.deepEqual(await said.json(), { said: 'off' });
  assert.equal((await t.obj.fetch(new Request('https://known/check', { method: 'POST', body: 'not json' }))).status, 200);
  assert.equal((await t.obj.fetch(new Request('https://known/other'))).status, 404);
});
