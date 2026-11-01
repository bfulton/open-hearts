// A table's referee (referee.mjs) in the relay that runs it, with no
// sockets in the way:
//
//   node --test service/do/referee.test.mjs
//
// The table's own rules are Dart's and tested there (packages/table,
// rules_test.dart, refereed_test.dart); the same table over a real
// socket to this relay is service/test/table_over_relay_test.dart. Here
// is what the referee itself is held to: whose events it takes, in what
// order, each once; what it notes of the connections to the log and of
// the time; and that a log written down comes back as it was.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { gunzipSync } from 'node:zlib';

import { wasmPath } from './host.mjs';
import { RESULT_NOT_HOUSE_WHY, VIEW_NOT_SEATED_WHY, lobbyKind, objectRelay, resultsTag, schnorrVerifier, serviceGate, tableLimits, watchKind } from './relay.mjs';
import { eventIdOf } from '../functions/records.mjs';
import { authorMost, logKind, specIdOf, startRefusal, tableReferee, tickGapMs, wakeEveryMs, wakeLimiter, writersOf } from './referee.mjs';
import { keys, signing } from './sign.mjs';
import { KEPT_MS, entryKey, tagStore } from './tag_store.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

const [ada, bao, house, stranger] = keys;

/// A spec's fields, as the shapes the referee looks at need them.
const spec = ({ id = table, seats = [{ key: ada.public }, { key: bao.public }, { bot: 'ruth' }, { bot: 'otto' }], sealed = true, withHouse = house.public } = {}) => ({
  id,
  sealed,
  target: 100,
  ...(withHouse ? { house: withHouse } : {}),
  seats,
});

/// A spec as Dart writes one (packages/table, spec.dart): its id first,
/// the hash of all the rest.
async function specOf(fields = {}) {
  const { id, ...written } = spec({ id: null, ...fields });
  return { id: await specIdOf(written), ...written };
}

/// The table here: a sealed one with the house, and an unsealed one
/// without.
const sealedSpec = await specOf();
const table = sealedSpec.id;
const plainSpec = await specOf({ sealed: false, withHouse: null });
const plain = plainSpec.id;

/// A socket that keeps what it was told, in order.
const socket = () => ({
  said: [],
  send(text) {
    this.said.push(JSON.parse(text));
  },
  of(what) {
    return this.said.filter((m) => m[0] === what);
  },
  /// The log entries it was sent, in order.
  get entries() {
    return this.of('LOG').map((m) => m[2]);
  },
});

let ids = 0;

/// A table event as a seat's device makes one (packages/table,
/// events.dart): its id the hash of what it says, and [author]'s
/// signature on it.
async function tableEvent(author, kind, body = {}, { on = table } = {}) {
  const e = { table: on, author: author.public, kind, body };
  const id = await eventIdOf(on, e);
  return { id, ...e, sig: sign.over(author, id) };
}

/// The start of the table [s] says, by [author], as a device makes it:
/// its id the hash of what it says.
async function startOf(author, s = sealedSpec) {
  const e = { table: s.id, author: author.public, kind: 'start', body: { spec: s } };
  const id = await eventIdOf(s.id, e);
  return { id, ...e, sig: sign.over(author, id) };
}

/// [e] for the log, as the line sends it: in a [logKind] event its
/// author signs.
const wrapped = (e, by = null) =>
  sign.event(by ?? keys.find((k) => k.public === e.author), { kind: logKind, content: JSON.stringify(e), tags: [['t', table]], created_at: 1000 + ids++ });

/// A clock a test moves.
function clock(at = 1_000_000) {
  const c = () => c.at;
  c.at = at;
  return c;
}

/// The relay of [table]'s tag as the object builds it, with the house
/// [house] and [entries] as kept; [wanted] counts each time the house is
/// wanted and away.
function referee({ now = clock(), entries = [], gate = null, kept = [], tag = table } = {}) {
  const wanted = { n: 0 };
  const relay = objectRelay(verify, {
    tag,
    now,
    gate,
    house: house.public,
    entries,
    keepEntry: (entry) => kept.push(entry),
    wanted: () => wanted.n++,
  });
  return { relay, wanted, kept, now };
}

const say = (relay, from, event) => relay.message(from, JSON.stringify(['EVENT', event]));

/// The gate of a deployed relay whose service is [stranger]'s key and
/// whose house is [house], on the clock [now].
const gateOn = (now = Date.now) => serviceGate({ service: stranger.public, verify, house: house.public, now });

/// An activation the service gives [key]'s device, good until [until]
/// (service/functions/licence.mjs, activationFor).
async function activationFor(key, until) {
  const account = key.public.slice(0, 32);
  const statement = `oh-active/1\n${account}\n${key.public}\n1\n${until}`;
  const digest = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(statement))).toString('hex');
  return { account, key: key.public, epoch: 1, until, sig: sign.over(stranger, digest) };
}

/// [s], open on [relay], answering its challenge as [key]: the house
/// by its key alone, anybody else with an activation good for an hour
/// of the clock [at].
async function answerAs(relay, s, key, at = Date.now) {
  const tags = key === house ? [] : [['activation', JSON.stringify(await activationFor(key, Math.floor(at() / 1000) + 3600))]];
  const e = await sign.event(key, { kind: 22242, tags: [['challenge', s.of('AUTH').at(-1)[1]], ...tags], created_at: Math.floor(at() / 1000) });
  await relay.message(s, JSON.stringify(['AUTH', e]));
  assert.equal(s.of('OK').at(-1)[2], true, s.of('OK').at(-1)[3]);
}
const ok = (from) => from.of('OK').at(-1);

test('the log begins with the table\'s start, said by one of its people, naming this relay\'s house', async () => {
  const { relay } = referee();
  const a = socket();
  relay.open(a);
  await relay.message(a, JSON.stringify(['LOG', 'log', 0]));
  assert.deepEqual(a.of('LOGEND').at(-1), ['LOGEND', 'log', 0]);

  // A move before there is a table, a start for another table, by
  // somebody not seated, naming another house, sealed with none.
  const refused = [
    await tableEvent(ada, 'play', { hand: 0, seat: 0, turn: 4, card: '2C' }),
    await tableEvent(ada, 'start', { spec: spec({ id: 'f'.repeat(32) }) }),
    await tableEvent(stranger, 'start', { spec: spec() }),
    await tableEvent(ada, 'start', { spec: spec({ withHouse: stranger.public }) }),
    await tableEvent(ada, 'start', { spec: spec({ withHouse: null }) }),
    await tableEvent(ada, 'start', { spec: { ...spec(), seats: spec().seats.slice(0, 3) } }),
  ];
  for (const e of refused) {
    await say(relay, a, await wrapped(e));
    assert.equal(ok(a)[2], false, `${e.kind} ${JSON.stringify(e.body).slice(0, 60)}`);
    assert.match(ok(a)[3], /^blocked: /);
  }
  assert.equal(a.of('LOG').length, 0);

  const start = await startOf(bao);
  await say(relay, a, await wrapped(start));
  assert.deepEqual(ok(a), ['OK', ok(a)[1], true, '']);
  assert.deepEqual(a.entries, [{ n: 0, t: 1_000_000, e: start }]);
});

test('the start is taken only as it was written, and only as the table its id names', async () => {
  // What every side reads as the same table, or no table at all: a log
  // begun with any of these would be one nobody could play.
  const signed = async (author, e) => {
    const id = await eventIdOf(e.table, e);
    return { id, ...e, sig: sign.over(author, id) };
  };
  const at = (s) => ({ table, author: ada.public, kind: 'start', body: { spec: s } });
  const cases = [
    // Under this table's id, another spec: another seed, a seat given
    // to a bot, the house left out, a field more.
    ['another spec', await wrapped(await signed(ada, at({ ...sealedSpec, seed: 2 }))), /^blocked: not the table this id names/],
    ['a seat given to a bot', await wrapped(await signed(ada, at({ ...sealedSpec, seats: [...sealedSpec.seats.slice(0, 1), { bot: 'ruth' }, ...sealedSpec.seats.slice(2)] }))), /^blocked: /],
    ['a field more', await wrapped(await signed(ada, at({ ...sealedSpec, rated: true }))), /^blocked: not the table this id names/],
    // Its id not first, as Dart never writes it.
    ['its id last', await wrapped(await signed(ada, at({ ...Object.fromEntries(Object.entries(sealedSpec).filter(([k]) => k !== 'id')), id: table }))), /^invalid: a start says its spec/],
    // Something besides the spec.
    ['more than its spec', await wrapped(await signed(ada, { ...at(sealedSpec), body: { spec: sealedSpec, also: 1 } })), /^invalid: a start says its spec/],
    // Its id not the hash of what it says, its signature good.
    ['an id of its own', await wrapped({ ...(await startOf(ada)), id: '7'.repeat(64), sig: sign.over(ada, '7'.repeat(64)) }), /^invalid: an event's id/],
  ];
  // Written otherwise than it comes out written again: the bytes every
  // side hashes would not be the ones hashed here.
  const loose = await startOf(ada);
  cases.push(['written loosely', await sign.event(ada, { kind: logKind, content: JSON.stringify(loose, null, 1), tags: [['t', table]] }), /^invalid: a start is taken as it was written/]);
  for (const [what, event, why] of cases) {
    const { relay } = referee();
    const a = socket();
    relay.open(a);
    await say(relay, a, event);
    assert.equal(ok(a)[2], false, what);
    assert.match(ok(a)[3], why, what);
    assert.equal(relay.entries.length, 0, what);
  }
  // And worked out alike from the text alone.
  assert.equal(await startRefusal(JSON.stringify(await startOf(ada)), table), null);
  assert.equal(await startRefusal(JSON.stringify(await tableEvent(ada, 'play', {})), table), null, 'not a start: take says why not');
});

test('two starts at once begin the log once', async () => {
  const { relay } = referee();
  const a = socket();
  const b = socket();
  relay.open(a);
  relay.open(b);
  const [ea, eb] = [await wrapped(await startOf(ada)), await wrapped(await startOf(bao))];
  await Promise.all([say(relay, a, ea), say(relay, b, eb)]);
  assert.equal(relay.entries.length, 1);
  assert.deepEqual([ok(a)[2], ok(b)[2]], [true, true]);
  assert.deepEqual([ok(a)[3], ok(b)[3]].sort(), ['', 'duplicate: the table has started']);
});

test('an unsealed table may name no house; a house it names is this relay\'s', () => {
  const unsealed = spec({ sealed: false, withHouse: null });
  assert.deepEqual([...writersOf(unsealed, table, house.public).writers], [ada.public, bao.public]);
  assert.deepEqual([...writersOf(spec(), table, house.public).writers], [ada.public, bao.public, house.public]);
  assert.equal(writersOf(spec(), table, null), null, 'a relay with no house referees no sealed table');
  assert.equal(writersOf(spec({ sealed: false, withHouse: stranger.public }), table, house.public), null);
  assert.equal(writersOf({ ...spec(), seats: [{ bot: 'a' }, { bot: 'b' }, { bot: 'c' }, { bot: 'd' }] }, table, house.public), null, 'nobody to start it');
  assert.equal(writersOf({ ...spec(), seats: [{ key: 'ab' }, ...spec().seats.slice(1)] }, table, house.public), null);
});

test('after the start, the people\'s and the house\'s events, in the order they came, each once', async () => {
  const now = clock();
  const { relay } = referee({ now });
  const a = socket();
  const watcher = socket();
  relay.open(a);
  relay.open(watcher);
  await relay.message(watcher, JSON.stringify(['LOG', 'w', 0]));
  const start = await startOf(ada);
  await say(relay, a, await wrapped(start));

  const step = await tableEvent(house, 'deal', { hand: 0, seat: 2, turn: -14 });
  now.at += 40;
  await say(relay, a, await wrapped(step));
  const play = await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 1 });
  now.at += 3;
  await say(relay, a, await wrapped(play));
  assert.deepEqual(
    watcher.entries.map((e) => [e.n, e.t, e.e.id]),
    [
      [0, 1_000_000, start.id],
      [1, 1_000_040, step.id],
      [2, 1_000_043, play.id],
    ],
  );

  // Said again — by the same device unsure it got through, or in
  // another wrapper — it is in the log once.
  await say(relay, a, await wrapped(play));
  assert.deepEqual(ok(a).slice(2), [true, 'duplicate: already in the log']);
  // Another person's start, once the table has one, is not the table's.
  await say(relay, a, await wrapped(await startOf(bao)));
  assert.deepEqual(ok(a).slice(2), [true, 'duplicate: the table has started']);

  // Nobody else's; not one said for its author by somebody else; not
  // one whose signature is not its author's; not another table's.
  const refusals = [
    [await wrapped(await tableEvent(stranger, 'play', { hand: 0, seat: 0, turn: 4 })), /^blocked: not one of the table/],
    [await wrapped(await tableEvent(ada, 'play', { hand: 0, seat: 0, turn: 4 }), bao), /^blocked: a table event is said by its author/],
    [await wrapped({ ...(await tableEvent(ada, 'play', { hand: 0, seat: 0, turn: 4 })), sig: sign.over(bao, '0'.repeat(64)) }), /^invalid: not signed/],
    [await wrapped(await tableEvent(ada, 'play', { hand: 0, seat: 0, turn: 4 }, { on: 'e'.repeat(32) })), /^blocked: this log is table/],
    [await sign.event(ada, { kind: logKind, content: 'not json', tags: [['t', table]] }), /^invalid: not a table event/],
    [await sign.event(ada, { kind: logKind, content: JSON.stringify({ id: 'short', author: ada.public, sig: '' }), tags: [['t', table]] }), /^invalid: not a table event/],
  ];
  for (const [event, why] of refusals) {
    await say(relay, a, event);
    assert.equal(ok(a)[2], false);
    assert.match(ok(a)[3], why);
  }
  assert.equal(watcher.entries.length, 3);
  assert.equal(relay.entries.length, 3);
});

test('a view of the table is carried only from one of its people, once its start says who they are', async () => {
  const { relay } = referee();
  const a = socket();
  const watcher = socket();
  relay.open(a);
  relay.open(watcher);
  await relay.message(watcher, JSON.stringify(['REQ', 'watch', { kinds: [watchKind], '#t': [table] }]));
  await say(relay, a, await wrapped(await startOf(ada)));
  const said = (key, content) => sign.event(key, { kind: watchKind, content: JSON.stringify(content), tags: [['t', table]], created_at: 1000 + ++ids });
  const view = { table, seq: 120, hand: 2, phase: 'play' };

  // A stranger's game of its own, shown to whoever watches: not carried.
  await say(relay, a, await said(stranger, { view: { ...view, seq: 2 ** 53 - 1, phase: 'gameOver' } }));
  assert.deepEqual(ok(a).slice(2), [false, VIEW_NOT_SEATED_WHY]);
  // A seated player's, and anybody saying they watch: carried.
  const players = await said(bao, { view });
  await say(relay, a, players);
  assert.equal(ok(a)[2], true, ok(a)[3]);
  const watching = await said(stranger, { watching: true });
  await say(relay, a, watching);
  assert.equal(ok(a)[2], true, ok(a)[3]);
  assert.deepEqual(watcher.of('EVENT').map((m) => m[2].id), [players.id, watching.id]);
});

test('an event is taken under the id its bytes hash to and no other, so nobody can say another\'s event first', async () => {
  const { relay } = referee();
  const a = socket();
  relay.open(a);
  await say(relay, a, await wrapped(await startOf(ada)));
  // Bao's leave says only his seat, so anybody can work out its id.
  // Ada signs an event of her own under that id, for the log to hold
  // it before Bao says his.
  const leave = await tableEvent(bao, 'leave', { seat: 1 });
  const squat = { id: leave.id, table, author: ada.public, kind: 'leave', body: {}, sig: sign.over(ada, leave.id) };
  await say(relay, a, await wrapped(squat));
  assert.deepEqual(ok(a).slice(2), [false, 'invalid: an event\'s id is the hash of what it says']);
  await say(relay, a, await wrapped(leave));
  assert.deepEqual(ok(a).slice(2), [true, '']);
  assert.deepEqual(relay.entries.map((entry) => entry.e.author), [ada.public, bao.public]);
});

test('every event of a real game, as the table made it, is taken as it came', async () => {
  // Four people and the rig's house to the end of a game to fifty
  // (packages/table, tool/game_fixture.dart).
  const fixture = new URL('../../packages/table/test/fixtures/refereed_four.json.gz', import.meta.url);
  const game = JSON.parse(gunzipSync(readFileSync(fixture)).toString());
  const events = game.log.filter((entry) => entry.e).map((entry) => entry.e);
  const kept = tableReferee({ table: game.spec.id, verify, house: game.spec.house });
  for (const e of events) {
    // As the relay hands it on, the outer event's id and signature checked.
    const answer = await kept.take({ pubkey: e.author, content: JSON.stringify(e) });
    assert.deepEqual(answer, { ok: true, why: '' }, `${e.kind} by ${e.author.slice(0, 6)}`);
  }
  assert.deepEqual(kept.entries.map((entry) => entry.e), events);
  assert.ok(events.length > 200);
});

test('each person\'s events fill no more than their share of the log, also once it is woken from storage, and the house\'s are not held to it', async () => {
  const { relay, kept } = referee();
  const a = socket();
  relay.open(a);
  const start = await startOf(ada);
  await say(relay, a, await wrapped(start));
  // Events near the most a socket may send.
  const big = (author, i) => tableEvent(author, 'play', { hand: 0, seat: 0, turn: 4, pad: 'x'.repeat(100_000), i });
  const full = 'blocked: this author has filled its share of the log';
  let share = JSON.stringify(start).length;
  const answers = [];
  for (let i = 0; i < 25; i++) {
    const e = await big(ada, i);
    await say(relay, a, await wrapped(e));
    const fits = share + JSON.stringify(e).length <= authorMost;
    if (fits) share += JSON.stringify(e).length;
    assert.deepEqual(ok(a).slice(2), fits ? [true, ''] : [false, full], `event ${i}`);
    answers.push(ok(a)[2]);
  }
  assert.ok(answers.includes(true) && answers.at(-1) === false);
  // Bao's events, and the house's past any one person's share.
  await say(relay, a, await wrapped(await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 1 })));
  assert.deepEqual(ok(a).slice(2), [true, '']);
  for (let i = 0; i < 25; i++) {
    await say(relay, a, await wrapped(await big(house, i)));
    assert.deepEqual(ok(a).slice(2), [true, ''], `the house's event ${i}`);
  }

  // The object woken from what it wrote down: Ada's share is as full.
  const again = referee({ entries: structuredClone(kept) });
  again.relay.open(a);
  await say(again.relay, a, await wrapped(await big(ada, 25)));
  assert.deepEqual(ok(a).slice(2), [false, full]);
  await say(again.relay, a, await wrapped(await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 2 })));
  assert.deepEqual(ok(a).slice(2), [true, '']);
});

test('an event is kept as a table event has it, and whatever else it carries is left out', async () => {
  const { relay } = referee();
  const a = socket();
  relay.open(a);
  const play = await tableEvent(ada, 'play', { hand: 0, seat: 0, turn: 4 });
  await say(relay, a, await wrapped(await startOf(ada)));
  await say(relay, a, await sign.event(ada, { kind: logKind, content: JSON.stringify({ ...play, padding: 'x'.repeat(1000) }), tags: [['t', table]] }));
  assert.deepEqual(relay.entries[1].e, play);
});

test('a key\'s last socket on the log closing is noted, and its first opening again', async () => {
  // The wall clock: an answer to the challenge is checked against it.
  const { relay } = referee({ gate: gateOn(), now: Date.now });
  const as = async (key) => {
    const s = socket();
    relay.open(s);
    await answerAs(relay, s, key);
    return s;
  };
  const a1 = await as(ada);
  const a2 = await as(ada);
  const b = await as(bao);
  const s = await as(stranger);
  for (const x of [a1, a2, b, s]) await relay.message(x, JSON.stringify(['LOG', 'log', 0]));
  // Before the start nothing is noted: there is no table to note it of.
  relay.close(s);
  await say(relay, a1, await wrapped(await startOf(ada)));
  assert.equal(relay.entries.length, 1);

  relay.close(a1);
  assert.equal(relay.entries.length, 1, 'one of two sockets: still there');
  relay.close(a2);
  assert.deepEqual(relay.entries.at(-1).down, ada.public);
  // Gone, and gone again by another socket that was not following: once.
  const a3 = await as(ada);
  relay.close(a3);
  assert.equal(relay.entries.length, 2);
  // Back, and the entry that says so is in what the socket is sent.
  const a4 = await as(ada);
  await relay.message(a4, JSON.stringify(['LOG', 'log', 0]));
  assert.deepEqual(relay.entries.at(-1).up, ada.public);
  assert.deepEqual(a4.entries.map((e) => e.n), [0, 1, 2]);
  // Its subscription closed is its connection to the log closed.
  await relay.message(a4, JSON.stringify(['CLOSE', 'log']));
  assert.deepEqual(relay.entries.at(-1).down, ada.public);
  // Somebody not at the table comes and goes unnoted.
  const s2 = await as(stranger);
  await relay.message(s2, JSON.stringify(['LOG', 'log', 0]));
  relay.close(s2);
  assert.equal(relay.entries.length, 4);
  assert.deepEqual(b.entries.map((e) => Object.keys(e).filter((k) => k !== 'n' && k !== 't')[0]), ['e', 'down', 'up', 'down']);
});

test('a socket whose answer has run out is sent nothing more of the log', async () => {
  const at = clock(Date.now());
  const { relay } = referee({ gate: gateOn(at), now: at, entries: [{ n: 0, t: 1, e: await startOf(ada) }] });
  // Ada's device, on an activation good for an hour; the house, on its
  // key, for a day.
  const a = socket();
  relay.open(a);
  await answerAs(relay, a, ada, at);
  await relay.message(a, JSON.stringify(['LOG', 'log', 0]));
  const h = socket();
  relay.open(h);
  await answerAs(relay, h, house, at);
  await say(relay, h, await wrapped(await tableEvent(house, 'deal', { hand: 0, seat: 1, turn: -15 })));
  assert.equal(a.of('LOG').length, 2);
  // Two hours on: the house is heard, and Ada's socket is sent none of it.
  at.at += 2 * 3600 * 1000;
  await say(relay, h, await wrapped(await tableEvent(house, 'deal', { hand: 0, seat: 3, turn: -13 })));
  assert.equal(relay.entries.length, 3);
  assert.equal(a.of('LOG').length, 2);
});

test('the log from any entry, then its end, then every entry as it comes', async () => {
  const { relay } = referee();
  const a = socket();
  relay.open(a);
  await say(relay, a, await wrapped(await startOf(ada)));
  for (let i = 0; i < 3; i++) await say(relay, a, await wrapped(await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 1, i })));
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['LOG', 'mine', 2]));
  assert.deepEqual(late.said.map((m) => (m[0] === 'LOG' ? m[2].n : m)), [2, 3, ['LOGEND', 'mine', 4]]);
  await say(relay, a, await wrapped(await tableEvent(ada, 'pass', { hand: 0, seat: 0, turn: 0 })));
  assert.equal(late.said.at(-1)[2].n, 4);
  assert.equal(late.said.at(-1)[1], 'mine');
  // Asked again from where it is, as a line that saw a gap does: the
  // same subscription, from there.
  await relay.message(late, JSON.stringify(['LOG', 'mine', 4]));
  assert.deepEqual(late.said.slice(-2).map((m) => m[0]), ['LOG', 'LOGEND']);
  // Nonsense is said to be.
  await relay.message(late, JSON.stringify(['LOG', 'mine', -1]));
  await relay.message(late, JSON.stringify(['LOG', 'mine']));
  assert.equal(late.of('NOTICE').length, 2);
});

test('asking for the log counts against the socket\'s rate, as publishing does', async () => {
  const { relay } = referee();
  const a = socket();
  relay.open(a);
  await say(relay, a, await wrapped(await startOf(ada)));
  // The clock stands still: what the socket spends does not come back.
  for (let i = 0; i < tableLimits.burst; i++) await relay.message(a, JSON.stringify(['LOG', 'log', 0]));
  assert.equal(a.of('LOGEND').length, tableLimits.burst - 1, 'the start took one');
  assert.deepEqual(a.said.at(-1), ['CLOSED', 'log', 'rate-limited: slow down']);
});

test('a tick when asked, once the table has begun, no oftener than the gap', async () => {
  const now = clock();
  const { relay } = referee({ now });
  const a = socket();
  relay.open(a);
  await relay.message(a, JSON.stringify(['TICK']));
  assert.equal(relay.entries.length, 0);
  await say(relay, a, await wrapped(await startOf(ada)));
  now.at += tickGapMs - 1;
  await relay.message(a, JSON.stringify(['TICK']));
  assert.equal(relay.entries.length, 1);
  now.at += 1;
  await relay.message(a, JSON.stringify(['TICK']));
  await relay.message(a, JSON.stringify(['TICK']));
  assert.deepEqual(relay.entries.slice(1), [{ n: 1, t: 1_000_000 + tickGapMs }]);
});

test('a tick only for the table\'s people and its house, and none once the house has said how the game came out', async () => {
  const now = clock();
  const { relay, kept } = referee({ now, gate: gateOn(now) });
  const [a, h, s] = [socket(), socket(), socket()];
  for (const [x, key] of [[a, ada], [h, house], [s, stranger]]) {
    relay.open(x);
    await answerAs(relay, x, key, now);
  }
  await say(relay, a, await wrapped(await startOf(ada)));
  const tick = async (x) => {
    now.at += tickGapMs;
    const before = relay.entries.length;
    await relay.message(x, JSON.stringify(['TICK']));
    return relay.entries.length - before;
  };
  assert.equal(await tick(s), 0, 'somebody not at the table');
  assert.equal(await tick(a), 1);
  assert.equal(await tick(h), 1);
  await say(relay, h, await wrapped(await tableEvent(house, 'result', { n: 3, hash: 'x', state: 'finished', totals: [0, 0, 0, 0] })));
  assert.equal(await tick(a), 0, 'the game is over');
  assert.equal(await tick(h), 0);

  // The same for an object woken from the log as it was written down.
  const again = referee({ now, gate: gateOn(now), entries: structuredClone(kept) });
  const b = socket();
  again.relay.open(b);
  await answerAs(again.relay, b, ada, now);
  now.at += tickGapMs;
  await again.relay.message(b, JSON.stringify(['TICK']));
  assert.equal(again.relay.entries.length, kept.length);
});

test('the clock never runs back in the log', async () => {
  const now = clock();
  const { relay } = referee({ now });
  const a = socket();
  relay.open(a);
  await say(relay, a, await wrapped(await startOf(ada)));
  now.at -= 5000;
  await say(relay, a, await wrapped(await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 1 })));
  assert.equal(relay.entries[1].t, relay.entries[0].t);
});

test('the house is wanted as a sealed table starts, and while it is away, until it has said how the game came out', async () => {
  const { relay, wanted } = referee();
  const a = socket();
  relay.open(a);
  await say(relay, a, await wrapped(await startOf(ada)));
  assert.equal(wanted.n, 1);
  await say(relay, a, await wrapped(await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 1 })));
  assert.equal(wanted.n, 2, 'away still');
  const h = socket();
  relay.open(h);
  // Without the gate, nobody answered as anybody: a test of the house's
  // own socket is the gate's (the test above). Here the house's word.
  await say(relay, h, await wrapped(await tableEvent(house, 'result', { n: 2, hash: 'x', state: 'finished', totals: [0, 0, 0, 0] })));
  await say(relay, a, await wrapped(await tableEvent(ada, 'leave', { seat: 0 })));
  assert.equal(wanted.n, 2, 'said: not wanted again');

  // An unsealed table wants no house.
  const unsealed = referee({ tag: plain });
  const b = socket();
  unsealed.relay.open(b);
  await say(unsealed.relay, b, await wrapped(await startOf(ada, plainSpec)));
  assert.equal(unsealed.relay.entries.length, 1);
  assert.equal(unsealed.wanted.n, 0);
});

test('a log written down comes back as it was, and goes on from there', async () => {
  const now = clock();
  const first = referee({ now, tag: plain });
  const a = socket();
  first.relay.open(a);
  await first.relay.message(a, JSON.stringify(['LOG', 'log', 0]));
  await say(first.relay, a, await wrapped(await startOf(ada, plainSpec)));
  const pass = await tableEvent(bao, 'pass', { hand: 0, seat: 1, turn: 1 }, { on: plain });
  await say(first.relay, a, await wrapped(pass));
  assert.deepEqual(first.kept, first.relay.entries);

  // The object woke with both people's sockets still open, each
  // carrying its subscription and who it answered as: nothing changed,
  // and nothing is noted.
  now.at += 60_000;
  const again = referee({ now, entries: structuredClone(first.kept), tag: plain });
  const until = Math.floor(Date.now() / 1000) + 600;
  again.relay.open(a, null, { account: null, key: ada.public, epoch: 0, until }, 'log');
  again.relay.open(socket(), null, { account: null, key: bao.public, epoch: 0, until }, 'log');
  again.relay.settle();
  assert.equal(again.relay.entries.length, 2);
  // An event it took before is still taken once.
  await say(again.relay, a, await wrapped(pass));
  assert.deepEqual(ok(a).slice(2), [true, 'duplicate: already in the log']);
  const play = await tableEvent(ada, 'play', { hand: 0, seat: 0, turn: 4 }, { on: plain });
  await say(again.relay, a, await wrapped(play));
  assert.deepEqual(a.entries.at(-1), { n: 2, t: 1_060_000, e: play });

  // A log with a gap in it is kept as far as it runs.
  const gapped = referee({ entries: [first.kept[0], { ...first.kept[1], n: 5 }], tag: plain });
  assert.equal(gapped.relay.entries.length, 1);
});

test('woken with nobody on the log that the log says is there, they are noted as gone', async () => {
  const gate = gateOn();
  const entries = [{ n: 0, t: 1, e: await startOf(ada) }, { n: 1, t: 2, down: bao.public }];
  const { relay, wanted } = referee({ gate, entries });
  // Ada's socket came back with the object, Bao's gone already; the
  // house is not there.
  const a = socket();
  relay.open(a, null, { account: null, key: ada.public, epoch: 0, until: Math.floor(Date.now() / 1000) + 600 }, 'log');
  relay.settle();
  assert.deepEqual(relay.entries.slice(2).map((e) => e.down), [house.public]);
  assert.equal(wanted.n, 2, 'once for the entry, once for the house\'s absence');
});

test('only a table\'s tag keeps a log', async () => {
  const relay = objectRelay(verify, { tag: 'room-1234', house: house.public });
  const a = socket();
  relay.open(a);
  await relay.message(a, JSON.stringify(['LOG', 'log', 0]));
  assert.deepEqual(a.said.at(-1), ['CLOSED', 'log', 'blocked: only a table\'s tag keeps a log']);
  await relay.message(a, JSON.stringify(['TICK']));
  assert.equal(a.said.at(-1)[0], 'NOTICE');
  await relay.message(a, JSON.stringify(['EVENT', await wrapped(await startOf(ada))]));
  assert.equal(ok(a)[2], false);
});

test('the results are the house\'s to say, and nobody else\'s', async () => {
  const relay = objectRelay(verify, { tag: resultsTag, house: house.public });
  const a = socket();
  relay.open(a);
  const result = (key) => sign.event(key, { kind: lobbyKind, content: '{"kind":"result","v":3}', tags: [['t', resultsTag]], created_at: 2000 + ids++ });
  await relay.message(a, JSON.stringify(['EVENT', await result(ada)]));
  assert.deepEqual(ok(a).slice(2), [false, RESULT_NOT_HOUSE_WHY]);
  await relay.message(a, JSON.stringify(['EVENT', await result(house)]));
  assert.deepEqual(ok(a).slice(2), [true, '']);
  assert.equal(relay.stored, 1);
  // A relay with no house takes no result at all.
  const none = objectRelay(verify, { tag: resultsTag });
  none.open(a);
  await none.message(a, JSON.stringify(['EVENT', await result(house)]));
  assert.equal(ok(a)[2], false);
});

test('before its answer, a socket\'s LOG and TICK wait with everything else it said', async () => {
  const { relay } = referee({ gate: gateOn(), now: Date.now, entries: [{ n: 0, t: 1, e: await startOf(ada) }] });
  const a = socket();
  relay.open(a);
  await relay.message(a, JSON.stringify(['LOG', 'log', 0]));
  await relay.message(a, JSON.stringify(['TICK']));
  assert.equal(a.of('LOG').length, 0);
  await answerAs(relay, a, ada);
  assert.equal(a.of('LOG').length, 2, 'the log, and the tick it asked for');
  assert.deepEqual(a.of('LOGEND')[0], ['LOGEND', 'log', 1]);

  // One refused is told its log is closed, and why.
  const b = socket();
  relay.open(b);
  const bad = await sign.event(bao, { kind: 22242, tags: [['challenge', b.of('AUTH')[0][1]]], created_at: Math.floor(Date.now() / 1000) });
  await relay.message(b, JSON.stringify(['AUTH', bad]));
  await relay.message(b, JSON.stringify(['LOG', 'log', 0]));
  assert.equal(b.said.at(-1)[0], 'CLOSED');
  assert.equal(b.said.at(-1)[1], 'log');
});

test('the log is written down entry by entry, and goes a day after its last', async () => {
  const rows = new Map();
  let alarm = null;
  const storage = {
    rows,
    async get(k) {
      return rows.get(k);
    },
    async put(k, v) {
      rows.set(k, structuredClone(v));
    },
    async delete(k) {
      const all = Array.isArray(k) ? k : [k];
      assert.ok(all.length <= 128, 'a delete is given at most 128 keys');
      for (const x of all) rows.delete(x);
    },
    async list({ prefix = '', end = null, limit = Infinity, reverse = false } = {}) {
      const sorted = [...rows.keys()].filter((k) => k.startsWith(prefix) && (end === null || k < end)).sort();
      if (reverse) sorted.reverse();
      return new Map(sorted.slice(0, limit).map((k) => [k, rows.get(k)]));
    },
    async getAlarm() {
      return alarm;
    },
    async setAlarm(at) {
      alarm = at;
    },
  };
  const kept = tagStore(storage, table);
  const entries = Array.from({ length: 300 }, (_, n) => ({ n, t: 1000 + n }));
  for (const e of entries) await kept.keepEntry(e, { now: 0 });
  assert.ok(rows.has(entryKey(299)));
  assert.notEqual(alarm, null);
  assert.deepEqual(await kept.loadLog(), entries);

  // A day after the first entry is not a day after the last.
  assert.equal(await kept.sweep({ now: 1000 + KEPT_MS }), false);
  assert.equal((await kept.loadLog()).length, 300);
  // A day after the last, it all goes, and there is nothing to sweep for.
  alarm = null;
  assert.equal(await kept.sweep({ now: 1299 + KEPT_MS }), true);
  assert.deepEqual(await kept.loadLog(), []);
  assert.equal(alarm, null);
});

test('the house is woken at most once in a while, and a wake wanted sooner is made when the while is up, if still wanted', async () => {
  const now = clock(0);
  const timers = [];
  const woken = [];
  let wanted = true;
  const want = wakeLimiter({ wake: () => woken.push(now()), stillWanted: async () => wanted, now, later: (fn, ms) => timers.push({ fn, at: now() + ms }) });
  want();
  assert.deepEqual(woken, [0]);
  now.at = 5000;
  want();
  want();
  assert.deepEqual(woken, [0], 'not again so soon');
  assert.equal(timers.length, 1, 'one wake held back, however often it is wanted');
  assert.equal(timers[0].at, wakeEveryMs);
  now.at = wakeEveryMs;
  await timers.shift().fn();
  assert.deepEqual(woken, [0, wakeEveryMs], 'made when the while is up');
  // Held back again, and by then no longer wanted: the house came.
  now.at = wakeEveryMs + 1000;
  want();
  wanted = false;
  now.at = 2 * wakeEveryMs;
  await timers.shift().fn();
  assert.deepEqual(woken, [0, wakeEveryMs]);
  // Long after, at once.
  now.at = 10 * wakeEveryMs;
  want();
  assert.deepEqual(woken, [0, wakeEveryMs, 10 * wakeEveryMs]);
  assert.equal(timers.length, 0);
});
