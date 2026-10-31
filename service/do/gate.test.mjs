// Who the relay carries (docs/explanation/service.md, "One device at a time"): a
// device the service has given a current activation, and the house; and
// of an account, only the device in use — a superseded one's sockets
// are closed and none is opened for it.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { activationOf, authKind, createRelay, objectRelay, schnorrVerifier, serviceGate } from './relay.mjs';
import { wasmPath } from './host.mjs';
import { keys, signing } from './sign.mjs';
import { DELETED_WHY } from '../functions/deletion.mjs';

const wasm = readFileSync(wasmPath);
const verify = await schnorrVerifier(wasm);
const sign = await signing(wasm);

// The service's pair: BIP-340's published one, as the browser rig's.
const SERVICE = keys[1];
const [ADA, , BAO, CY] = keys;
const ACCOUNT = '0a'.repeat(16);
const T = 1_800_000_000;
const now = () => T * 1000;

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
const sha = async (text) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))));

/// What the service signs for [pair] (service/functions/licence.mjs,
/// activationFor), signed here with the service's own secret.
async function activation(pair, { account = ACCOUNT, epoch = 1, until = T + 3600 } = {}) {
  const digest = await sha(`oh-active/1\n${account}\n${pair.public}\n${epoch}\n${until}`);
  return { account, key: pair.public, epoch, until, sig: await sigOver(digest) };
}

/// A BIP-340 signature by the service over [digest].
async function sigOver(digest) {
  const { memory, alloc, reset, sign: s } = (await WebAssembly.instantiate(wasm, {})).instance.exports;
  reset();
  const at = { sk: alloc(32), msg: alloc(32), aux: alloc(32), sig: alloc(64) };
  const put = (to, h) => {
    const mem = new Uint8Array(memory.buffer);
    for (let i = 0; i < h.length; i += 2) mem[to + i / 2] = parseInt(h.slice(i, i + 2), 16);
  };
  put(at.sk, SERVICE.secret);
  put(at.msg, digest);
  put(at.aux, '0'.repeat(64));
  if (s(at.sk, at.msg, at.aux, at.sig) !== 1) throw new Error('sign');
  return hex(new Uint8Array(memory.buffer).slice(at.sig, at.sig + 64));
}

/// A socket that keeps what it was told, and whether it was closed.
const socket = () => ({
  said: [],
  closed: null,
  send(text) {
    this.said.push(JSON.parse(text));
  },
  close(code, why) {
    this.closed = { code, why };
  },
  of(what) {
    return this.said.filter((m) => m[0] === what);
  },
  get challenge() {
    return this.of('AUTH').at(-1)?.[1];
  },
});

/// [pair]'s answer to [s]'s challenge, showing [tags].
const answer = (pair, s, tags, created_at = T) =>
  sign.event(pair, { kind: authKind, content: '', tags: [['relay', 'wss://relay.openhearts.game/online'], ['challenge', s.challenge], ...tags], created_at });

const showing = async (pair, s, act) => answer(pair, s, [['activation', JSON.stringify(act)]]);

const beat = (pair, at = T) => sign.event(pair, { kind: 24246, content: '{"kind":"here"}', tags: [['t', 'online']], created_at: at });

const gated = (more = {}) => createRelay({ verify, now, gate: serviceGate({ service: SERVICE.public, verify, now, ...more }) });

test('an activation is the service\'s, for its key, and not run out', async () => {
  const act = await activation(ADA);
  const raw = act;
  assert.deepEqual(await activationOf(raw, SERVICE.public, verify, T), { account: ACCOUNT, key: ADA.public, epoch: 1, until: T + 3600 });
  assert.equal(await activationOf(raw, SERVICE.public, verify, T + 3600), null, 'run out');
  assert.equal(await activationOf({ ...raw, epoch: 2 }, SERVICE.public, verify, T), null, 'not what was signed');
  assert.equal(await activationOf(raw, keys[0].public, verify, T), null, 'another service\'s key');
});

test('a socket is asked who it is, and carried nothing until it has answered', async () => {
  const relay = gated();
  const a = socket();
  relay.open(a);
  assert.match(a.challenge, /^[0-9a-f]{32}$/);
  // Said before the answer: held, not refused.
  await relay.message(a, JSON.stringify(['REQ', 'online', { kinds: [24246] }]));
  await relay.message(a, JSON.stringify(['EVENT', await beat(ADA)]));
  assert.equal(a.of('EOSE').length, 0);
  assert.equal(a.of('OK').length, 0);
  const act = await activation(ADA);
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, act)]));
  const oks = a.of('OK');
  assert.equal(oks[0][2], true, 'the answer is taken');
  assert.equal(oks[1][2], true, 'and then what was held, in order');
  assert.equal(a.of('EOSE').length, 1);
});

test('what the relay took is told to its host with who said it: the account the gate let in', async () => {
  const heard = [];
  const relay = createRelay({ verify, now, gate: serviceGate({ service: SERVICE.public, verify, now }), heard: (event, who) => heard.push([event.id, who]) });
  const a = socket();
  relay.open(a);
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, await activation(ADA))]));
  const said = await beat(ADA);
  await relay.message(a, JSON.stringify(['EVENT', said]));
  assert.deepEqual(heard, [[said.id, { account: ACCOUNT, key: ADA.public, epoch: 1, until: T + 3600 }]]);
});

test('no activation, another key\'s, one run out or another challenge\'s answer: nothing carried, and told why', async () => {
  const relay = gated();
  const adas = await activation(ADA);
  const old = await activation(ADA, { until: T - 1 });
  for (const [why, made] of [
    ['none', async (s) => answer(ADA, s, [])],
    ['hers, shown by him', async (s) => showing(BAO, s, adas)],
    ['run out', async (s) => showing(ADA, s, old)],
    ['another challenge', async (s) => sign.event(ADA, { kind: authKind, content: '', tags: [['challenge', 'ff'.repeat(16)], ['activation', JSON.stringify(adas)]], created_at: T })],
    ['an old answer', async (s) => answer(ADA, s, [['activation', JSON.stringify(adas)]], T - 3600)],
  ]) {
    const s = socket();
    relay.open(s);
    await relay.message(s, JSON.stringify(['REQ', 'online', { kinds: [24246] }]));
    await relay.message(s, JSON.stringify(['AUTH', await made(s)]));
    assert.equal(s.of('OK')[0][2], false, why);
    assert.match(s.of('OK')[0][3], /^auth-required:/, why);
    assert.equal(s.of('CLOSED').length, 1, `${why}: the subscription is closed`);
    assert.equal(s.of('EOSE').length, 0, why);
    await relay.message(s, JSON.stringify(['EVENT', await beat(ADA)]));
    assert.equal(s.of('OK')[1][2], false, why);
  }
});

test('a later device of the account closes the earlier one\'s socket, and none is opened for the earlier', async () => {
  const relay = gated();
  const a = socket();
  const b = socket();
  const listener = socket();
  for (const s of [a, b, listener]) relay.open(s);
  const first = await activation(ADA, { epoch: 1 });
  const second = await activation(BAO, { epoch: 2 });
  const cys = await activation(CY, { account: '0b'.repeat(16), epoch: 1 });
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, first)]));
  await relay.message(listener, JSON.stringify(['AUTH', await showing(CY, listener, cys)]));
  await relay.message(listener, JSON.stringify(['REQ', 'online', { kinds: [24246] }]));
  await relay.message(a, JSON.stringify(['EVENT', await beat(ADA)]));
  assert.equal(listener.of('EVENT').length, 1);

  await relay.message(b, JSON.stringify(['AUTH', await showing(BAO, b, second)]));
  assert.equal(b.of('OK')[0][2], true);
  assert.match(a.of('NOTICE').at(-1)[1], /^superseded:/);
  assert.equal(a.closed?.code, 4001, 'closed, not asked to stop');
  // What it says afterwards goes nowhere.
  await relay.message(a, JSON.stringify(['EVENT', await beat(ADA, T + 1)]));
  assert.equal(listener.of('EVENT').length, 1);
  // And it is not let back in on what it was given before.
  const again = socket();
  relay.open(again);
  await relay.message(again, JSON.stringify(['AUTH', await showing(ADA, again, first)]));
  assert.match(again.of('OK')[0][3], /^superseded:/);
  // Another account is nobody's business here.
  assert.equal(listener.closed, null);
});

test('the account\'s turn says it first: the relay closes the superseded device\'s sockets when told, and asks as a socket answers', async () => {
  const asked = [];
  let current = 1;
  const relay = gated({
    seen: async (who) => {
      asked.push(who.epoch);
      return who.epoch === current ? null : 'superseded: another device of this account is in use';
    },
  });
  const a = socket();
  relay.open(a);
  const first = await activation(ADA, { epoch: 1 });
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, first)]));
  assert.equal(a.of('OK')[0][2], true);
  current = 2;
  relay.revoke(ACCOUNT, 2);
  assert.equal(a.closed?.code, 4001);
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['AUTH', await showing(ADA, late, first)]));
  assert.match(late.of('OK')[0][3], /^superseded:/);
  assert.deepEqual(asked, [1, 1], 'asked at every answer');
});

test('the account\'s turn says the account is suspended: its sockets close saying so, and a device from before is turned away in the same words, for good', async () => {
  const SUSPENDED = 'suspended: this account is suspended from live play';
  const relay = gated({ seen: async () => null });
  const a = socket();
  relay.open(a);
  const first = await activation(ADA, { epoch: 1 });
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, first)]));
  relay.revoke(ACCOUNT, 2, SUSPENDED);
  assert.deepEqual(a.closed, { code: 4001, why: SUSPENDED });
  assert.deepEqual(a.of('NOTICE').at(-1), ['NOTICE', SUSPENDED]);
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['AUTH', await showing(ADA, late, first)]));
  assert.equal(late.of('OK')[0][3], SUSPENDED);
  assert.equal(late.closed?.code, 4001, 'for good, not to be asked again');
  // A reason the relay does not know is not repeated: another device
  // is in use, as ever.
  const OTHER = '0b'.repeat(16);
  const b = socket();
  relay.open(b);
  await relay.message(b, JSON.stringify(['AUTH', await showing(BAO, b, await activation(BAO, { account: OTHER }))]));
  relay.revoke(OTHER, 2, 'whatever a caller makes up');
  assert.match(b.closed?.why, /^superseded:/);
});

test('the account\'s turn says the account was deleted: its sockets close saying so, and a device from before is turned away the same', async () => {
  const relay = gated({ seen: async () => null });
  const a = socket();
  relay.open(a);
  const first = await activation(ADA, { epoch: 1 });
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, first)]));
  relay.revoke(ACCOUNT, 2, DELETED_WHY);
  assert.deepEqual(a.closed, { code: 4001, why: DELETED_WHY });
  const late = socket();
  relay.open(late);
  await relay.message(late, JSON.stringify(['AUTH', await showing(ADA, late, first)]));
  assert.equal(late.of('OK')[0][3], DELETED_WHY);
});

test('the house by its key alone, and nobody else as the house', async () => {
  const relay = gated({ house: CY.public });
  const h = socket();
  relay.open(h);
  await relay.message(h, JSON.stringify(['AUTH', await answer(CY, h, [])]));
  assert.equal(h.of('OK')[0][2], true);
  assert.deepEqual(relay.authOf(h), { account: null, key: CY.public, epoch: 0, until: T + 24 * 60 * 60 });
  // Another key showing nothing is shown nothing: it is not the house.
  const other = socket();
  relay.open(other);
  await relay.message(other, JSON.stringify(['AUTH', await answer(BAO, other, [])]));
  assert.equal(other.of('OK')[0][2], false);
  // Nor is any key, at a relay that has no house.
  const none = gated();
  const n = socket();
  none.open(n);
  await none.message(n, JSON.stringify(['AUTH', await answer(CY, n, [])]));
  assert.equal(n.of('OK')[0][2], false);
});

test('an answer that runs out is asked for again, and the device answers with the one it has now', async () => {
  let t = T * 1000;
  const relay = createRelay({ verify, now: () => t, gate: serviceGate({ service: SERVICE.public, verify, now: () => t }) });
  const a = socket();
  relay.open(a);
  const short = await activation(ADA, { until: T + 60 });
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, short)]));
  t += 120 * 1000;
  await relay.message(a, JSON.stringify(['EVENT', await beat(ADA, T + 120)]));
  assert.equal(a.of('AUTH').length, 2, 'asked again');
  const fresh = await activation(ADA, { until: T + 3600 });
  await relay.message(a, JSON.stringify(['AUTH', await answer(ADA, a, [['activation', JSON.stringify(fresh)]], T + 120)]));
  assert.deepEqual(a.of('OK').map((m) => m[2]), [true, true, true], 'the answer, and then what was held');
});

test('through hibernation: who a socket answered as comes back with it', async () => {
  const act = await activation(ADA);
  const relay = objectRelay(verify, { tag: 'online', now, gate: serviceGate({ service: SERVICE.public, verify, now }) });
  const a = socket();
  relay.open(a);
  await relay.message(a, JSON.stringify(['AUTH', await showing(ADA, a, act)]));
  const carried = relay.authOf(a);
  const woken = objectRelay(verify, { tag: 'online', now, gate: serviceGate({ service: SERVICE.public, verify, now }) });
  const back = socket();
  woken.open(back, {}, carried);
  assert.equal(back.of('AUTH').length, 0, 'not asked again');
  await woken.message(back, JSON.stringify(['EVENT', await beat(ADA)]));
  assert.equal(back.of('OK')[0][2], true);
});
