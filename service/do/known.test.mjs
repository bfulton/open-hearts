// Known images of child sexual abuse (known.mjs): each new picture asked
// about once, from the United States, before it is carried; and a match
// acted on with nobody waiting on the operator — withheld, held,
// terminated, reported to NCMEC, and the operator told — each step tried
// again until it is done.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { KNOWN_OBJECT, KnownPictures, knownAsker, knownScreen, retryAfter } from './known.mjs';
import { lobbyKind } from './relay.mjs';
import { PICTURES_ROW, WITHHELD_WHY, allowedOf, allowing, pictureDigest, withheldOf } from '../functions/pictures.mjs';

const A = '0123456789abcdef0123456789abcdef';
const B = 'fedcba9876543210fedcba9876543210';
const C = 'abcdefabcdefabcdefabcdefabcdefab';
const KEY = 'cd'.repeat(32);
const ORIGIN = 'https://play.example';
const PHOTODNA = 'https://photodna.example/Match';
const NCMEC = 'https://report.cybertip.org/ispws';

const bytes = (n) => Uint8Array.from([0xff, 0xd8, 0xff, n]);
const b64 = (u8) => Buffer.from(u8).toString('base64');
const pictureEvent = (jpeg, id = 'e1') => ({ id, kind: lobbyKind, content: JSON.stringify({ kind: 'picture', jpeg }) });

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
  const pictures = r2({ [`seen/${A}/${earlierDigest}`]: new Uint8Array(), [`review/${earlierDigest}.jpg`]: earlier });
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

test('the screen: a picture asked about until it is cleared, a match withheld as a take-down is, and a failure let through', async () => {
  const asked = [];
  let said = 'clear';
  const screen = knownScreen({ ask: async (a) => (asked.push(a), typeof said === 'function' ? said() : said) });
  const jpeg = b64(bytes(1));
  assert.equal(await screen(pictureEvent(jpeg), { account: A, key: KEY }), null);
  assert.equal(await screen(pictureEvent(jpeg, 'e2'), { account: A, key: KEY }), null);
  assert.deepEqual(asked, [{ jpeg, account: A, key: KEY }], 'once cleared, not asked again');

  said = 'match';
  const other = b64(bytes(2));
  assert.equal(await screen(pictureEvent(other), { account: B, key: KEY }), WITHHELD_WHY);
  assert.equal(await screen(pictureEvent(other, 'e3'), { account: 'not an account', key: null }), WITHHELD_WHY, 'asked again: each account that puts it out');
  assert.deepEqual(asked.at(-1), { jpeg: other, account: null, key: null });

  said = () => {
    throw new Error('down');
  };
  const third = b64(bytes(3));
  assert.equal(await screen(pictureEvent(third), { account: A, key: KEY }), null, 'let through');
  said = 'failed';
  assert.equal(await screen(pictureEvent(third), { account: A, key: KEY }), null);
  said = 'match';
  assert.equal(await screen(pictureEvent(third), { account: A, key: KEY }), WITHHELD_WHY, 'and asked about again');

  const before = asked.length;
  assert.equal(await screen({ id: 'x', kind: lobbyKind, content: '{"kind":"seat"}' }, { account: A }), null);
  assert.equal(await screen({ id: 'y', kind: 1, content: JSON.stringify({ kind: 'picture', jpeg: b64(bytes(7)) }) }, { account: A }), null);
  assert.equal(asked.length, before, 'only a picture, of the lobby kind');
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
  t.pictures.m.set(`seen/${C}/${digest}`, { bytes: new Uint8Array(), type: '' });

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
  assert.equal(await t.obj.check({ jpeg: b64(jpeg), account: null, key: null }), 'failed', 'put out by a device the relay did not know');
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

  // A relay that cannot reach the object says so.
  const told = [];
  const screen = knownScreen({ ask: async () => { throw new Error('said 503'); }, failed: (why) => told.push(why) });
  assert.equal(await screen(pictureEvent(b64(jpeg)), { account: A }), null);
  assert.deepEqual(told, ['a relay could not ask whether a picture is a known image: said 503']);
});

test('off without the key, and the object answers only its two calls', async () => {
  const t = await setUp({ key: '' });
  assert.equal(await t.obj.check({ jpeg: b64(bytes(1)), account: A, key: KEY }), 'off');
  assert.equal(t.w.photoDnaAsked, 0);
  const said = await t.obj.fetch(new Request('https://known/check', { method: 'POST', body: JSON.stringify({ jpeg: b64(bytes(1)) }) }));
  assert.deepEqual(await said.json(), { said: 'off' });
  assert.equal((await t.obj.fetch(new Request('https://known/check', { method: 'POST', body: 'not json' }))).status, 200);
  assert.equal((await t.obj.fetch(new Request('https://known/other'))).status, 404);
});
