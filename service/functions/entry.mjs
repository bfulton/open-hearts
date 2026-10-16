// The Pages worker's entry, as deploy.sh publishes it: _worker.js/ is a
// directory holding this file as index.js, worker.mjs and the modules
// beside it, the signature wasm, and config/openhearts.json and
// site/ledger.json as modules. Cloudflare compiles an imported .wasm
// ahead of time and will not compile one from bytes while running,
// which is what the worker does everywhere else (Node, the tests), so
// the module is handed over here; the committed configuration is laid under the project's
// settings (deployment.mjs); and the ledger of the terms and the privacy
// policy the site was built with goes beside them (notices.mjs).
import wasm from './schnorr.wasm';
import config from './openhearts.config.mjs';
import ledger from './ledger.config.mjs';
import { withConfig } from './deployment.mjs';
import worker from './worker.mjs';
import { useSchnorrModule } from './licence.mjs';

useSchnorrModule(wasm);

export default {
  fetch: (request, env, ctx) => worker.fetch(request, { ...withConfig(env, config), OH_LEDGER: ledger }, ctx),
};
