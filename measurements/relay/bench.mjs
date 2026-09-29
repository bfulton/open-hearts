// What the relay path carries, and what it costs:
//
//   node measurements/relay/bench.mjs
//
// The table has two paths (app/lib/net/mesh_transport.dart): a WebRTC
// data channel to every other human — measured in ../channel — and the
// relay beside them, which is the *only* path to a juror. A juror is
// not a peer: it is summoned, it follows the table from the relay
// alone (packages/table/lib/src/juror_duty.dart), and nothing ever
// offers it a channel. Doc 04 makes the foreman a computing party at
// one human, so what a relay carries is not a detail of the transport:
// it is the whole budget for the one party that has no other way in.
//
// What runs here is the relay the object runs (service/do/relay.mjs)
// on the node host (service/do/host.mjs), over a loopback socket, with
// real BIP-340 signatures through the app's own wasm. Like the channel
// bench this is a ceiling and not a link: a public relay is somebody
// else's machine with its own limits, and our own object is a hop
// across the world. What the loopback does measure honestly is the
// envelope, the per-event work both ends must do, and what a small
// message waits behind.
//
// What it does not measure is sealing, which is Dart: seal.dart.

import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';

import { serve, wasmPath } from '../../service/do/host.mjs';
import { idOf, schnorrVerifier } from '../../service/do/relay.mjs';
import { keys, signing } from '../../service/do/sign.mjs';

/// One bot-held seat for one hand (packages/engine/tool/circuit_count.dart).
const GATES = 53726;
/// An extended transfer, in bytes (../ot/README.md).
const TRANSFER = 16;
/// How much a sender queues before it waits, the figure the channel
/// bench's "behind" row uses (../channel/README.md).
const BURST = 8 << 20;
/// TableKinds.table, and a tag to put it under.
const KIND = 24242;
const TAG = 'bench';

const wasm = readFileSync(wasmPath);
const sign = await signing(wasm);
const verify = await schnorrVerifier(wasm);
const relay = await serve({ port: 0 });

/// Bytes as a table message would carry them: base64 in a JSON object,
/// which is what anything that is not text costs on this wire.
const payload = (bytes) => JSON.stringify({ d: Buffer.alloc(bytes, 7).toString('base64') });

/// A signed event of kind 24242 tagged with the table, the way
/// RelayTransport builds one (packages/table/lib/src/relay_transport.dart).
let nonce = 0;
const event = (content) => sign.event(keys[0], { kind: KIND, content, tags: [['t', TAG]], created_at: 1_000_000 + nonce++ });

const wire = (ev) => Buffer.byteLength(JSON.stringify(['EVENT', ev]));
const ms = (n) => n.toFixed(2).padStart(8);
const at = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];

/// A socket, open and ready to be talked to.
function connect() {
  const ws = new WebSocket(`${relay.url}/${TAG}`);
  ws.onerror = (e) => console.error('socket', e.message ?? e);
  return new Promise((done) => {
    ws.onopen = () => done(ws);
  });
}

/// A socket subscribed to the table's kind and tag, calling [onEvent]
/// with each event as it arrives. Resolves at EOSE, which is when the
/// relay has the subscription.
async function subscriber(onEvent) {
  const ws = await connect();
  return new Promise((done) => {
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg[0] === 'EVENT') onEvent(msg[2], m.data.length);
      else if (msg[0] === 'EOSE') done(ws);
    };
    ws.send(JSON.stringify(['REQ', 's', { kinds: [KIND], '#t': [TAG] }]));
  });
}

/// Hands [events] to [ws] as fast as the socket will take them, up to
/// [cap] queued, yielding between each so that anything else this
/// process is doing — a table message down another socket — gets its
/// turn, as it would in an app.
async function pour(ws, events, cap = 4 << 20) {
  for (const ev of events) {
    ws.send(JSON.stringify(['EVENT', ev]));
    await new Promise(setImmediate);
    while (ws.bufferedAmount > cap) await new Promise((r) => setTimeout(r, 1));
  }
}

console.log(`the relay the object runs, on loopback, node ${process.version} (v8 ${process.versions.v8.split('.').slice(0, 2).join('.')})\n`);

// ---------------------------------------------------------------- //
// The envelope: what a byte of payload costs on the wire.
// ---------------------------------------------------------------- //
console.log('the envelope, one event of kind 24242 tagged with a table\n');
console.log('   payload      content         wire   expansion');
for (const bytes of [0, 32, 1024, 16 * 1024, 64 * 1024, 256 * 1024]) {
  const content = payload(bytes);
  const ev = await event(content);
  const w = wire(ev);
  console.log(
    `  ${String(bytes).padStart(8)}  ${String(Buffer.byteLength(content)).padStart(11)}  ${String(w).padStart(11)}` +
      `   ${bytes === 0 ? '—' : `${(w / bytes).toFixed(2)}x`}`,
  );
}
// A sealed content is base64 and has nothing in it to escape, so what
// the envelope costs such an event is flat.
const flat = wire(await event('A'.repeat(4096))) - 4096;
console.log(`\n  a content with nothing to escape — which is anything base64 — costs ${flat} bytes of envelope`);

// ---------------------------------------------------------------- //
// The per-event work: a signature to send one, a hash and a signature
// to accept one — paid by the relay, and again by every receiver.
// ---------------------------------------------------------------- //
console.log("\nper event, through the app's own wasm\n");
console.log('      payload        sign       check      sign/s     check/s');
for (const bytes of [32, 1024, 16 * 1024, 64 * 1024]) {
  const content = payload(bytes);
  const rounds = bytes > 16 * 1024 ? 100 : 200;
  const made = [];
  let t = performance.now();
  for (let i = 0; i < rounds; i++) made.push(await event(content));
  const signed = (performance.now() - t) / rounds;
  t = performance.now();
  for (const ev of made) {
    const id = await idOf(ev.pubkey, ev.created_at, ev.kind, ev.tags, ev.content);
    if (!verify(ev.pubkey, id, ev.sig)) throw new Error('a signature this file just made');
  }
  const checked = (performance.now() - t) / rounds;
  console.log(
    `  ${String(bytes).padStart(11)}  ${ms(signed)} ms  ${ms(checked)} ms` +
      `  ${String(Math.round(1000 / signed)).padStart(10)}  ${String(Math.round(1000 / checked)).padStart(10)}`,
  );
}

// ---------------------------------------------------------------- //
// Throughput: one publisher, one subscriber, events signed in advance
// so that what is timed is the relay and not the signing.
// ---------------------------------------------------------------- //
console.log('\none publisher, one subscriber, pre-signed\n');
console.log('      payload   events     payload MB/s    wire MB/s    events/s');
for (const [bytes, count] of [
  [1024, 2000],
  [16 * 1024, 800],
  [64 * 1024, 300],
  [256 * 1024, 120],
]) {
  const content = payload(bytes);
  const events = [];
  for (let i = 0; i < count; i++) events.push(await event(`${content.slice(0, -1)},"n":${i}}`));
  let got = 0;
  let bytesIn = 0;
  let done;
  const all = new Promise((r) => (done = r));
  const sub = await subscriber((_, size) => {
    bytesIn += size;
    if (++got === count) done();
  });
  const pub = await connect();
  pub.onmessage = () => {}; // the OKs, which are traffic back
  const t = performance.now();
  await pour(pub, events);
  await all;
  const secs = (performance.now() - t) / 1000;
  console.log(
    `  ${String(bytes).padStart(11)}  ${String(count).padStart(7)}  ${((bytes * count) / 1048576 / secs).toFixed(1).padStart(15)}` +
      `  ${(bytesIn / 1048576 / secs).toFixed(1).padStart(11)}  ${String(Math.round(count / secs)).padStart(10)}`,
  );
  pub.close();
  sub.close();
}

// ---------------------------------------------------------------- //
// What a table's own message waits behind: idle, beside a bulk stream
// on a second socket, and behind one on its own.
// ---------------------------------------------------------------- //
console.log('\ndelivery of a 64-byte message, publish to receipt\n');

const small = [];
for (let i = 0; i < 300; i++) small.push(await event(payload(48)));
const bulkContent = payload(64 * 1024);
const bulk = [];
for (let i = 0; i < 600; i++) bulk.push(await event(`${bulkContent.slice(0, -1)},"n":${i}}`));

const waiting = {};
const sub = await subscriber((ev) => waiting[ev.id]?.());
const pub = await connect();
pub.onmessage = () => {};

/// [rounds] messages one at a time down [ws], each timed from the send
/// to the moment the subscriber has it.
async function trips(ws, pool, rounds) {
  const out = [];
  for (let i = 0; i < rounds; i++) {
    const ev = pool.pop();
    const t = performance.now();
    const seen = new Promise((r) => (waiting[ev.id] = r));
    ws.send(JSON.stringify(['EVENT', ev]));
    await seen;
    out.push(performance.now() - t);
  }
  return out.sort((a, b) => a - b);
}

await trips(pub, small, 40); // warm
const idle = await trips(pub, small, 100);

// Beside: the bulk goes down a second socket, paced, so the small
// message is never queued behind it. What the two still share is the
// relay, which is one queue for everything on a tag.
const second = await connect();
second.onmessage = () => {};
const pouring = pour(second, bulk.slice(0, 150));
const beside = await trips(pub, small, 100);
await pouring;

// Behind: the same socket, with what a sender queues before it waits
// already in it. A paced sender on loopback never builds a queue at
// all — the socket drains between ticks — so the queue is built the
// way a real one is, by handing over more than the link can take.
const behind = [];
let queued = 0;
for (let round = 0; round < 5; round++) {
  let burst = 0;
  for (const ev of bulk.slice(150 + round * 90, 150 + (round + 1) * 90)) {
    const frame = JSON.stringify(['EVENT', ev]);
    burst += frame.length;
    pub.send(frame);
    if (burst >= BURST) break;
  }
  queued = Math.max(queued, pub.bufferedAmount);
  behind.push((await trips(pub, small, 1))[0]);
  while (pub.bufferedAmount > 0) await new Promise((r) => setTimeout(r, 1));
}
behind.sort((a, b) => a - b);

for (const [what, t] of [
  ['idle', idle],
  ['beside a bulk stream, on another socket', beside],
  [`behind ${(queued / 1024).toFixed(0)} KB of one, on the same socket`, behind],
]) {
  console.log(`  ${what.padEnd(44)} ${at(t, 0.5).toFixed(1).padStart(6)} ms median  ${at(t, 0.95).toFixed(1).padStart(6)} ms p95`);
}

// ---------------------------------------------------------------- //
// And what that is, in the units doc 04 asks about.
// ---------------------------------------------------------------- //
const hand = GATES * TRANSFER;
console.log(`\nfor a seat's ${GATES} AND gates at ${TRANSFER} bytes a transfer, one transfer a gate:`);
console.log(`  ${(hand / 1024).toFixed(0)} KB of material a hand, before it is base64, sealed and signed`);

pub.close();
second.close();
sub.close();
relay.close();
