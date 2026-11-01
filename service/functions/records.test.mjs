// What the bucket keeps (records.mjs): a record its own player sent,
// once, packed, and given back as it was.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { gunzipSync, gzipSync } from 'node:zlib';
import { test } from 'node:test';

import { keys } from '../do/sign.mjs';
import { NotAsSent, anonymizeGames, eventIdOf, forgottenKey, keepRecord, keptGames, logHashes, markForgotten, recordMost, recordResponse } from './records.mjs';
import { licenceFor, signerOn } from './licence.mjs';

// Devices that can sign: BIP-340's published pairs, the second skipped
// as the worker's tests skip it (it is their service's own).
const [ada, , bao] = keys;
const ADA = ada.public;
const BAO = bao.public;
const CY = 'c'.repeat(64);
const TABLE = '0123456789abcdef0123456789abcdef';
const signer = await signerOn(await readFile(new URL('../../app/web/schnorr.wasm', import.meta.url)));
const keep = (bucket, key, table, text) => keepRecord(bucket, key, table, text, { verify: signer.verify });

/// An event [pair] says at [table], made as the table makes one
/// (packages/table, events.dart): its id the hash of what it says.
async function said(pair, kind, body, table = TABLE) {
  const event = { table, author: pair.public, kind, body };
  const id = await eventIdOf(table, event);
  return { id, table, author: pair.public, kind, body, sig: signer.sign(pair.secret, id) };
}

/// A game's record, as its players send it: the referee's log, with a
/// play each from Ada and Bao in it.
const game = {
  v: 3,
  spec: { id: TABLE, seed: 1, seats: [{ key: ADA }, { key: BAO }, { bot: 'Romeo' }, { bot: 'Juliet' }] },
  log: [
    { n: 0, t: 1000, e: await said(ada, 'play', { hand: 0, turn: 4, seat: 0, card: '2C' }) },
    { n: 1, t: 1250 },
    { n: 2, t: 2000, e: await said(bao, 'play', { hand: 0, turn: 5, seat: 1, card: '3C' }) },
  ],
};

/// An R2 bucket in memory: head, get, put, and a listing a page of one
/// at a time, as R2's binding lists, with each object's custom metadata
/// when it is asked for. Each write gives its object a new etag, and a
/// put with `onlyIf` is made only if that holds and answers null if not,
/// as R2's does. [before], if set, is told of each put just before it is
/// judged: a test's way to be another device writing at that moment.
function bucket() {
  const kept = new Map();
  let etags = 0;
  return {
    kept,
    read: [],
    puts: [],
    before: null,
    async head(key) {
      const k = kept.get(key);
      return k ? { key, etag: k.etag, customMetadata: k.custom } : null;
    },
    async get(key) {
      this.read.push(key);
      const k = kept.get(key);
      return k ? { body: new Blob([k.body]).stream(), etag: k.etag, httpMetadata: k.meta, customMetadata: k.custom } : null;
    },
    async put(key, body, options = {}) {
      await this.before?.(key, options);
      const was = kept.get(key);
      const { etagMatches, etagDoesNotMatch } = options.onlyIf ?? {};
      if (etagMatches !== undefined && was?.etag !== etagMatches) return null;
      if (etagDoesNotMatch !== undefined && was && (etagDoesNotMatch === '*' || was.etag === etagDoesNotMatch)) return null;
      const etag = `etag-${++etags}`;
      this.puts.push(key);
      kept.set(key, { body: Buffer.from(typeof body === 'string' ? body : new Uint8Array(body)), meta: options.httpMetadata, custom: options.customMetadata, etag });
      return { key, etag };
    },
    async list({ prefix, cursor, include = [] }) {
      const all = [...kept.keys()].filter((k) => k.startsWith(prefix)).sort();
      const at = cursor ? all.indexOf(cursor) : 0;
      const key = all[at];
      const objects = key === undefined ? [] : [{ key, ...(include.includes('customMetadata') ? { customMetadata: kept.get(key).custom } : {}) }];
      return { objects, truncated: at + 1 < all.length, cursor: all[at + 1] };
    },
  };
}

/// The game's record as its players send it, or with [change] made to
/// a copy first.
const record = (change = (r) => r) => JSON.stringify(change(structuredClone(game)));

test('an event\'s id is worked out here as the table works it out', async () => {
  // A real game, every event in it made by the Dart table.
  const real = JSON.parse(gunzipSync(await readFile(new URL('../../packages/table/test/fixtures/sealed_three_leave.json.gz', import.meta.url))).toString());
  const ids = await Promise.all(real.record.map((d) => eventIdOf(real.spec.id, d.event)));
  assert.deepEqual(ids, real.record.map((d) => d.event.id));
  assert.ok(ids.length > 50);
});

test('an event\'s id does not hang on the order of any object\'s keys, at any depth, as the table works it out', async () => {
  // The id the Dart table gives this event; JavaScript lists the
  // keys of `known` as 0, 2, 3, 10 whatever order they were written in.
  const body = { hand: 1, turn: 57, seat: 1, round: 4, secret: 's', known: { 3: 'c', 0: 'a', 2: 'b', 10: 'd' }, deeper: [{ b: 1, a: 2 }] };
  const event = { author: '14261433f12e255e017d79fd36bb2845f6417d399f19fd1f3aa455577c1aabf4', kind: 'deal', body };
  assert.equal(await eventIdOf('ab'.repeat(16), event), '35461adc14d3ef3efdac798ed5d2e426ab81ddca685cb25dbb922de94bcaed97');
});

/// A real game, played to its end over the referee's log on the
/// simulator by four people with real keys, its house's result in it, and
/// licences from the rig's service (BIP-340's second pair;
/// packages/table, tool/game_fixture.dart): the record as the app sends
/// it. [text] is what the tool printed, less the line it ended with.
const refereedFour = gunzipSync(await readFile(new URL('../../packages/table/test/fixtures/refereed_four.json.gz', import.meta.url))).toString().trim();
const real = JSON.parse(refereedFour);
const fromReal = (b, key, text = refereedFour, more = {}) =>
  keepRecord(b, key, real.spec.id, text, { verify: signer.verify, service: keys[1].public, house: real.spec.house, ...more });
const keptReal = (b) => b.kept.get(`tables/${real.spec.id}.json`);
const keptRealText = (b) => gunzipSync(keptReal(b).body).toString();

test('the log\'s running hash here is the one Dart folds, on the cases both read, and the house\'s word in a real game names the log by it', async () => {
  const vectors = JSON.parse(await readFile(new URL('../../packages/table/test/log_hash.vectors.json', import.meta.url), 'utf8'));
  assert.equal((await logHashes([]))[0], vectors.start);
  for (const c of vectors.cases) assert.deepEqual(await logHashes(c.log), c.hashes, c.name);
  const entries = vectors.cases.flatMap((c) => c.log);
  assert.ok(entries.some((e) => e.up) && entries.some((e) => e.down) && entries.some((e) => !e.e && !e.up && !e.down), 'a connection each way, and a tick');
  assert.ok(entries.some((e) => e.e?.kind === 'play') && entries.some((e) => e.e?.kind === 'wave'), 'an event that reads, and one that does not');
  // And a game the Dart table played and its house signed for: the hash
  // the house named is the fold of the entries before its word.
  const result = real.log.map((entry) => entry.e).find((e) => e?.kind === 'result' && e.author === real.spec.house);
  assert.equal((await logHashes(real.log))[result.body.n], result.body.hash);
  assert.notEqual((await logHashes(real.log))[result.body.n - 1], result.body.hash);
});

test('a game played at a refereed table, its record as the app sends it, comes out vouched, with each seat\'s name from its own device, and opens', async () => {
  const events = real.log.filter((entry) => entry.e).map((entry) => entry.e);
  assert.deepEqual(await Promise.all(events.map((e) => eventIdOf(real.spec.id, e))), events.map((e) => e.id));
  assert.ok(events.some((e) => e.kind === 'result' && e.author === real.spec.house));
  assert.deepEqual(real.names, { 0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee' }, 'each device sends the names of all four, as the table gave them');
  // Whichever of the four sends first: kept, marked as carrying the
  // house's word, and with the name of the seat that sent it and no other.
  for (const [i, seat] of real.spec.seats.entries()) {
    const b = bucket();
    assert.deepEqual(await fromReal(b, seat.key), { status: 200, body: { kept: true } });
    assert.deepEqual(keptReal(b).custom, { from: seat.key, accounts: real.spec.seats.map((s) => s.licence.account).join(','), vouched: '1' });
    const kept = JSON.parse(keptRealText(b));
    assert.deepEqual(kept.names, { [i]: real.names[i] });
    assert.deepEqual({ ...kept, names: undefined }, { ...real, names: undefined }, 'the rest as it was sent');
    // What opens is what the table played: the same log, entry for
    // entry, which the verifier replays (kept_records_test.dart holds this
    // very game to it).
    assert.equal(JSON.stringify(kept.log), JSON.stringify(real.log));
    assert.equal(keptRealText(b), refereedFour.replace(/"names":\{.*\}\}$/, `"names":{"${i}":"${real.names[i]}"}}`));
  }
  // The other three send theirs: each name goes in beside its seat, from
  // its own device, and the game is the one the first kept, as it was
  // sent, with all four names.
  const b = bucket();
  assert.equal((await fromReal(b, real.spec.seats[2].key)).status, 200);
  for (const i of [0, 3, 1]) assert.deepEqual(await fromReal(b, real.spec.seats[i].key), { status: 200, body: { kept: true, already: true } });
  assert.equal(keptRealText(b), refereedFour, 'every name, and the game as the app wrote it');
  assert.deepEqual(keptReal(b).custom, { from: real.spec.seats[2].key, accounts: real.spec.seats.map((s) => s.licence.account).join(','), vouched: '1' });
  // It comes back as kept, to whoever may look at it.
  const res = await recordResponse(b, real.spec.id);
  assert.equal(gunzipSync(Buffer.from(await res.arrayBuffer())).toString(), refereedFour);
  // The house signed in it too, but sits at no seat: a record is sent by
  // a player.
  assert.equal((await fromReal(bucket(), real.spec.house)).status, 403);
});

test('a stub of a game, sent before its end, does not stand in the way of the game: the copy with the house\'s word replaces it, and nothing replaces that', async () => {
  const [one, two, three] = real.spec.seats.map((s) => s.key);
  // Seat 0's copy cut short, before the house had said how the game
  // came out: a record of a game nobody can open.
  const resultAt = real.log.findIndex((entry) => entry.e?.kind === 'result');
  const cut = (entries, names) => JSON.stringify({ ...real, log: real.log.slice(0, entries), names });
  const stub = cut(resultAt - 40, { 0: 'Ada', 1: 'Not Bao', 2: 'Not Cy' });
  const b = bucket();
  assert.deepEqual(await fromReal(b, one, stub), { status: 200, body: { kept: true } });
  assert.equal(keptReal(b).custom.vouched, undefined, 'a copy that carries no word of the house\'s is first come, as it was');
  assert.deepEqual(JSON.parse(keptRealText(b)).names, { 0: 'Ada' }, 'and the names others are said to have are not kept');
  // Another stub does not replace it, whoever sends it.
  assert.deepEqual(await fromReal(b, two, cut(120, real.names)), { status: 200, body: { kept: true, already: true } });
  assert.equal(JSON.parse(keptRealText(b)).log.length, resultAt - 40);
  assert.equal(keptReal(b).custom.from, one);
  // The whole game does, and is marked.
  assert.deepEqual(await fromReal(b, two), { status: 200, body: { kept: true } });
  assert.equal(keptReal(b).custom.vouched, '1');
  assert.equal(keptReal(b).custom.from, two);
  assert.equal(JSON.parse(keptRealText(b)).log.length, real.log.length);
  assert.deepEqual(JSON.parse(keptRealText(b)).names, { 1: 'Bao' });
  // A stub sent again, or sent by another seat, replaces nothing and adds
  // nothing but its sender's own name; the game's other seats then
  // send theirs.
  const before = keptReal(b);
  assert.deepEqual(await fromReal(b, one, stub), { status: 200, body: { kept: true, already: true } });
  assert.deepEqual(await fromReal(b, three, cut(100, real.names)), { status: 200, body: { kept: true, already: true } });
  assert.equal(JSON.parse(keptRealText(b)).log.length, real.log.length, 'still the whole game');
  assert.deepEqual(JSON.parse(keptRealText(b)).names, { 0: 'Ada', 1: 'Bao', 2: 'Cy' });
  assert.notEqual(keptReal(b).etag, before.etag);
  assert.equal(keptReal(b).custom.vouched, '1');
  // Another copy of the whole game is already kept: no more is done.
  const puts = b.puts.length;
  assert.deepEqual(await fromReal(b, real.spec.seats[3].key), { status: 200, body: { kept: true, already: true } });
  assert.equal(b.puts.length, puts + 1, 'only the name of the seat that sent it');
});

test('a player at the table sends its record, and it is kept packed, once', async () => {
  const b = bucket();
  const text = record();
  assert.deepEqual(await keep(b, ADA, TABLE, text), { status: 200, body: { kept: true } });
  const kept = b.kept.get(`tables/${TABLE}.json`);
  assert.equal(gunzipSync(kept.body).toString(), text);
  assert.equal(kept.meta.contentEncoding, 'gzip');
  assert.ok(kept.body.length < text.length * 2);
  // Another player's copy: the first is the one kept.
  assert.deepEqual(await keep(b, BAO, TABLE, record()), { status: 200, body: { kept: true, already: true } });
  assert.equal(b.kept.size, 1);
});

test('only a player at that table, with that table\'s record, of a game\'s size', async () => {
  const b = bucket();
  assert.equal((await keep(b, CY, TABLE, record())).status, 403, 'not seated there');
  const named = (table) => record((r) => ({ ...r, spec: { ...r.spec, id: table } }));
  assert.equal((await keep(b, ADA, 'ROOM-1-2', named('ROOM-1-2'))).status, 400, 'not a table id');
  assert.equal((await keep(b, ADA, TABLE, named('f'.repeat(32)))).status, 400, 'another table\'s');
  assert.equal((await keep(b, ADA, TABLE, 'not json')).status, 400);
  assert.equal((await keep(b, ADA, TABLE, JSON.stringify({ v: 3, spec: { id: TABLE } }))).status, 400);
  // The forms before the referee, kept as they were and kept no more.
  for (const v of [1, 2]) {
    assert.deepEqual(await keep(b, ADA, TABLE, record((r) => ({ ...r, v }))), { status: 400, body: { error: 'a record of form 3' } });
  }
  assert.equal((await keep(b, ADA, TABLE, record(({ log, ...r }) => ({ ...r, record: log })))).status, 400, 'no log');
  assert.equal((await keep(b, ADA, TABLE, ' '.repeat(recordMost + 1))).status, 413);
  assert.equal((await keep(null, ADA, TABLE, record())).status, 503, 'no bucket bound');
  assert.equal(b.kept.size, 0);
});

test('only a record with moves its sender signed at that table in it', async () => {
  const b = bucket();
  // Somebody's key written into a seat of a game they never played:
  // nothing in it is theirs.
  const seated = record((r) => ({ ...r, spec: { ...r.spec, seats: r.spec.seats.map((s, i) => (i === 0 ? { key: CY } : s)) } }));
  assert.equal((await keep(b, CY, TABLE, seated)).status, 403, 'seated, but none of it signed by them');
  // Their own events, each said differently from what they signed.
  const changed = record((r) => {
    for (const d of r.log) if (d.e?.author === ADA) d.e.body = { ...d.e.body, hand: d.e.body.hand + 1 };
    return r;
  });
  assert.equal((await keep(b, ADA, TABLE, changed)).status, 403, 'not what was signed');
  // Their own events, with signatures that are not theirs.
  const forged = record((r) => {
    for (const d of r.log) if (d.e?.author === ADA) d.e.sig = 'ab'.repeat(64);
    return r;
  });
  assert.equal((await keep(b, ADA, TABLE, forged)).status, 403, 'not signed by them');
  assert.equal(b.kept.size, 0);
  assert.equal((await keep(b, ADA, TABLE, record())).status, 200, 'and the game as it was is kept');
});

test('where the service signs licences, only seats the app would show: each person\'s licensed for its key, each account once', async () => {
  // The worker's tests' service: BIP-340's second pair.
  const [other, service] = keys;
  const by = (pair) => ({ signer, secret: pair.secret, service: pair.public });
  const keepChecked = (text) => keepRecord(bucket(), ADA, TABLE, text, { verify: signer.verify, service: service.public });
  const A = 'a'.repeat(32);
  const B = 'b'.repeat(32);
  const adas = await licenceFor(ADA, A, '2026-11-01', by(service));
  const baos = await licenceFor(BAO, B, '2026-11-01', by(service));
  const seated = (bao) => record((r) => {
    r.spec.seats[0].licence = adas;
    if (bao) r.spec.seats[1].licence = bao;
    return r;
  });
  for (const [text, error, what] of [
    [record(), 'seat 0 has no licence for its key', 'none at all'],
    [seated(null), 'seat 1 has no licence for its key', 'none at one seat'],
    [seated(adas), 'seat 1 has no licence for its key', 'another device\'s'],
    [seated({ ...baos, account: A }), 'seat 1 has no licence for its key', 'changed after it was signed'],
    [seated({ ...baos, sig: 'ab' }), 'seat 1 has no licence for its key', 'not a signature'],
    [seated(await licenceFor(BAO, B, '2026-11-01', by(other))), 'seat 1 has no licence for its key', 'another service\'s'],
    [seated(await licenceFor(BAO, A, '2026-11-01', by(service))), 'seat 1 is an account already seated', 'one account at two seats'],
  ]) {
    assert.deepEqual(await keepChecked(text), { status: 403, body: { error } }, what);
  }
  assert.deepEqual(await keepChecked(seated(baos)), { status: 200, body: { kept: true } });
  // Not its date: a game is read, and sent, after licences run out.
  assert.deepEqual(await keepChecked(seated(await licenceFor(BAO, B, '2020-01-01', by(service)))), { status: 200, body: { kept: true } });
});

test('a kept record comes back as it was sent, packed and for good; none is a 404', async () => {
  const b = bucket();
  await keep(b, ADA, TABLE, record());
  const res = await recordResponse(b, TABLE);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-encoding'), 'gzip');
  assert.match(res.headers.get('cache-control'), /immutable/);
  assert.equal(gunzipSync(Buffer.from(await res.arrayBuffer())).toString(), record());
  assert.equal((await recordResponse(b, 'f'.repeat(32))).status, 404);
  assert.equal((await recordResponse(b, 'nope')).status, 400);
});

test('a game sent after an account was forgotten is kept without its name, and no name of it is put beside it after', async () => {
  const FORGOTTEN = 'f'.repeat(32);
  const OTHER = 'e'.repeat(32);
  const licence = (key, account) => ({ key, account, until: '2026-11-01', plan: 'annual', sig: '00'.repeat(64) });
  // Bao's seat is the forgotten account's: it played on while its last
  // licence ran, and each device sends the game, naming both.
  const licensed = (r) => {
    r.spec.seats[0].licence = licence(ADA, OTHER);
    r.spec.seats[1].licence = licence(BAO, FORGOTTEN);
    r.names = { 0: 'Ada', 1: 'Bao' };
    return r;
  };
  const forgotten = () => {
    const b = bucket();
    b.kept.set(forgottenKey(FORGOTTEN), { body: Buffer.from('{}') });
    return b;
  };
  const namesKept = (b) => JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString()).names;
  // Ada's device sends first, and then Bao's: Ada's name is kept, and
  // Bao's never is.
  const b = forgotten();
  assert.deepEqual(await keep(b, ADA, TABLE, record(licensed)), { status: 200, body: { kept: true } });
  assert.deepEqual(namesKept(b), { 0: 'Ada' });
  assert.deepEqual({ ...JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString()), names: undefined }, { ...JSON.parse(record(licensed)), names: undefined }, 'the rest as it was sent');
  const puts = b.puts.length;
  assert.deepEqual(await keep(b, BAO, TABLE, record(licensed)), { status: 200, body: { kept: true, already: true } });
  assert.equal(b.puts.length, puts, 'nothing written');
  assert.deepEqual(namesKept(b), { 0: 'Ada' });

  // Bao's device first: no names at all, and then Ada's goes in.
  const b2 = forgotten();
  await keep(b2, BAO, TABLE, record(licensed));
  assert.equal('names' in JSON.parse(gunzipSync(b2.kept.get(`tables/${TABLE}.json`).body).toString()), false);
  assert.deepEqual(await keep(b2, ADA, TABLE, record(licensed)), { status: 200, body: { kept: true, already: true } });
  assert.deepEqual(namesKept(b2), { 0: 'Ada' });

  // A forgotten account's device sending again, with another name, has
  // none put beside the game either.
  const b3 = forgotten();
  await keep(b3, ADA, TABLE, record(licensed));
  await keep(b3, BAO, TABLE, record((r) => ({ ...licensed(r), names: { 1: 'Bao Again' } })));
  assert.deepEqual(namesKept(b3), { 0: 'Ada' });

  // The seat is the account's in the game kept, though the copy sent says
  // another account sat there: the name is not put beside it.
  const b6 = forgotten();
  await keep(b6, ADA, TABLE, record(licensed));
  assert.deepEqual(await keep(b6, BAO, TABLE, record((r) => ({ ...licensed(r), spec: { ...r.spec, seats: r.spec.seats.map((s, i) => (i === 1 ? { ...s, licence: licence(BAO, OTHER) } : s)) } }))), { status: 200, body: { kept: true, already: true } });
  assert.deepEqual(namesKept(b6), { 0: 'Ada' });

  // Nobody forgotten, and nothing but the sender's own name: kept as it
  // was sent, byte for byte, written however the device wrote it.
  const spaced = (names) => JSON.stringify({ ...licensed(structuredClone(game)), names }, null, 1);
  const b4 = bucket();
  await keep(b4, ADA, TABLE, spaced({ 0: 'Ada' }));
  assert.equal(gunzipSync(b4.kept.get(`tables/${TABLE}.json`).body).toString(), spaced({ 0: 'Ada' }));
  // Another seat's name in a record JSON.stringify would not give back as
  // it was sent: it cannot be taken out, so it is refused, not kept with
  // the name nor rewritten.
  const b5 = bucket();
  assert.deepEqual(await keep(b5, ADA, TABLE, spaced({ 0: 'Ada', 1: 'Bao' })), { status: 422, body: { error: 'a record that cannot be kept without the names taken out of it' } });
  assert.equal(b5.kept.has(`tables/${TABLE}.json`), false);
});

test('a game is kept with its sender\'s name, and without one the filter refuses; the rest as it was sent', async () => {
  const named = (names) => (r) => ({ ...r, names });
  const namesKept = (b) => JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString()).names;
  const b = bucket();
  assert.deepEqual(await keep(b, ADA, TABLE, record(named({ 0: 'Ada', 1: 'Cassandra' }))), { status: 200, body: { kept: true } });
  assert.deepEqual(namesKept(b), { 0: 'Ada' }, 'and not that of a seat that did not send it');
  assert.deepEqual({ ...JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString()), names: undefined }, { ...JSON.parse(record(named({}))), names: undefined });
  // A sender's own name that the filter refuses: no names at all.
  const b2 = bucket();
  await keep(b2, ADA, TABLE, record(named({ 0: 'Sh1t Head', 1: 'Cassandra' })));
  assert.equal('names' in JSON.parse(gunzipSync(b2.kept.get(`tables/${TABLE}.json`).body).toString()), false);
  const b3 = bucket();
  await keep(b3, ADA, TABLE, record(named({ 0: 'f u c k' })));
  assert.equal('names' in JSON.parse(gunzipSync(b3.kept.get(`tables/${TABLE}.json`).body).toString()), false);
  // Nor is it put beside a game kept already, which it leaves as it is.
  await keep(b, BAO, TABLE, record(named({ 0: 'Ada', 1: 'Sh1t Head' })));
  assert.deepEqual(namesKept(b), { 0: 'Ada' });
  // The one name it is, the name the others may see: kept byte for byte.
  const b4 = bucket();
  const fine = record(named({ 1: 'Cassandra' }));
  await keep(b4, BAO, TABLE, fine);
  assert.equal(gunzipSync(b4.kept.get(`tables/${TABLE}.json`).body).toString(), fine);
});

test("a record's names are one at most beside each person's seat, as a profile holds one; more is not a record, and a name that could not be one there is taken off", async () => {
  const named = (names) => (r) => ({ ...r, names });
  const five = Object.fromEntries(Array.from({ length: 5 }, (_, i) => [i, 'Ada']));
  for (const names of [five, ['Ada'], null, 'Ada']) {
    assert.deepEqual(await keep(bucket(), ADA, TABLE, record(named(names))), { status: 400, body: { error: 'not a record' } }, JSON.stringify(names));
  }
  // A name longer than a profile's, beside a bot's seat, beside no seat,
  // with a control character in it, or not a name at all: taken off,
  // before the filter is run over it.
  for (const names of [
    { 0: 'Ada', 1: 'a '.repeat(500000) },
    { 0: 'Ada', 2: 'Romeo' },
    { 0: 'Ada', x: 'Bao' },
    { 0: 'Ada', 1: 'Bao\u0007' },
    { 0: 'Ada', 1: 7 },
  ]) {
    const b = bucket();
    assert.deepEqual(await keep(b, ADA, TABLE, record(named(names))), { status: 200, body: { kept: true } });
    assert.deepEqual(JSON.parse(gunzipSync(b.kept.get(`tables/${TABLE}.json`).body).toString()).names, { 0: 'Ada' });
  }
});

test('a kept game notes the accounts at its seats, and the worker reads only the games that name the one being deleted', async () => {
  const A = 'a'.repeat(32);
  const B = 'b'.repeat(32);
  const b = bucket();
  const kept = (r) => JSON.parse(gunzipSync(b.kept.get(`tables/${r}.json`).body).toString());
  // Ada's and Bao's game, kept as a player sends it: its accounts noted.
  // Each device sends its copy, and puts its own name beside its seat.
  const licensed = (r) => {
    r.spec.seats[0].licence = { key: ADA, account: A };
    r.spec.seats[1].licence = { key: BAO, account: B };
    return { ...r, names: { 0: 'Ada', 1: 'Bao' } };
  };
  await keep(b, ADA, TABLE, record(licensed));
  assert.deepEqual(b.kept.get(`tables/${TABLE}.json`).custom, { from: ADA, accounts: `${A},${B}` });
  await keep(b, BAO, TABLE, record(licensed));
  assert.deepEqual(kept(TABLE).names, { 0: 'Ada', 1: 'Bao' });
  assert.deepEqual(b.kept.get(`tables/${TABLE}.json`).custom, { from: ADA, accounts: `${A},${B}` }, 'what was noted stays');
  // A game kept before accounts were noted, one of Bao's alone, and one
  // of Ada's that would not be written back as it was sent.
  const put = (id, text, custom) => b.put(`tables/${id}.json`, gzipSync(text), { httpMetadata: { contentType: 'application/json', contentEncoding: 'gzip' }, customMetadata: custom });
  const seated = (id, accounts, names) => JSON.stringify({ v: 2, spec: { id, seats: accounts.map((account, i) => ({ key: `${i}`.repeat(64), licence: { account } })) }, record: [], names });
  await put('before', seated('before', [B, A], { 0: 'Bao', 1: 'Ada' }), { from: BAO });
  await put('baos', seated('baos', [B], { 0: 'Bao' }), { from: BAO, accounts: B });
  await put('odd', '{"v":2,"spec":{"id":"odd","seats":[{"licence":{"account":"' + A + '"}}]},"record":[{"at":2.0}],"names":{"0":"Ada"}}', { from: ADA, accounts: A });
  const refused = [];
  b.read.length = 0;
  const changed = await anonymizeGames(keptGames(b), A, { refused: (key) => refused.push(key) });
  assert.deepEqual(changed, [{ key: `tables/${TABLE}.json`, named: [0] }, { key: 'tables/before.json', named: [1] }]);
  assert.deepEqual(refused, ['tables/odd.json'], 'one it would not write back is said, and the rest go on');
  assert.ok(!b.read.includes('tables/baos.json'), 'a game noted without the account is never read');
  assert.deepEqual(kept(TABLE).names, { 1: 'Bao' });
  assert.deepEqual(kept('before').names, { 0: 'Bao' });
  assert.deepEqual(kept('baos').names, { 0: 'Bao' });
  // Rewritten as it is kept: packed, said so, with what was noted beside
  // it, and now the accounts too where a game had none.
  assert.equal(b.kept.get(`tables/${TABLE}.json`).meta.contentEncoding, 'gzip');
  assert.deepEqual(b.kept.get(`tables/${TABLE}.json`).custom, { from: ADA, accounts: `${A},${B}` });
  assert.deepEqual(b.kept.get('tables/before.json').custom, { from: BAO, accounts: `${B},${A}` });
  // Without [refused], such a game stops the run, as for the operator.
  await assert.rejects(anonymizeGames(keptGames(b), A), NotAsSent);
});

// ---- the house's word, on a game in miniature -------------------------------

/// A house of the tests' own, which can sign: BIP-340's fourth pair.
const HOUSE = keys[3];
const ACCT_ADA = 'a'.repeat(32);
const ACCT_BAO = 'b'.repeat(32);
const miniSpec = {
  id: TABLE,
  seed: 1,
  house: HOUSE.public,
  seats: [{ key: ADA, licence: { key: ADA, account: ACCT_ADA } }, { key: BAO, licence: { key: BAO, account: ACCT_BAO } }, { bot: 'Romeo' }, { bot: 'Juliet' }],
};

/// The entries of a game in miniature as the referee keeps them, before
/// the house has said how it came out: the start, a play each from Ada
/// and Bao, a tick, a connection opened and one closed. [baoPlay] is
/// Bao's event in place of his play, and [spec] the table's.
async function played({ baoPlay = null, spec = miniSpec } = {}) {
  return [
    { n: 0, t: 1000, e: await said(ada, 'start', { spec }) },
    { n: 1, t: 1250, e: await said(ada, 'play', { hand: 0, turn: 4, seat: 0, card: '2C' }) },
    { n: 2, t: 1500 },
    { n: 3, t: 1750, up: BAO },
    { n: 4, t: 2000, e: baoPlay ?? (await said(bao, 'play', { hand: 0, turn: 5, seat: 1, card: '3C' })) },
    { n: 5, t: 2500, down: ADA },
  ];
}

/// The text of the record of that game as a player's device sends it,
/// with the house's word on it at the end: `result`, naming the log as it
/// stood by its length and hash. [log] makes a change to the entries
/// before the house says its word, which names them as they are then,
/// and [change] to the record after it; [word] changes what the house
/// says, or is null for no word at all; [text] is how it is written.
async function mini({ baoPlay, spec = miniSpec, log = (l) => l, word = {}, change = (r) => r, text = JSON.stringify } = {}) {
  const entries = log(await played({ baoPlay, spec }));
  const n = word?.n ?? entries.length;
  const hash = word?.hash ?? (await logHashes(entries))[n];
  const said_ = word === null ? [] : [{ n: entries.length, t: entries.at(-1).t + 100, e: await said(word.by ?? HOUSE, 'result', { n, hash, state: 'finished', totals: word.totals ?? [1, 2, 3, 4] }) }];
  return text(change({ v: 3, spec: structuredClone(spec), log: [...entries, ...said_], names: { 0: 'Ada', 1: 'Bao' } }));
}

const keepAt = (b, key, text, house = HOUSE.public, more = {}) => keepRecord(b, key, TABLE, text, { verify: signer.verify, house, ...more });
const keptAt = (b) => b.kept.get(`tables/${TABLE}.json`);
const keptText = (b) => gunzipSync(keptAt(b).body).toString();
/// Whether the copy [text], sent by [key] to a bucket with none kept, is
/// kept as carrying the house's word.
async function vouched(text, key = ADA, house = HOUSE.public) {
  const b = bucket();
  assert.equal((await keepAt(b, key, text, house)).status, 200, 'kept, whether it is vouched or not');
  return keptAt(b).custom.vouched === '1';
}

test('a copy carries the house\'s word when its log is the one the house signed for, every entry in it reads, and it is as the app writes it, and not otherwise', async () => {
  const whole = await mini();
  assert.equal(await vouched(whole), true, 'a game in miniature');
  assert.equal(await vouched(whole, BAO), true, 'from either of its players');
  // What the house signed for is the log as it stood: whatever came after
  // is a tick or a connection, and the copy is still the game.
  assert.equal(await vouched(await mini({ change: (r) => { r.log.push({ n: r.log.length, t: 9000 }, { n: r.log.length + 1, t: 9001, down: BAO }); return r; } })), true, 'ticks and connections after its word');
  // A word that names fewer entries than came before it, by the hash of those.
  assert.equal(await vouched(await mini({ word: { n: 4 } })), true, 'the log as it stood when the house said it');

  const deep = (n) => (n ? [deep(n - 1)] : []);
  const startsLikeOne = await said(ada, 'play', { hand: 0, turn: 0, seat: 0, card: '2C', spec: miniSpec });
  const hashes = await logHashes(await played());
  const swap = (r) => {
    [r.log[1], r.log[4]] = [r.log[4], r.log[1]];
    r.log.forEach((e, i) => (e.n = i));
    return r;
  };
  const wrong = [
    // The house's word is not there, is not the house's, or does not name this log.
    ['no word of the house', await mini({ word: null })],
    ['a word said by a player', await mini({ word: { by: ada } })],
    ['a word naming a hash that is not the log\'s', await mini({ word: { hash: 'ab'.repeat(32) } })],
    ['a word naming the hash of a longer log', await mini({ word: { n: 5, hash: hashes[6] } })],
    ['a word with no totals', await mini({ word: { totals: 'none' } })],
    // The log is not the one the house signed for.
    ['an entry\'s time moved on', await mini({ change: (r) => { r.log[2].t += 1; return r; } })],
    ['an entry dropped, the rest numbered again', await mini({ change: (r) => { r.log.splice(2, 1); r.log.forEach((e, i) => (e.n = i)); return r; } })],
    ['two events in another order, numbered as they were', await mini({ change: swap })],
    ['a connection of another key', await mini({ change: (r) => { r.log[3].up = ADA; return r; } })],
    // Every entry reads, and is nothing more than the referee wrote.
    ['an event changed, its id as it was', await mini({ change: (r) => { r.log[1].e.body.card = '3C'; return r; } })],
    ['an event with the signature of another', await mini({ change: (r) => { r.log[4].e.sig = r.log[1].e.sig; return r; } })],
    ['an event of another table', await mini({ change: (r) => { r.log[4].e.table = 'f'.repeat(32); return r; } })],
    ['an event with a key of its own', await mini({ change: (r) => { r.log[1].e.more = 1; return r; } })],
    ['an event no side reads: a kind it does not know', await mini({ baoPlay: await said(bao, 'wave', { at: 1 }) })],
    ['an event no side reads: a play with no card', await mini({ baoPlay: await said(bao, 'play', { hand: 0, turn: 5, seat: 1 }) })],
    ['an event nested deeper than any side reads', await mini({ baoPlay: await said(bao, 'play', { hand: 0, turn: 5, seat: 1, card: '3C', deep: deep(40) }) })],
    ['an entry holding an event and a connection', await mini({ log: (l) => { l[1] = { ...l[1], up: BAO }; return l; } })],
    ['an entry with a key of its own', await mini({ log: (l) => { l[2] = { ...l[2], x: 1 }; return l; } })],
    ['an entry not numbered by where it is', await mini({ log: (l) => { l[3].n = 7; return l; } })],
    ['a connection of something that is not a key', await mini({ log: (l) => { l[3].up = 'bao'; return l; } })],
    ['a time that is not a whole number', await mini({ log: (l) => { l[2].t = 1500.5; return l; } })],
    // The record is the table's the log says it is, and is how the app writes it.
    ['a table of another house, the house this service has having said its word', await mini({ spec: { ...miniSpec, house: 'ab'.repeat(32) } })],
    ['a spec other than the one the log starts', await mini({ change: (r) => { r.spec.seed = 2; return r; } })],
    ['a log that starts with an event that is not a start, though it says the spec', await mini({ log: (l) => [{ n: 0, t: 1000, e: startsLikeOne }, ...l.slice(1)] })],
    ['a log that does not start the table', await mini({ log: (l) => [{ n: 0, t: 1000 }, ...l.slice(1)] })],
    ['a record with a key of its own', await mini({ change: ({ names, ...r }) => ({ ...r, more: 'x'.repeat(1000), names }) })],
    // (Each with the sender's own name only, since another's cannot be taken out of text not written as it is here.)
    ['a record written with spaces', await mini({ change: (r) => { r.names = { 0: 'Ada' }; return r; }, text: (r) => JSON.stringify(r, null, 1) })],
    ['a number written another way', await mini({ change: (r) => { r.names = { 0: 'Ada' }; return r; }, text: (r) => JSON.stringify(r).replace('"t":1500', '"t":1500.0') })],
  ];
  for (const [what, text] of wrong) assert.equal(await vouched(text), false, what);
  // The house this service has, and no other; and none where it has none.
  assert.equal(await vouched(whole, ADA, 'ab'.repeat(32)), false, 'another house');
  assert.equal(await vouched(whole, ADA, null), false, 'none');
  assert.equal(await vouched(whole, ADA, HOUSE.public.toUpperCase()), false, 'not in the form a key is in');
  // A log with an entry no side reads is the game still, first come as it was:
  // kept, and the next copy is not put in its place.
  const b = bucket();
  assert.equal((await keepAt(b, ADA, wrong[13][1])).status, 200);
  assert.deepEqual(await keepAt(b, BAO, whole), { status: 200, body: { kept: true } }, 'but the whole game replaces it');
});

test('a copy that carries the house\'s word is kept in the place of one that does not, on the etag it read; and a copy is never put over one that does', async () => {
  const whole = await mini();
  const stub = await mini({ word: null });
  const other = await mini({ change: (r) => { r.names = { 0: 'Ada 2' }; return r; } });

  // A stub kept before any copy had the house's word, or before the word
  // was marked: replaced.
  const legacy = bucket();
  await legacy.put(`tables/${TABLE}.json`, gzipSync(stub), { httpMetadata: { contentType: 'application/json', contentEncoding: 'gzip' }, customMetadata: { from: ADA, accounts: ACCT_ADA } });
  assert.deepEqual(await keepAt(legacy, BAO, stub), { status: 200, body: { kept: true, already: true } }, 'by none that has not');
  assert.equal(keptAt(legacy).custom.vouched, undefined);
  assert.deepEqual(await keepAt(legacy, BAO, whole), { status: 200, body: { kept: true } });
  assert.deepEqual(keptAt(legacy).custom, { from: BAO, accounts: `${ACCT_ADA},${ACCT_BAO}`, vouched: '1' });
  assert.deepEqual(await keepAt(legacy, ADA, stub), { status: 200, body: { kept: true, already: true } }, 'and not put back');
  assert.equal(JSON.parse(keptText(legacy)).log.length, JSON.parse(whole).log.length);

  // Two devices at once. A stub that finds none kept, and writes while the
  // whole game is being kept, does not go over it.
  const b = bucket();
  b.before = async () => {
    b.before = null;
    await keepAt(b, BAO, whole);
  };
  assert.deepEqual(await keepAt(b, ADA, stub), { status: 200, body: { kept: true, already: true } });
  assert.equal(keptAt(b).custom.vouched, '1');
  assert.equal(keptAt(b).custom.from, BAO);
  assert.equal(JSON.parse(keptText(b)).log.length, JSON.parse(whole).log.length);

  // The whole game, replacing a stub that another whole game replaced while it was being
  // written, goes over nothing: it is tried again against what is kept.
  const c = bucket();
  await keepAt(c, ADA, stub);
  c.before = async () => {
    c.before = null;
    await keepAt(c, ADA, other);
  };
  assert.deepEqual(await keepAt(c, BAO, whole), { status: 200, body: { kept: true, already: true } });
  assert.equal(keptAt(c).custom.from, ADA, 'the first whole game stays');
  assert.deepEqual(JSON.parse(keptText(c)).names, { 0: 'Ada 2', 1: 'Bao' }, 'with the name its sender put beside it, and Bao\'s beside that');

  // A device that is changed under for good is told, and has written nothing.
  const d = bucket();
  await keepAt(d, ADA, stub);
  const puts = d.puts.length;
  d.before = async (key) => {
    d.kept.get(key).etag += '+';
  };
  assert.equal((await keepAt(d, BAO, whole)).status, 409);
  assert.equal(d.puts.length, puts);
  assert.equal(keptAt(d).custom.vouched, undefined);
});

test('each seat\'s name is put beside the game by its own device, from the seat it holds in the game kept, and by nobody else', async () => {
  const keepNames = async (b, names, key, house = HOUSE.public) => keepAt(b, key, await mini({ change: (r) => { r.names = names; return r; } }), house);
  const namesOf = (b) => JSON.parse(keptText(b)).names;
  const b = bucket();
  assert.deepEqual(await keepNames(b, { 0: 'Ada', 1: 'Not Bao' }, ADA), { status: 200, body: { kept: true } });
  assert.deepEqual(namesOf(b), { 0: 'Ada' });
  // Bao's device: its own seat, whatever it says of the others'.
  assert.deepEqual(await keepNames(b, { 0: 'Mallory', 1: 'Bao' }, BAO), { status: 200, body: { kept: true, already: true } });
  assert.deepEqual(namesOf(b), { 0: 'Ada', 1: 'Bao' });
  assert.deepEqual(keptAt(b).custom, { from: ADA, accounts: `${ACCT_ADA},${ACCT_BAO}`, vouched: '1' }, 'what was noted beside it stays');
  // The same again writes nothing; another name for its own seat does.
  const puts = b.puts.length;
  await keepNames(b, { 0: 'Ada', 1: 'Bao' }, BAO);
  assert.equal(b.puts.length, puts);
  await keepNames(b, { 1: 'Bao B' }, BAO);
  assert.deepEqual(namesOf(b), { 0: 'Ada', 1: 'Bao B' });
  // A device with no name of its own to put there reads nothing.
  b.read.length = 0;
  await keepNames(b, { 0: 'Mallory' }, BAO);
  await keepNames(b, undefined, ADA);
  assert.deepEqual(b.read, []);
  assert.deepEqual(namesOf(b), { 0: 'Ada', 1: 'Bao B' });
  // Not a name that could not be one there, nor one the filter refuses.
  for (const name of ['a '.repeat(500000), 'Bao\u0007', 7, 'Sh1t Head']) await keepNames(b, { 1: name }, BAO);
  assert.deepEqual(namesOf(b), { 0: 'Ada', 1: 'Bao B' });

  // The seat is the one that holds the sender's key in the game kept, not
  // the one the sender's copy says: a copy with the seats the other way
  // round, kept first (and neither of them vouched), puts Ada's name
  // nowhere beside her own seat.
  const swapped = bucket();
  const flipped = await mini({ change: (r) => { r.spec.seats.splice(0, 2, r.spec.seats[1], r.spec.seats[0]); r.names = { 0: 'Bao' }; return r; } });
  await keepAt(swapped, BAO, flipped, null);
  await keepNames(swapped, { 0: 'Ada' }, ADA, null);
  assert.deepEqual(namesOf(swapped), { 0: 'Bao' });

  // A game kept in a form that cannot be written as it came is left as it is.
  const odd = bucket();
  const spaced = await mini({ text: (r) => JSON.stringify(r, null, 1), change: (r) => { r.names = { 0: 'Ada' }; return r; } });
  await keepAt(odd, ADA, spaced);
  assert.equal(keptText(odd), spaced);
  const before = odd.puts.length;
  assert.deepEqual(await keepNames(odd, { 1: 'Bao' }, BAO, null), { status: 200, body: { kept: true, already: true } });
  assert.equal(odd.puts.length, before);
  assert.equal(keptText(odd), spaced);

  // Two devices at once: a name put beside the game while another is being
  // read is not written over.
  const race = bucket();
  await keepNames(race, { 0: 'Ada' }, ADA);
  race.before = async () => {
    race.before = null;
    await keepNames(race, { 0: 'Ada B' }, ADA);
  };
  await keepNames(race, { 1: 'Bao' }, BAO);
  assert.deepEqual(namesOf(race), { 0: 'Ada B', 1: 'Bao' });
  const stuck = bucket();
  await keepNames(stuck, { 0: 'Ada' }, ADA);
  stuck.before = async (key) => {
    stuck.kept.get(key).etag += '+';
  };
  assert.equal((await keepNames(stuck, { 1: 'Bao' }, BAO)).status, 409);
  assert.deepEqual(namesOf(stuck), { 0: 'Ada' });
});

test('what is noted beside a kept game, the house\'s word among it, stays when a name is taken off it', async () => {
  const b = bucket();
  await keepAt(b, ADA, await mini());
  await keepAt(b, BAO, await mini());
  assert.deepEqual(JSON.parse(keptText(b)).names, { 0: 'Ada', 1: 'Bao' });
  assert.deepEqual(await anonymizeGames(keptGames(b), ACCT_ADA), [{ key: `tables/${TABLE}.json`, named: [0] }]);
  assert.deepEqual(JSON.parse(keptText(b)).names, { 1: 'Bao' });
  assert.deepEqual(keptAt(b).custom, { from: ADA, accounts: `${ACCT_ADA},${ACCT_BAO}`, vouched: '1' });
});

test('an account marked forgotten from the worker is marked once', async () => {
  const b = bucket();
  const A = 'a'.repeat(32);
  await markForgotten(b, A, { now: Date.parse('2026-10-19T12:00:00Z') });
  assert.deepEqual(JSON.parse(b.kept.get(forgottenKey(A)).body.toString()), { forgotten: '2026-10-19' });
  await markForgotten(b, A, { now: Date.parse('2026-10-20T12:00:00Z') });
  assert.deepEqual(JSON.parse(b.kept.get(forgottenKey(A)).body.toString()), { forgotten: '2026-10-19' }, 'the first day stays');
});
