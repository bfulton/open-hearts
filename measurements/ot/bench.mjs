// The wasm build under Node (V8, the same engine as Chrome's):
//
//   node bench.mjs [transfers] [triples] [bucket]
//
// The wasm imports two host functions and nothing else — no glue
// library — so this file is the whole host.
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';

const FIELDS = ['expand', 'transpose', 'check', 'hash', 'all', 'sent', 'abits', 'haand', 'laand', 'bucket', 'triples', 'bits', 'aes', 'transfers', 'abitCheck', 'abitBits', 'pre', 'garble', 'eval', 'decision', 'dbits', 'dpre', 'daes', 'dands'];
/// One bot-held seat for one hand (packages/engine/tool/circuit_count.dart).
const GATES = 53726;

const m = Number(process.argv[2] ?? 1 << 20);
const n = Number(process.argv[3] ?? 1 << 11);
const bucket = Number(process.argv[4] ?? 4);
const wasm = readFileSync(new URL('./target/wasm32-unknown-unknown/release/ot_bench.wasm', import.meta.url));
const out = {};
const { instance } = await WebAssembly.instantiate(wasm, {
  env: { now: () => performance.now(), report: (id, v) => (out[FIELDS[id]] = v) },
});

instance.exports.bench(1 << 14, 1n); // warm
instance.exports.bench(m, 2n);

const ns = (ms) => (ms * 1e6) / m;
console.log(`${m} extended transfers, wasm under node ${process.versions.v8.split('.').slice(0, 2).join('.')}\n`);
for (const f of ['expand', 'transpose', 'check', 'hash', 'all']) {
  console.log(`  ${f.padEnd(11)} ${out[f].toFixed(1).padStart(8)} ms  ${ns(out[f]).toFixed(1).padStart(8)} ns each`);
}
const lean = out.expand + out.transpose + out.hash;
console.log(`  without the check,        ${ns(lean).toFixed(1).padStart(8)} ns each`);
console.log(`\n  on the wire ${out.sent} bytes  ${(out.sent / m).toFixed(1)} bytes each`);
console.log(`\nfor a seat's ${GATES} AND gates, at one transfer a gate:`);
console.log(
  `  ${((ns(out.all) * GATES) / 1e6).toFixed(0)} ms as measured, ` +
    `${((ns(lean) * GATES) / 1e6).toFixed(0)} ms without the check, ` +
    `${((out.sent / m) * GATES / 1024).toFixed(0)} KB on the wire`,
);

// And the authentication on top, which is what a gate actually costs.
instance.exports.bench_triples(256, bucket, 3n); // warm
instance.exports.bench_triples(n, bucket, 4n);

const each = (ms) => (ms * 1e6) / n;
const bytes = out.bits / 8 / n;
console.log(`\n${n} authenticated AND triples, bucket of ${bucket}, the same wasm\n`);
for (const [f, label] of [
  ['abits', 'the transfers under them'],
  ['haand', 'the cross terms'],
  ['laand', 'the leaky check'],
  ['bucket', 'bucketing'],
  ['triples', 'all of it'],
]) {
  console.log(`  ${label.padEnd(24)} ${out[f].toFixed(1).padStart(8)} ms  ${each(out[f]).toFixed(0).padStart(9)} ns each`);
}
const leanTriple = out.triples - out.abitCheck;
console.log(`  ${'without the KOS check'.padEnd(24)} ${leanTriple.toFixed(1).padStart(8)} ms  ${each(leanTriple).toFixed(0).padStart(9)} ns each`);
console.log(
  `\n  on the wire ${bytes.toFixed(0)} bytes each — ${(out.abitBits / 8 / n).toFixed(0)} the transfers, ` +
    `${((out.bits - out.abitBits) / 8 / n).toFixed(0)} the check — ` +
    `${out.transfers / n} transfers and ${out.aes / n} block cipher calls a triple`,
);
console.log(`\nfor a seat's ${GATES} AND gates, one triple a gate:`);
console.log(
  `  ${((each(out.triples) * GATES) / 1e9).toFixed(1)} s as measured, ` +
    `${((each(leanTriple) * GATES) / 1e9).toFixed(1)} s without the KOS check, ` +
    `${((bytes * GATES) / 1048576).toFixed(1)} MB on the wire, ${bytes.toFixed(0)} bytes a gate`,
);

// And the whole of a bot's decision: the policy garbled over a hand
// neither party can see. The circuit is compiled into the wasm.
instance.exports.bench_decision(bucket, 5n);

const dAll = out.decision;
const dBytes = out.dbits / 8;
console.log(`\none decision of the bot, garbled, bucket of ${bucket}, the same wasm\n`);
console.log(`  ${out.dands} AND gates`);
for (const [f, label] of [
  ['pre', 'the triples and the bits'],
  ['garble', 'garbling'],
  ['eval', 'evaluating'],
  ['decision', 'all of it'],
]) {
  console.log(`  ${label.padEnd(24)} ${out[f].toFixed(1).padStart(8)} ms`);
}
console.log(
  `\n  on the wire ${(dBytes / 1048576).toFixed(2)} MB — ${(out.dpre / 8 / 1048576).toFixed(2)} the preprocessing, ` +
    `${((out.dbits - out.dpre) / 8 / 1048576).toFixed(2)} the tables and the rest`,
);
console.log(`  ${(dBytes / out.dands).toFixed(0)} bytes a gate, ${out.daes} block cipher calls`);
console.log(`\na hand is a pass and thirteen plays; at this play's size that is`);
console.log(`  ${((13 * dBytes) / 1048576).toFixed(1)} MB and ${((13 * dAll) / 1000).toFixed(1)} s for thirteen of them, before the pass`);
