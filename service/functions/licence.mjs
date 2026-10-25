// The service's signed statements: a device's licence, and the
// activation the account's device in use holds (household.mjs, "one
// device at a time").
//
// A licence is what a subscribed device holds instead of a receipt: a
// short signed statement it checks against a key baked into its build
// (packages/table, licence.dart). Short, and renewed while the
// subscription lives, so a cancellation needs no revocation list —
// the last licence simply runs out. It names the device's key and the
// account the device is one of, which is what every peer at a table
// checks a seat by: the key signs the moves, the account is who sat.
// POST /api/licence answers {"licence": {key, account, until, plan,
// sig}} — for the service's licenceDays, signed by the service key
// (OH_SERVICE_SECRET, with OH_SERVICE_KEY beside it as the public half
// the app has baked in), or 402 when no subscription stands behind the
// key, or 403 with `suspended` when its account is suspended
// (suspension.mjs). What is read is one row, and the others only
// around a renewal or a refusal.
//
// The curve is the one the whole project signs on, so the signing is
// the app's own wasm: on Cloudflare the module entry.mjs imports, and
// elsewhere (the tests, wrangler pages dev) fetched from the static
// assets the worker serves.

import { entitlementOf } from './accounts.mjs';
import { dayAfter, digestOf, earlier, hex, storeOf } from './rows.mjs';
import { S, notConfigured } from './settings.mjs';
import { SUSPENDED_WHY } from './suspension.mjs';

const STATEMENT = 'oh-licence/2';
const PLAN = 'year';

/// The app's own BIP-340 wasm, which this worker serves as a static
/// asset and then signs with: one curve in the project, one
/// implementation of it. Instantiated once per isolate.
let signing = null;

export async function signerOn(bytes) {
  // A compiled module (what Cloudflare hands an imported .wasm) gives an
  // instance; bytes (Node, the tests) give the module and the instance.
  const made = await WebAssembly.instantiate(bytes, {});
  const { memory, alloc, reset, sign, verify } = (made.instance ?? made).exports;
  reset();
  const at = { sk: alloc(32), pk: alloc(32), msg: alloc(32), aux: alloc(32), sig: alloc(64) };
  const put = (to, hex) => {
    const mem = new Uint8Array(memory.buffer);
    for (let i = 0; i < hex.length; i += 2) mem[to + i / 2] = parseInt(hex.slice(i, i + 2), 16);
  };
  return {
    /// A signature over a 32-byte digest, hex in and hex out; null when
    /// the secret is not one.
    sign(secretHex, digestHex) {
      put(at.sk, secretHex);
      put(at.msg, digestHex);
      crypto.getRandomValues(new Uint8Array(memory.buffer, at.aux, 32));
      if (sign(at.sk, at.msg, at.aux, at.sig) !== 1) return null;
      return hex(new Uint8Array(memory.buffer).slice(at.sig, at.sig + 64));
    },
    verify(keyHex, digestHex, sigHex) {
      put(at.pk, keyHex);
      put(at.msg, digestHex);
      put(at.sig, sigHex);
      return verify(at.pk, at.msg, at.sig) === 1;
    },
  };
}

/// The signature wasm as a compiled module, when the runtime imported
/// one (service/functions/entry.mjs): Cloudflare will not compile wasm
/// from bytes at run time, so on Cloudflare this is the only way in.
let schnorrModule = null;
export const useSchnorrModule = (module) => (schnorrModule = module);

/// The signer for this isolate, over the wasm the site already serves.
/// What is kept is the promise of it rather than the signer, so a
/// second request arriving while the first is still fetching gets the
/// one the first built and not one of its own.
export function signerFor(request, env) {
  if (schnorrModule) return (signing ??= signerOn(schnorrModule));
  return (signing ??= (async () => {
    const res = await env.ASSETS.fetch(new URL('/play/schnorr.wasm', request.url));
    if (!res.ok) throw new Error(`no schnorr wasm: ${res.status}`);
    return signerOn(await res.arrayBuffer());
  })().catch((e) => {
    // A failure is not cached: the next request tries again.
    signing = null;
    throw e;
  }));
}

/// [canonical], signed by the service. Null when the service's two
/// halves do not match: a signature this service cannot verify against
/// the key every app has baked in is one no device would take, and a
/// loud refusal beats a quiet one nobody can debug.
async function serviceSigned(canonical, { signer, secret, service }) {
  const digest = await digestOf(canonical);
  const sig = signer.sign(secret, digest);
  if (!sig || !signer.verify(service, digest, sig)) return null;
  return sig;
}

/// The statement, signed: this device, its account, the last day.
export async function licenceFor(key, account, until, keys) {
  const sig = await serviceSigned(`${STATEMENT}\n${key}\n${account}\n${until}\n${PLAN}`, keys);
  return sig ? { key, account, until, plan: PLAN, sig } : null;
}

/// The service's two halves, when both are set and look like keys.
export function serviceKeys(env) {
  const secret = env.OH_SERVICE_SECRET;
  const service = env.OH_SERVICE_KEY;
  if (!/^[0-9a-f]{64}$/.test(secret ?? '') || !/^[0-9a-f]{64}$/.test(service ?? '')) return null;
  return { secret, service };
}

/// The licence handler's status and body. [written] is the device's
/// row as its account's object has just written it, bringing the device
/// in (accounts.mjs, entitlementOf).
export async function licence(key, env, { signer, now = Date.now(), open = false, written = null } = {}) {
  const keys = serviceKeys(env);
  if (!keys) return { status: 503, body: notConfigured('OH_SERVICE_KEY and OH_SERVICE_SECRET') };
  const store = storeOf(env);
  if (!store) return { status: 503, body: notConfigured('OH_STORE') };
  const held = await entitlementOf(store, key, { now, openHouse: open, written });
  if (!held) {
    // Said apart from having no subscription, so that the app says why
    // live play is shut rather than offering to sell it again.
    if ((written ?? (await store.get(`KEY#${key}`, 'ENTITLEMENT')))?.suspended) return { status: 403, body: { error: SUSPENDED_WHY, suspended: true } };
    return { status: 402, body: { error: 'no subscription' } };
  }
  const until = earlier(dayAfter(now, S().licenceDays), held.licensed_until);
  const signed = await licenceFor(key, held.account, until, { signer, ...keys });
  if (!signed) return { status: 503, body: { error: 'the service key does not match its secret' } };
  return { status: 200, body: { licence: signed } };
}

/// How long an activation is good for, in seconds. The app asks again
/// every twenty minutes while it is open, and at every table.
export const ACTIVATION_S = 60 * 60;

const ACTIVE = 'oh-active/1';

/// The activation, signed: {account, key, epoch, until, sig}.
export async function activationFor(account, key, epoch, until, keys) {
  const sig = await serviceSigned(`${ACTIVE}\n${account}\n${key}\n${epoch}\n${until}`, keys);
  return sig ? { account, key, epoch, until, sig } : null;
}
