// The Pages worker's entry, as deploy.sh publishes it: _worker.js/ is a
// directory holding this file as index.js, worker.mjs, the signature
// wasm, and config/openhearts.json as a module. Cloudflare compiles an
// imported .wasm ahead of time and will not compile one from bytes while
// running, which is what the worker does everywhere else (Node, the
// tests), so the module is handed over here; and the committed
// configuration is laid under the project's settings (deployment.mjs).
import wasm from './schnorr.wasm';
import config from './openhearts.config.mjs';
import { withConfig } from './deployment.mjs';
import worker, { useSchnorrModule } from './worker.mjs';

useSchnorrModule(wasm);

export default {
  fetch: (request, env, ctx) => worker.fetch(request, withConfig(env, config), ctx),
};
