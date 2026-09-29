// BIP-340 test vectors 0 and 1 against the wasm, then a timing under
// node's V8 (the browser number is what matters; see bench.mjs).
import { readFileSync } from 'node:fs';
import { loadSchnorr, hex, unhex } from './schnorr.mjs';

const s = await loadSchnorr(readFileSync(new URL('./schnorr.wasm', import.meta.url)));
const vectors = [
  { sk: '0000000000000000000000000000000000000000000000000000000000000003',
    pk: 'F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9',
    aux: '0000000000000000000000000000000000000000000000000000000000000000',
    msg: '0000000000000000000000000000000000000000000000000000000000000000',
    sig: 'E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0' },
  { sk: 'B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF',
    pk: 'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
    aux: '0000000000000000000000000000000000000000000000000000000000000001',
    msg: '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
    sig: '6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A' },
];
for (const [i, v] of vectors.entries()) {
  const sig = s.sign(unhex(v.sk), unhex(v.msg), unhex(v.aux));
  const same = hex(sig).toUpperCase() === v.sig;
  const ok = s.verify(unhex(v.pk), unhex(v.msg), unhex(v.sig));
  const tampered = unhex(v.sig); tampered[0] ^= 1;
  const bad = s.verify(unhex(v.pk), unhex(v.msg), tampered);
  console.log(`vector ${i}: signature ${same ? 'matches' : 'DIFFERS'}, verifies ${ok}, tampered verifies ${bad}`);
  if (!same || !ok || bad) process.exit(1);
}
const N = 200;
const sk = unhex(vectors[1].sk), pk = unhex(vectors[1].pk);
const msgs = Array.from({ length: N }, (_, i) => { const m = new Uint8Array(32); m[0] = i; m[1] = i >> 8; return m; });
const aux = new Uint8Array(32);
let t = performance.now();
const sigs = msgs.map((m) => s.sign(sk, m, aux));
const signMs = (performance.now() - t) / N;
t = performance.now();
let good = 0;
for (let i = 0; i < N; i++) good += s.verify(pk, msgs[i], sigs[i]) ? 1 : 0;
const verifyMs = (performance.now() - t) / N;
console.log(JSON.stringify({ runtime: 'node', sign_ms: +signMs.toFixed(3), verify_ms: +verifyMs.toFixed(3), verified: good, of: N }));
