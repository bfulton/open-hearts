// The Pages worker's entry, as deploy.sh publishes it: _worker.js/ is a
// directory holding this file as index.js, worker.mjs and the signature
// wasm. Cloudflare compiles an imported .wasm ahead of time and will not
// compile one from bytes while running, which is what the worker does
// everywhere else (Node, the tests), so the module is handed over here.
import wasm from './schnorr.wasm';
import worker, { useSchnorrModule } from './worker.mjs';

useSchnorrModule(wasm);

export default worker;
