// Runs the deal benchmark's wasm build under Node (V8, the same engine
// as Chrome):  node bench.mjs [runs]
//
// The wasm imports two host functions and nothing else — no glue
// library — so this file is the whole host.
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';

export const FIELDS = [
  'setup', 'keygen (per player)', 'aggregate key + 4 key proofs',
  'mask 52 cards', 'shuffle + prove (one player)',
  'verify one shuffle proof', 'one reveal token + proof',
  'unmask one card (4 tokens, proofs checked)',
  'per-player work for one deal', 'table deal latency',
];

// Everything the module imports beyond `env` is wasm-bindgen's
// placeholder set — pulled in by a dependency's getrandom feature and
// dead at runtime, since every random value here comes from a seeded
// generator. Stub each one to fail loudly if that ever stops being true.
function imports(module, env) {
  const stubs = {};
  for (const { module: m, name } of WebAssembly.Module.imports(module)) {
    if (m === 'env') continue;
    (stubs[m] ??= {})[name] = name === '__wbindgen_describe'
      ? () => {}
      : () => { throw new Error(`wasm called stubbed import ${m}.${name}`); };
  }
  return { env, ...stubs };
}

const wasm = readFileSync(new URL(
  './target/wasm32-unknown-unknown/release/shuffle_bench.wasm', import.meta.url));
const runs = Number(process.argv[2] ?? 3);
const results = [];
let current;
const module = await WebAssembly.compile(wasm);
const instance = await WebAssembly.instantiate(module, imports(module, {
  now: () => performance.now(),
  report: (id, ms) => { current[FIELDS[id]] = ms; },
}));
for (let seed = 0; seed < runs; seed++) {
  current = {};
  const t0 = performance.now();
  instance.exports.bench(BigInt(seed));
  current['whole run'] = performance.now() - t0;
  results.push(current);
}
const last = results.at(-1);
console.log(`wasm under Node ${process.version}, ${wasm.length} bytes, best of ${runs} runs\n`);
for (const name of [...FIELDS, 'whole run']) {
  const best = Math.min(...results.map(r => r[name]));
  console.log(`${name.padEnd(46)} ${best.toFixed(1).padStart(9)} ms`);
}
