// The service's handlers as one Cloudflare Pages worker
// (docs/06-service.md): what runs on our side beside the static site
// and the app. deploy.sh copies this file to _worker.js at the root of
// the published directory, where Pages runs it for every request;
// whatever is not a handler is handed to the static assets.
//
// Every handler but Stripe's is asked with the caller's table key, and
// signed by it: {"key", "at", "sig", ...} — see "who is asking" below.
// A key is public, so a request that only names one is anybody's.
//
// turn-creds: POST /api/turn answers {"iceServers": [...], "ttl":
// seconds} — Cloudflare Realtime TURN credentials good for a few hours,
// minted from a TURN key that lives in the project's secrets
// (OH_TURN_KEY_ID, OH_TURN_API_TOKEN) and never here, for a device
// whose subscription stands: TURN is what the subscription pays for.
// Without the secrets the handler says so (503) and the app falls back
// to STUN alone.
//
// licence: POST /api/licence answers {"licence": {key, until, plan,
// sig}} — a month, signed by the service key (OH_SERVICE_SECRET, with
// OH_SERVICE_KEY beside it as the public half the app has baked in), or
// 402 when no subscription stands behind the key. What is read is one
// row, and the second only around a renewal.
//
// No imports, so nothing is bundled: the file is the worker. The curve
// is the one the whole project signs on, so the signing is the app's
// own wasm, fetched from the static assets this worker serves.

import { keepRecord, recordMost, recordResponse } from './records.mjs';

const UPSTREAM = 'https://rtc.live.cloudflare.com/v1/turn/keys';

/// Whether [url] is this machine: local mode, `wrangler pages dev` and
/// the browser suites' rig. What only a dev machine may do is decided
/// by where the request went, not by a setting alone — a setting left
/// on in production is then a setting that does nothing.
export function isLocal(url) {
  try {
    const host = new URL(url).hostname;
    return host === 'localhost' || host === '127.0.0.1';
  } catch {
    return false;
  }
}

/// Local mode's open house (doc 06): every device that asks licensed,
/// and `local:` sign-ins taken. Only where it is set and only on this
/// machine: set in a production project by mistake, it would license
/// everyone and let anybody sign in as anybody.
export const openHouse = (env, request) => !!env.OH_OPEN_HOUSE && isLocal(request.url);

// ---- The service's own settings ---------------------------------------
//
// The numbers the service runs by — how long a licence lasts, how many
// devices a subscription carries, how long a code is good for, which
// Stripe price a checkout sells — read from one row the operator
// writes, `config|service` in OH_STORE (doc 06, "The service's
// settings"). Not the app's row: nothing here is served to anybody.
// Each is checked against bounds before it is taken, and one that does
// not check out is left at its default, so a typo in the row is never
// worse than no row.

/// The defaults, which are what the service ran by before the row.
export const SERVICE_DEFAULTS = Object.freeze({
  licenceDays: 31,
  mostDevices: 5,
  ticketMinutes: 10,
  ticketReuseMinutes: 2,
  turnTtlS: 4 * 60 * 60,
  requestToleranceS: 300,
  webhookToleranceS: 300,
  householdChangesPerHour: 20,
  householdReadsPerHour: 60,
  stripePrice: null,
});

/// Least and most for each number, whole numbers only. The edges are
/// where a setting stops being a tuning and becomes a hole: a licence
/// past a year outlives the subscription, a clock skew past fifteen
/// minutes makes a captured request good for longer than any device
/// needs.
export const SERVICE_BOUNDS = Object.freeze({
  licenceDays: [1, 62],
  mostDevices: [1, 10],
  ticketMinutes: [1, 60],
  ticketReuseMinutes: [0, 30],
  turnTtlS: [600, 24 * 60 * 60],
  requestToleranceS: [30, 900],
  webhookToleranceS: [60, 900],
  householdChangesPerHour: [5, 500],
  householdReadsPerHour: [10, 2000],
});

/// The row, checked: every field that checks out, the default for the
/// rest.
export function serviceSettingsOf(raw) {
  const c = { ...SERVICE_DEFAULTS };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return c;
  for (const [name, [least, most]] of Object.entries(SERVICE_BOUNDS)) {
    const v = raw[name];
    if (Number.isInteger(v) && v >= least && v <= most) c[name] = v;
  }
  // A code handed back again has to have the time left to be used.
  if (c.ticketReuseMinutes >= c.ticketMinutes) c.ticketReuseMinutes = Math.min(SERVICE_DEFAULTS.ticketReuseMinutes, c.ticketMinutes - 1);
  if (typeof raw.stripePrice === 'string' && STRIPE_PRICE.test(raw.stripePrice)) c.stripePrice = raw.stripePrice;
  return c;
}

/// Where the row lives: `config|service` in OH_STORE.
const SERVICE_ROW = ['config', 'service'];

/// How long an isolate goes by the row before it reads it again.
const SETTINGS_KEPT_MS = 60 * 1000;

let settings = SERVICE_DEFAULTS;
let settledAt = -Infinity;

/// What the service runs by now.
export const S = () => settings;

/// Reads the row if this isolate has not lately; a store that is down,
/// or no store, is the defaults. Called at the top of every request.
export async function settle(env, { now = Date.now() } = {}) {
  if (now - settledAt < SETTINGS_KEPT_MS) return settings;
  settledAt = now;
  let raw = null;
  try {
    raw = (await storeOf(env)?.get(...SERVICE_ROW)) ?? null;
  } catch {
    // Unreadable is the same as absent: the defaults.
  }
  settings = Object.freeze(serviceSettingsOf(raw));
  return settings;
}

/// For a test: these settings, until the next [settle] that reads.
export function useSettings(next = {}) {
  settings = Object.freeze({ ...SERVICE_DEFAULTS, ...next });
  settledAt = Infinity;
}

/// For a test: back to the defaults, and the next request reads the row.
export function forgetSettings() {
  settings = SERVICE_DEFAULTS;
  settledAt = -Infinity;
}

/// The origin a browser may call the handlers from, echoed back, or
/// null: the site's own hosts, and — on a dev machine only — the dev
/// machine's own pages.
export function allowedOrigin(origin, requestUrl = null) {
  if (!origin) return null;
  let host;
  try {
    host = new URL(origin).hostname;
  } catch {
    return null;
  }
  if (host === 'localhost' || host === '127.0.0.1') return requestUrl && isLocal(requestUrl) ? origin : null;
  if (host === 'openhearts.game' || host === 'www.openhearts.game') return origin;
  if (host === 'open-hearts.pages.dev' || host.endsWith('.open-hearts.pages.dev')) return origin;
  return null;
}

function cors(request, headers = {}) {
  const origin = allowedOrigin(request.headers.get('origin'), request.url);
  const h = { ...headers };
  if (origin) {
    h['access-control-allow-origin'] = origin;
    h['vary'] = 'origin';
  }
  return h;
}

const json = (request, status, body, extra = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: cors(request, { 'content-type': 'application/json', 'cache-control': 'no-store', ...extra }),
  });

/// Cloudflare's answer as a list of ICE servers, whichever shape it
/// takes: a list, or the older single object; urls as a list.
export function serversOf(answer) {
  const s = answer?.iceServers;
  const list = Array.isArray(s) ? s : s ? [s] : [];
  return list
    .map(({ urls, username, credential }) => ({
      urls: (Array.isArray(urls) ? urls : [urls]).filter((u) => typeof u === 'string'),
      ...(typeof username === 'string' ? { username } : {}),
      ...(typeof credential === 'string' ? { credential } : {}),
    }))
    .filter((x) => x.urls.length);
}

/// Mints credentials: the status and body to answer with.
export async function mint(env, fetchImpl = fetch) {
  const keyId = env.OH_TURN_KEY_ID;
  const token = env.OH_TURN_API_TOKEN;
  if (!keyId || !token) return { status: 503, body: { error: 'turn not configured' } };
  const ttl = S().turnTtlS;
  const upstream = `${UPSTREAM}/${keyId}/credentials/generate-ice-servers`;
  let res;
  try {
    res = await fetchImpl(upstream, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ ttl }),
    });
  } catch {
    return { status: 502, body: { error: 'turn upstream unreachable' } };
  }
  if (!res.ok) return { status: 502, body: { error: `turn upstream ${res.status}` } };
  let answer;
  try {
    answer = await res.json();
  } catch {
    return { status: 502, body: { error: 'turn upstream not json' } };
  }
  const iceServers = serversOf(answer);
  if (!iceServers.length) return { status: 502, body: { error: 'turn upstream gave no servers' } };
  return { status: 200, body: { iceServers, ttl } };
}

// ---- the licence -------------------------------------------------------
// What a subscribed device holds instead of a receipt: a short signed
// statement it checks against a key baked into its build
// (app/lib/net/licence.dart). Short, and renewed while the
// subscription lives, so a cancellation needs no revocation list —
// the last licence simply runs out.

/// A licence's days. A month, and never past what has been paid for.
const STATEMENT = 'oh-licence/1';
const PLAN = 'year';

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');

/// A day as the statement spells it: an ISO date, UTC.
export const dayOf = (at) => new Date(at).toISOString().slice(0, 10);

/// [days] after [at], as a day.
export const dayAfter = (at, days) => dayOf(new Date(at).getTime() + days * 86400000);

/// The earlier of two days, which is how a licence is kept inside what
/// was paid for.
const earlier = (a, b) => (a < b ? a : b);

/// Everything the service keeps, as one key-value table (doc 06): a
/// lookup by key, never a scan. Cloudflare KV in production; a Map
/// stands in for the tests and for local mode.
export function storeOf(env) {
  const kv = env.OH_STORE;
  if (!kv) return null;
  const at = (pk, sk) => `${pk}|${sk}`;
  return {
    async get(pk, sk) {
      return kv.get(at(pk, sk), 'json');
    },
    /// [ttl], in seconds, is how long KV keeps the row before letting
    /// it go by itself; without one it is kept until it is deleted.
    async put(pk, sk, value, { ttl } = {}) {
      await kv.put(at(pk, sk), JSON.stringify(value), ...(ttl ? [{ expirationTtl: ttl }] : []));
    },
    async del(pk, sk) {
      await kv.delete(at(pk, sk));
    },
    /// The sort keys under [pk] that begin with [prefix]. The only
    /// call here that is not a point lookup, and it is bounded by what
    /// lives under one subscription: five devices (doc 06).
    async under(pk, prefix) {
      const found = [];
      let cursor;
      do {
        const page = await kv.list({ prefix: at(pk, prefix), cursor });
        for (const { name } of page.keys) found.push(name.slice(`${pk}|`.length));
        cursor = page.list_complete ? undefined : page.cursor;
      } while (cursor);
      return found;
    },
  };
}

export function memoryStore(seed = {}) {
  const rows = new Map(Object.entries(seed));
  const at = (pk, sk) => `${pk}|${sk}`;
  return {
    rows,
    async get(pk, sk) {
      const raw = rows.get(at(pk, sk));
      return raw === undefined ? null : JSON.parse(raw);
    },
    /// An expiry is KV's to keep: a Map lives no longer than a test.
    async put(pk, sk, value) {
      rows.set(at(pk, sk), JSON.stringify(value));
    },
    async del(pk, sk) {
      rows.delete(at(pk, sk));
    },
    async under(pk, prefix) {
      return [...rows.keys()].filter((k) => k.startsWith(at(pk, prefix))).map((k) => k.slice(`${pk}|`.length));
    },
  };
}

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

/// The signer for this isolate, over the wasm the site already serves.
/// What is kept is the promise of it rather than the signer, so a
/// second request arriving while the first is still fetching gets the
/// one the first built and not one of its own.
/// The signature wasm as a compiled module, when the runtime imported
/// one (service/functions/entry.mjs): Cloudflare will not compile wasm
/// from bytes at run time, so on Cloudflare this is the only way in.
let schnorrModule = null;
export const useSchnorrModule = (module) => (schnorrModule = module);

function signerFor(request, env) {
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

async function digestOf(text) {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))));
}

/// The statement, signed. Null when the service's two halves do not
/// match: a signature this service cannot verify against the key every
/// app has baked in is one no device would take, and a loud refusal
/// beats a quiet one nobody can debug.
export async function licenceFor(key, until, { signer, secret, service }) {
  const canonical = `${STATEMENT}\n${key}\n${until}\n${PLAN}`;
  const digest = await digestOf(canonical);
  const sig = signer.sign(secret, digest);
  if (!sig || !signer.verify(service, digest, sig)) return null;
  return { key, until, plan: PLAN, sig };
}

/// How far this key is paid up to, and what it is paid under. One read
/// of the device's own row; a second of the subscription's only when
/// that row says the device has run out, which is once a renewal.
///
/// In local mode a key nobody has heard of is entitled on the spot for
/// a month (doc 06, local mode) — one branch, and it is never on in
/// production.
export async function entitlementOf(store, key, { now = Date.now(), openHouse = false } = {}) {
  const today = dayOf(now);
  const row = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!row) {
    if (!openHouse) return null;
    const subscription = `local-${key.slice(0, 16)}`;
    const renews_at = dayAfter(now, S().licenceDays);
    await store.put(`SUB#${subscription}`, 'META', { source: 'local', txn_ref: null, renews_at, cancelled_at: null });
    await store.put(`SUB#${subscription}`, `DEVICE#${key}`, { bound_at: today });
    const made = { subscription, licensed_until: renews_at, at: today };
    await store.put(`KEY#${key}`, 'ENTITLEMENT', made);
    return made;
  }
  if (row.licensed_until && row.licensed_until >= today) return row;
  // Run out as this row has it, or never written: a checkout binds the
  // device before Stripe has told us when the subscription runs to.
  // The subscription itself is the authority, and a renewal moves it
  // on without touching the devices under it.
  const sub = await store.get(`SUB#${row.subscription}`, 'META');
  if (!sub || !sub.renews_at || sub.renews_at < today) return null;
  const caught = { ...row, licensed_until: sub.renews_at, at: today };
  await store.put(`KEY#${key}`, 'ENTITLEMENT', caught);
  return caught;
}

/// The licence handler's status and body.
export async function licence(key, env, { signer, now = Date.now(), open = false } = {}) {
  const secret = env.OH_SERVICE_SECRET;
  const service = env.OH_SERVICE_KEY;
  if (!/^[0-9a-f]{64}$/.test(secret ?? '') || !/^[0-9a-f]{64}$/.test(service ?? '')) {
    return { status: 503, body: { error: 'licensing not configured' } };
  }
  const store = storeOf(env);
  if (!store) return { status: 503, body: { error: 'licensing not configured' } };
  const held = await entitlementOf(store, key, { now, openHouse: open });
  if (!held) return { status: 402, body: { error: 'no subscription' } };
  const until = earlier(dayAfter(now, S().licenceDays), held.licensed_until);
  const signed = await licenceFor(key, until, { signer, secret, service });
  if (!signed) return { status: 503, body: { error: 'the service key does not match its secret' } };
  return { status: 200, body: { licence: signed } };
}

// ---- who is asking -----------------------------------------------------
// A handler asked with a key acts for that key: it licenses it, mints
// it TURN, makes a code against what it paid for, binds it, lists its
// household and drops devices off it. And a key is public — it signs
// every event a device says at a table, and the relays hand those to
// anybody — so naming one proves nothing. The device signs what it
// asks for, with the key it names (app/lib/net/licence.dart):
//
//     oh-request/1 \n <handler> \n <key> \n <at> \n <what>
//
// hashed and signed BIP-340, where [at] is the second it was made and
// [what] is what it asks for beyond itself — the code it spends, the
// device it drops — or nothing. None of the first four can hold a
// newline and [what] is last, so there is one way to read it; the
// handler is in it, so a licence request cannot be spent as a code
// request; and the statement begins with its own tag, so no event a
// table signs is ever one of these.
// A request a few minutes old is refused, which is as long as a
// captured one is worth anything: there is no nonce to remember, so
// nothing is written to check one.

const REQUEST = 'oh-request/1';

/// How far a request's second may be from ours. Clocks drift; a phone
/// whose clock is out by more than this is told so.

/// The text a request's signature is over.
export const requestStatement = (handler, key, at, what = '') => `${REQUEST}\n${handler}\n${key}\n${at}\n${what}`;

/// The key [body] was signed by for [handler] and [what], as {key}; or
/// the refusal to answer with, as {status, body}.
export async function askedBy(body, handler, what, signer, { now = Date.now() } = {}) {
  const key = keyOf(body);
  if (!key) return { status: 400, body: { error: 'a table key, 64 hex' } };
  const { at, sig } = body;
  if (!Number.isSafeInteger(at) || typeof sig !== 'string' || !/^[0-9a-f]{128}$/.test(sig)) {
    return { status: 401, body: { error: 'a request is signed by the key it names' } };
  }
  if (!signer.verify(key, await digestOf(requestStatement(handler, key, at, what)), sig)) {
    return { status: 401, body: { error: 'not signed by that key' } };
  }
  if (Math.abs(now / 1000 - at) > S().requestToleranceS) {
    return { status: 401, body: { error: "this device's clock is out by more than five minutes" } };
  }
  return { key };
}

// ---- buying, on the web ------------------------------------------------
// Stripe Checkout in subscription mode, with the device's key in the
// session. Nobody is asked to make an account: the key the buyer had
// when they bought is what the entitlement is written against, and the
// licence follows it. A phone will buy through its own store instead
// (doc 06), which needs the app to be in one first.

const STRIPE = 'https://api.stripe.com/v1';

/// The states a subscription does not come back from. Not `canceled`
/// alone: dunning that gives up leaves `unpaid`, and a checkout that
/// was never paid leaves `incomplete_expired`.
const ENDED = new Set(['canceled', 'unpaid', 'incomplete_expired']);

/// And of those, the ones that are final: `unpaid` comes back when the
/// invoice is paid after all; these two do not, and neither does a
/// subscription Stripe has deleted.
const FINAL = new Set(['canceled', 'incomplete_expired']);

/// How far out of date a webhook's own timestamp may be. Stripe signs
/// the moment it sends; a replay from last week is not a payment.

/// Where a buyer may be sent back to: this site, and nowhere else. The
/// address rides in from the app, and an app is not what decides where
/// a payment lands.
export function sameSite(candidate, requestUrl) {
  if (typeof candidate !== 'string') return null;
  let at;
  try {
    at = new URL(candidate, requestUrl);
  } catch {
    return null;
  }
  return at.origin === new URL(requestUrl).origin ? at.toString() : null;
}

/// What names the price a checkout sells: its id (`price_…`), or its
/// lookup key, which is the same in test mode and live and moves to a
/// new price in the dashboard with nothing changed here.
export const STRIPE_PRICE = /^(price_[A-Za-z0-9]{1,64}|(?!price_)[A-Za-z0-9_.:-]{1,200})$/;

/// Lookup keys already asked of Stripe, kept a few minutes: a key moved
/// to a new price reaches checkouts within that.
const priceIds = new Map();
const PRICE_KEPT_MS = 5 * 60 * 1000;

/// For a test: ask Stripe again.
export const forgetPriceIds = () => priceIds.clear();

/// The price id [named] stands for — itself, when it is one; the active
/// price holding it as its lookup key, when it is not; null when Stripe
/// has no such price.
export async function priceIdOf(named, secret, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (named.startsWith('price_')) return named;
  const kept = priceIds.get(named);
  if (kept && kept.until > now) return kept.id;
  const url = `${STRIPE}/prices?${new URLSearchParams({ 'lookup_keys[]': named, active: 'true', limit: '1' })}`;
  const res = await fetchImpl(url, { headers: { authorization: `Bearer ${secret}` } });
  if (!res.ok) throw new Error(`stripe prices ${res.status}`);
  const id = (await res.json())?.data?.[0]?.id;
  if (typeof id !== 'string' || !id.startsWith('price_')) return null;
  priceIds.set(named, { id, until: now + PRICE_KEPT_MS });
  return id;
}

/// How Stripe's checkout page looks: the app's, not the account's — the
/// felt, the gold, the front door's heart, and the name (one account may
/// sell more than one app). The icon is the site's own copy, so a
/// preview's checkout shows a preview's icon. Only the top of the page
/// takes the name; receipts carry the account's public business name.
export function checkoutBranding(back) {
  return {
    'branding_settings[display_name]': 'Open Hearts',
    'branding_settings[icon][type]': 'url',
    'branding_settings[icon][url]': new URL('/icon-512.png', back).toString(),
    'branding_settings[background_color]': '#06231A',
    'branding_settings[button_color]': '#E4B363',
    'branding_settings[border_style]': 'rounded',
    'branding_settings[font_family]': 'roboto',
  };
}

/// A checkout session for [key], as Stripe answers: {status, body}.
export async function checkout(key, back, cancelled, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  const named = S().stripePrice ?? env.OH_STRIPE_PRICE;
  if (!secret || typeof named !== 'string' || !STRIPE_PRICE.test(named)) return { status: 503, body: { error: 'the shop is not open yet' } };
  let price;
  try {
    price = await priceIdOf(named, secret, fetchImpl);
  } catch {
    return { status: 502, body: { error: 'the shop is not answering' } };
  }
  if (!price) return { status: 503, body: { error: 'the shop is not open yet' } };
  const form = new URLSearchParams({
    mode: 'subscription',
    'line_items[0][price]': price,
    'line_items[0][quantity]': '1',
    success_url: back,
    cancel_url: cancelled,
    // Three places, because three different events carry it back: the
    // session's own metadata, the reference on the session, and the
    // subscription's metadata, which is what a renewal a year from now
    // will have.
    'metadata[key]': key,
    client_reference_id: key,
    'subscription_data[metadata][key]': key,
    ...checkoutBranding(back),
  });
  let res;
  try {
    res = await fetchImpl(`${STRIPE}/checkout/sessions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    });
  } catch {
    return { status: 502, body: { error: 'the shop is not answering' } };
  }
  if (!res.ok) return { status: 502, body: { error: `the shop said ${res.status}` } };
  let session;
  try {
    session = await res.json();
  } catch {
    return { status: 502, body: { error: 'the shop talked nonsense' } };
  }
  if (typeof session.url !== 'string') return { status: 502, body: { error: 'the shop gave no checkout' } };
  return { status: 200, body: { url: session.url } };
}

/// Whether [header] signs [raw] with [secret], the way Stripe signs.
/// The payload is the timestamp and the body with a dot between them,
/// HMAC-SHA256; a signature over a payload from last week is refused
/// whatever it says, since a replay is not a payment.
export async function webhookSigned(header, raw, secret, { now = Date.now() } = {}) {
  if (typeof header !== 'string' || !secret) return false;
  const parts = Object.create(null);
  const v1 = [];
  for (const piece of header.split(',')) {
    const at = piece.indexOf('=');
    if (at < 0) continue;
    const name = piece.slice(0, at).trim();
    const value = piece.slice(at + 1).trim();
    if (name === 'v1') v1.push(value);
    else parts[name] = value;
  }
  const t = Number(parts.t);
  if (!Number.isFinite(t) || !v1.length) return false;
  if (Math.abs(now / 1000 - t) > S().webhookToleranceS) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'verify',
  ]);
  const signed = new TextEncoder().encode(`${t}.${raw}`);
  // Every v1 offered, since a secret being rotated signs with two —
  // each checked by the platform's own HMAC verify, which compares in
  // constant time, rather than by comparing strings, which stops at the
  // first character that differs.
  for (const offered of v1) {
    if (!/^[0-9a-f]{64}$/.test(offered)) continue;
    const mac = Uint8Array.from(offered.match(/../g), (b) => parseInt(b, 16));
    if (await crypto.subtle.verify('HMAC', key, mac, signed)) return true;
  }
  return false;
}

/// What a Stripe event means here, written down. Returns what was
/// recorded, or null when the event is not one of ours — a webhook
/// carries everything the account does, and most of it is not this.
export async function record(event, store, { now = Date.now() } = {}) {
  const object = event?.data?.object ?? {};
  const today = dayOf(now);
  // A checkout this service made, and paid for. Made here: only a
  // session this worker created carries the key in its metadata — a
  // Payment Link or a checkout for some other product on the account
  // can carry a client_reference_id in its URL, and must not buy live
  // play with it. Paid: `complete` with payment still to come is what a
  // delayed method sends first, and its money arrives, or does not, in
  // `async_payment_succeeded`.
  if (event?.type === 'checkout.session.completed' || event?.type === 'checkout.session.async_payment_succeeded') {
    if (object.mode !== undefined && object.mode !== 'subscription') return null;
    if (object.payment_status !== 'paid' && object.payment_status !== 'no_payment_required') return null;
    const key = object.metadata?.key;
    const subscription = typeof object.subscription === 'string' ? object.subscription : object.subscription?.id;
    if (!/^[0-9a-f]{64}$/.test(key ?? '') || !subscription) return null;
    // The date is the subscription's to say, and its own event may not
    // have arrived yet: bound now, dated on the first ask after it has.
    const known = await store.get(`SUB#${subscription}`, 'META');
    await store.put(`SUB#${subscription}`, `DEVICE#${key}`, { bound_at: today });
    await keepCustomer(store, subscription, object.customer);
    await store.put(`KEY#${key}`, 'ENTITLEMENT', {
      subscription,
      licensed_until: known?.renews_at ?? null,
      at: today,
    });
    return { bound: key, subscription };
  }
  if (event?.type?.startsWith('customer.subscription.')) {
    const subscription = object.id;
    if (!subscription) return null;
    await keepCustomer(store, subscription, object.customer);
    const period = object.current_period_end ?? object.items?.data?.[0]?.current_period_end;
    // Ended: Stripe deleted it, or dunning gave up, or it was refunded
    // out. A subscription that is merely *cancelling* is not this — it
    // runs to the end of what was paid for, which is what renews_at
    // already says.
    const final = event.type.endsWith('.deleted') || FINAL.has(object.status);
    return dateSubscription(store, subscription, {
      source: 'stripe',
      txn_ref: object.latest_invoice ?? null,
      until: period ? period * 1000 : null,
      gone: final || ENDED.has(object.status),
      final,
      cancelledAt: object.canceled_at ? object.canceled_at * 1000 : null,
      created: Number.isSafeInteger(event.created) ? event.created : null,
      now,
    });
  }
  return null;
}

/// What a store says of a subscription, written down — Stripe, the App
/// Store or Google Play alike. [until] is when what was paid for runs
/// out, in ms; [gone] that it has ended now (refunded, revoked, given
/// up on); [final] that nothing after this is news. [created] is when
/// the store said it, in seconds, or null. Returns what was recorded,
/// or null when it was not news.
export async function dateSubscription(store, subscription, { source, txn_ref = null, until, gone = false, final = false, cancelledAt = null, created = null, now = Date.now() }) {
  const today = dayOf(now);
  // Stores do not promise to deliver in order, and a delivery that
  // failed is tried again for days: an update from before the end can
  // arrive after it. An event older than the one that wrote the row is
  // not news, and nothing is news after the end.
  const known = await store.get(`SUB#${subscription}`, 'META');
  if (known?.final) return null;
  if (created !== null && known?.event_at != null && created < known.event_at) return null;
  const renews_at = gone ? today : until ? dayOf(until) : null;
  await store.put(`SUB#${subscription}`, 'META', {
    source,
    txn_ref,
    renews_at,
    cancelled_at: cancelledAt ? dayOf(cancelledAt) : gone ? today : null,
    event_at: created ?? known?.event_at ?? null,
    ...(final ? { final: true } : {}),
  });
  // The devices under it hold a copy of the date so that a licence is
  // one read (doc 06). A renewal may leave those copies stale — they
  // catch up by themselves, later is harmless. An ending may not: a
  // copy that outlived its subscription would go on licensing a
  // refunded device for as long as a year. Five rows, once.
  if (gone) {
    for (const sk of await store.under(`SUB#${subscription}`, 'DEVICE#')) {
      const key = sk.slice('DEVICE#'.length);
      const row = await store.get(`KEY#${key}`, 'ENTITLEMENT');
      if (row?.subscription !== subscription) continue;
      await store.put(`KEY#${key}`, 'ENTITLEMENT', { ...row, licensed_until: today, at: today });
    }
  }
  return { subscription, renews_at };
}

/// The Stripe customer behind [subscription], kept so a device on it can
/// open the billing portal. A row of its own, since the subscription's
/// META is written whole by every subscription event.
async function keepCustomer(store, subscription, customer) {
  const id = typeof customer === 'string' ? customer : customer?.id;
  if (typeof id !== 'string' || !/^cus_[A-Za-z0-9]{1,64}$/.test(id)) return;
  const known = await store.get(`SUB#${subscription}`, 'CUSTOMER');
  if (known?.customer !== id) await store.put(`SUB#${subscription}`, 'CUSTOMER', { customer: id });
}

// ---- managing a web subscription ------------------------------------------
// A web subscriber cancels, changes card or reads an invoice in Stripe's
// own billing portal: the service opens a session for the subscription's
// customer and the device goes there, as it went to the checkout. Any
// device on the subscription may, as any may drop another: a household
// that lost the phone that paid still has to be able to cancel. A
// subscription bought in a store is managed in the store, and local
// mode's open house was never bought at all.

/// A billing portal session for the subscription [key] is on: {status, body}.
export async function manage(key, back, store, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  if (!secret) return { status: 503, body: { error: 'the shop is not open yet' } };
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  const subscription = held?.subscription;
  if (!subscription) return { status: 402, body: { error: 'no subscription' } };
  if (!subscription.startsWith('sub_')) return { status: 409, body: { error: 'not a web subscription' } };
  // Bound to it, not merely once on it: a dropped device keeps no say.
  if (!(await store.get(`SUB#${subscription}`, `DEVICE#${key}`))) return { status: 402, body: { error: 'no subscription' } };
  const auth = { authorization: `Bearer ${secret}` };
  let customer = (await store.get(`SUB#${subscription}`, 'CUSTOMER'))?.customer;
  if (!customer) {
    // Bought before the customer was kept: Stripe knows.
    try {
      const res = await fetchImpl(`${STRIPE}/subscriptions/${encodeURIComponent(subscription)}`, { headers: auth });
      if (res.ok) customer = (await res.json())?.customer;
    } catch {
      return { status: 502, body: { error: 'the shop is not answering' } };
    }
    if (typeof customer !== 'string' || !/^cus_[A-Za-z0-9]{1,64}$/.test(customer)) {
      return { status: 502, body: { error: 'the shop does not know this subscription' } };
    }
    await keepCustomer(store, subscription, customer);
  }
  let res;
  try {
    res = await fetchImpl(`${STRIPE}/billing_portal/sessions`, {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ customer, return_url: back }).toString(),
    });
  } catch {
    return { status: 502, body: { error: 'the shop is not answering' } };
  }
  if (!res.ok) return { status: 502, body: { error: `the shop said ${res.status}` } };
  let session;
  try {
    session = await res.json();
  } catch {
    return { status: 502, body: { error: 'the shop talked nonsense' } };
  }
  if (typeof session.url !== 'string') return { status: 502, body: { error: 'the shop gave no portal' } };
  return { status: 200, body: { url: session.url } };
}

// ---- a subscription is a person's, not a device's ----------------------
// Five devices to a subscription, and any of them can drop another.
// Unbounded sharing is a subscription shared with the internet; five is
// a household (doc 06).
//
// A second device is brought in by a code: the subscribed device shows
// one, the new device arrives carrying it, and it is spent. The code is
// a random sixteen bytes and nothing else. The design has it carry the
// subscription and an expiry under a signature; what is built keeps
// both here instead, for two reasons that only showed up against a
// camera. A code that has to be spent needs a row whatever it carries,
// so a signature saves no lookup — and a code three times longer is a
// QR three times denser, read across a table by a phone that is not
// quite still. Keeping it here also keeps the subscription off the
// wire, which a photograph of a screen would otherwise carry away.


/// How long a code is worth anything. Long enough to walk a phone over,
/// short enough that a photograph of the screen is not a key.

/// How long a code's row is kept, spent or not, before the store lets
/// it go by itself: an hour, so that a late scan is told the code ran
/// out rather than that it never was. Without it every code ever made
/// would be a row for ever.
const TICKET_KEPT_S = 60 * 60;

const TICKET_BYTES = 16;

const nonce = () => hex(crypto.getRandomValues(new Uint8Array(TICKET_BYTES)));

/// The devices on a subscription, oldest binding first.
export async function devicesOn(store, subscription) {
  const found = [];
  for (const sk of await store.under(`SUB#${subscription}`, 'DEVICE#')) {
    const key = sk.slice('DEVICE#'.length);
    const row = await store.get(`SUB#${subscription}`, sk);
    found.push({ key, bound_at: row?.bound_at ?? null });
  }
  return found.sort((a, b) => String(a.bound_at).localeCompare(String(b.bound_at)) || a.key.localeCompare(b.key));
}

/// How long an outstanding code must still have to be handed out again
/// rather than replaced: enough to walk a phone over.

/// A code for a new device to arrive with: {status, body}. The one
/// already outstanding, while it is unspent and has time left: asking
/// again is a read, not a new row and a listing of the household — a
/// subscriber asking in a loop would otherwise spend the store's writes
/// for everyone, Stripe's included (docs/security-review.md, 10).
export async function ticketFor(key, store, { now = Date.now() } = {}) {
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return { status: 402, body: { error: 'no subscription' } };
  const out = await store.get(`SUB#${held.subscription}`, 'TICKET');
  if (out && Date.parse(out.expires_at) - now >= S().ticketReuseMinutes * 60000) {
    const ticket = await store.get(`TICKET#${out.code}`, 'META');
    if (ticket && !ticket.used_at) {
      return { status: 200, body: { ticket: out.code, expires_at: out.expires_at, devices: out.devices, most: S().mostDevices } };
    }
  }
  const devices = await devicesOn(store, held.subscription);
  if (devices.length >= S().mostDevices) {
    return { status: 409, body: { error: 'five devices already', devices: devices.length, most: S().mostDevices } };
  }
  const code = nonce();
  const expires_at = new Date(now + S().ticketMinutes * 60000).toISOString();
  await store.put(`TICKET#${code}`, 'META', { subscription: held.subscription, expires_at, used_at: null, made_by: key }, { ttl: TICKET_KEPT_S });
  await store.put(`SUB#${held.subscription}`, 'TICKET', { code, expires_at, devices: devices.length }, { ttl: TICKET_KEPT_S });
  return { status: 200, body: { ticket: code, expires_at, devices: devices.length, most: S().mostDevices } };
}

/// A device arriving with a code. The code is spent whether or not the
/// licence that follows can be signed: a code that could be tried twice
/// is not a code that was spent once.
export async function claimWith(key, code, store, { now = Date.now() } = {}) {
  if (typeof code !== 'string' || !/^[0-9a-f]{2,64}$/.test(code)) return { status: 400, body: { error: 'not a code' } };
  const ticket = await store.get(`TICKET#${code}`, 'META');
  if (!ticket) return { status: 404, body: { error: 'no such code' } };
  if (ticket.used_at) return { status: 409, body: { error: 'that code has been used' } };
  if (Date.parse(ticket.expires_at) <= now) return { status: 410, body: { error: 'that code has run out' } };
  const today = dayOf(now);
  return joinSubscription(key, ticket.subscription, store, {
    now,
    spend: () => store.put(`TICKET#${code}`, 'META', { ...ticket, used_at: today, used_by: key }, { ttl: TICKET_KEPT_S }),
  });
}

// ---- backup codes ----------------------------------------------------------
// A code on the screen of a device already on the subscription is good
// for ten minutes; a backup code is good until it is used or replaced.
// It is for the day there is no such screen: a phone lost, a new one in
// hand. Five to a subscription, each good once, kept with the
// subscription and shown on any device bound to it; replaced all five
// at once from any of them, which spends the old ones. The person who
// paid on the web is sent them by email when the subscription is made
// and again when they are replaced — to the address Stripe holds, read
// from Stripe when it is needed and not kept here.
//
// Sixteen characters of Crockford's base32, eighty bits, read and typed
// by a person: no I, L, O or U, case and dashes ignored, and an O, I or
// L typed is taken as the 0 or 1 it looks like. A code's row is keyed
// by its digest, so a listing of the store does not list the codes.

export const BACKUP_CODES = 5;
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

function backupCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  let bits = 0;
  let value = 0;
  let out = '';
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += CROCKFORD[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  return out.match(/.{4}/g).join('-');
}

/// [text] as a backup code, XXXX-XXXX-XXXX-XXXX, or null when it is not
/// one: what a person typed or pasted, read generously.
export function backupCodeOf(text) {
  if (typeof text !== 'string' || text.length > 64) return null;
  const plain = text
    .toUpperCase()
    .replace(/[\s-]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1');
  if (!/^[0-9A-HJKMNP-TV-Z]{16}$/.test(plain)) return null;
  return plain.match(/.{4}/g).join('-');
}

const backupRow = async (code) => `BACKUP#${await digestOf(`oh-backup/1\n${code}`)}`;

/// Five new codes for [subscription], replacing any it had: their rows
/// go, so an old one is no such code. Returns the household's row.
async function makeBackups(store, subscription, { now }) {
  const old = await store.get(`SUB#${subscription}`, 'BACKUP');
  for (const c of old?.codes ?? []) await store.del(await backupRow(c.code), 'META');
  const codes = [];
  while (codes.length < BACKUP_CODES) {
    const code = backupCode();
    if (!codes.some((c) => c.code === code)) codes.push({ code, used_at: null });
  }
  for (const c of codes) await store.put(await backupRow(c.code), 'META', { subscription });
  const row = { codes, made_at: new Date(now).toISOString(), emailed_at: null };
  await store.put(`SUB#${subscription}`, 'BACKUP', row);
  return row;
}

/// The codes as a device on the subscription is shown them.
const backupsShown = (row) => ({ codes: row.codes.map((c) => ({ code: c.code, used: c.used_at !== null })), made_at: row.made_at });

/// Sends [row]'s codes to [email] with [mail], and notes that it did:
/// {row, unsent}, [unsent] null when it went and otherwise why not —
/// `no address`, `no mail` (Email Sending not bound here), `no codes`
/// (all used) or `failed`. Every one that did not go is logged; the
/// codes are on every device on the subscription regardless.
async function mailBackups(store, subscription, row, email, mail, { now, why = null }) {
  const codes = row.codes.filter((c) => c.used_at === null).map((c) => c.code);
  const unsent = !mail ? 'no mail' : typeof email !== 'string' || !email.includes('@') ? 'no address' : codes.length === 0 ? 'no codes' : null;
  if (unsent) {
    console.log(`backup codes for ${subscription}: not sent: ${unsent}${why ? ` (${String(why).slice(0, 200)})` : ''}`);
    return { row, unsent };
  }
  try {
    await mail(email, codes);
  } catch (e) {
    console.log(`backup codes for ${subscription}: not sent: ${e?.code ?? ''} ${e?.message ?? e}`);
    return { row, unsent: 'failed' };
  }
  console.log(`backup codes for ${subscription}: sent`);
  const sent = { ...row, emailed_at: new Date(now).toISOString() };
  await store.put(`SUB#${subscription}`, 'BACKUP', sent);
  return { row: sent, unsent: null };
}

/// A subscription just paid for: its codes, made once, and sent to the
/// payer once. A webhook delivered twice finds them made, and sends
/// only if the first send did not go.
export async function backupsMade(subscription, email, store, mail, { now = Date.now() } = {}) {
  let row = await store.get(`SUB#${subscription}`, 'BACKUP');
  if (!row) row = await makeBackups(store, subscription, { now });
  if (!row.emailed_at) ({ row } = await mailBackups(store, subscription, row, email, mail, { now }));
  return { status: 200, body: { made_at: row.made_at, emailed: row.emailed_at !== null } };
}

/// The codes, for a device bound to the subscription: made if there are
/// none yet (a subscription from before them, or bought in a store),
/// and replaced when [rotate]; with [send], the ones still good sent to
/// [email], the payer's, when a device asks (the Email button) — and
/// `emailed`, or `unsent` and why not, in the answer.
export async function backupsFor(key, store, mail, { rotate = false, send = false, email = null, why = null, now = Date.now() } = {}) {
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return { status: 402, body: { error: 'no subscription' } };
  if (!(await store.get(`SUB#${held.subscription}`, `DEVICE#${key}`))) return { status: 402, body: { error: 'no subscription' } };
  let row = await store.get(`SUB#${held.subscription}`, 'BACKUP');
  if (!row || rotate) row = await makeBackups(store, held.subscription, { now });
  if (!send) return { status: 200, body: { ...backupsShown(row), emailed: false } };
  const mailed = await mailBackups(store, held.subscription, row, email, mail, { now, why });
  return { status: 200, body: { ...backupsShown(mailed.row), emailed: mailed.unsent === null, ...(mailed.unsent ? { unsent: mailed.unsent } : {}) } };
}

/// A device arriving with a backup code. Spent only by a join that
/// goes through: a code turned down for a full household is still good
/// once a device is dropped.
export async function redeemBackup(key, code, store, { now = Date.now() } = {}) {
  const at = await store.get(await backupRow(code), 'META');
  if (!at) return { status: 404, body: { error: 'no such code' } };
  const row = await store.get(`SUB#${at.subscription}`, 'BACKUP');
  const mine = row?.codes.find((c) => c.code === code);
  if (!mine) return { status: 404, body: { error: 'no such code' } };
  if (mine.used_at) return { status: 409, body: { error: 'that code has been used' } };
  const today = dayOf(now);
  return joinSubscription(key, at.subscription, store, {
    now,
    spend: () =>
      store.put(`SUB#${at.subscription}`, 'BACKUP', {
        ...row,
        codes: row.codes.map((c) => (c.code === code ? { ...c, used_at: today } : c)),
      }),
  });
}

/// [key] onto [subscription], by the household's rules: no more devices
/// than it carries, and not off another subscription that is still paid
/// up unless [moving] — which only the device that paid for this one
/// is. [spend] runs once those are met and before anything is written:
/// a code is used up then, and not by a join that was refused.
export async function joinSubscription(key, subscription, store, { now = Date.now(), moving = false, spend = null } = {}) {
  const devices = await devicesOn(store, subscription);
  const already = devices.some((d) => d.key === key);
  if (!already && devices.length >= S().mostDevices) {
    return { status: 409, body: { error: 'five devices already', devices: devices.length, most: S().mostDevices } };
  }
  const today = dayOf(now);
  // A device on another subscription that is still paid up stays on
  // it. A code arrives in a link, so a link from a stranger with a
  // subscription of his own would otherwise take a device off the one
  // its owner paid for, onto one where he can drop it. Leaving is the
  // device's own to do, by dropping itself first — or by buying a
  // subscription of its own, which is as plain a word as it can say. A
  // subscription that has ended holds nothing, and neither does local
  // mode's open house, which licenses every device that asks and was
  // never anybody's purchase.
  const was = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (was && was.subscription !== subscription && !moving) {
    const theirs = await store.get(`SUB#${was.subscription}`, 'META');
    if (theirs && theirs.source !== 'local' && theirs.renews_at && theirs.renews_at >= today) {
      return { status: 409, body: { error: 'this device is on another subscription: drop it there first' } };
    }
  }
  if (spend) await spend();
  // A device that was on another subscription leaves it rather than
  // counting against both.
  if (was && was.subscription !== subscription) await store.del(`SUB#${was.subscription}`, `DEVICE#${key}`);
  const sub = await store.get(`SUB#${subscription}`, 'META');
  if (!already) await store.put(`SUB#${subscription}`, `DEVICE#${key}`, { bound_at: today });
  await store.put(`KEY#${key}`, 'ENTITLEMENT', {
    subscription,
    licensed_until: sub?.renews_at ?? null,
    at: today,
  });
  return { status: 200, body: { subscription } };
}

/// Dropping a device: any device on the subscription can drop any
/// other, its own self included — which is how a device is handed on.
export async function dropDevice(key, device, store, { now = Date.now() } = {}) {
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return { status: 402, body: { error: 'no subscription' } };
  const devices = await devicesOn(store, held.subscription);
  if (!devices.some((d) => d.key === device)) return { status: 404, body: { error: 'not a device on this subscription' } };
  await store.del(`SUB#${held.subscription}`, `DEVICE#${device}`);
  // And the entitlement that device holds, which is gone rather than
  // run out: a licence is one read, and a row saying it is paid up to
  // next year would be that read. Its own copy of the date is not the
  // only thing that would say so — a row dated today falls through to
  // the subscription on the next ask, and the subscription is still
  // paid up. It is the binding that ended, so the binding is what goes.
  const theirs = await store.get(`KEY#${device}`, 'ENTITLEMENT');
  if (theirs?.subscription === held.subscription) await store.del(`KEY#${device}`, 'ENTITLEMENT');
  return { status: 200, body: { devices: (await devicesOn(store, held.subscription)).length, most: S().mostDevices } };
}

// ---- one household at a time ------------------------------------------
// A code made, a code spent, a device dropped, the list read: each reads
// the household and writes it in separate calls, and KV has no
// compare-and-set, so two at once could both find room for a fifth
// device and make six (docs/security-review.md, 9). They run one after
// another per subscription instead: in a Durable Object per
// subscription where the project binds one as HOUSEHOLD (one object,
// one thread, wherever in the world the requests come from), and in
// this isolate's own queue where it does not — which covers requests
// that land together on one isolate and no more. The same place keeps a
// household to so many of them an hour, which is what keeps one
// subscriber from spending the store's daily writes and lists.

/// What one household may do in an hour: changes (a code, a claim, a
/// drop) and readings of its list. A person adding a phone does a
/// handful of each.

/// One household's queue and its hour: everything asked of it runs in
/// order, and what is over the hour's allowance is refused before it
/// touches the store.
export function sequencer({ now = Date.now } = {}) {
  let queue = Promise.resolve();
  const done = { change: [], read: [] };
  return (kind, work) => {
    const run = queue.then(async () => {
      const t = now();
      const recent = (done[kind] = done[kind].filter((at) => t - at < 3600000));
      const most = kind === 'read' ? S().householdReadsPerHour : S().householdChangesPerHour;
      if (recent.length >= most) return { status: 429, body: { error: 'too many at once: try again in a while' } };
      recent.push(t);
      return work();
    });
    queue = run.catch(() => {});
    return run;
  };
}

/// What a household is asked: {op: 'ticket' | 'claim' | 'drop' | 'list', ...}.
export async function householdOp(op, store, { now = Date.now(), mail = null } = {}) {
  switch (op.op) {
    case 'ticket':
      return ticketFor(op.key, store, { now });
    case 'claim':
      return claimWith(op.key, op.code, store, { now });
    case 'redeem':
      return redeemBackup(op.key, op.code, store, { now });
    case 'backups':
      return backupsFor(op.key, store, mail, { rotate: op.rotate === true, send: op.send === true, email: op.email ?? null, why: op.why ?? null, now });
    case 'made':
      return backupsMade(op.subscription, op.email ?? null, store, mail, { now });
    case 'bind':
      return bindPurchase(op, store, { now });
    case 'drop':
      return dropDevice(op.key, op.device, store, { now });
    case 'list': {
      const held = await store.get(`KEY#${op.key}`, 'ENTITLEMENT');
      if (!held) return { status: 402, body: { error: 'no subscription' } };
      return { status: 200, body: { devices: await devicesOn(store, held.subscription), most: S().mostDevices } };
    }
    default:
      return { status: 400, body: { error: 'not a household operation' } };
  }
}

const kindOf = (op) => (op.op === 'list' || (op.op === 'backups' && op.rotate !== true) ? 'read' : 'change');

/// How backup codes are emailed where [env] can: Cloudflare's Email
/// Sending, bound as EMAIL to the worker the household runs in, from
/// OH_MAIL_FROM, answered at OH_MAIL_REPLY_TO where that is set. Null
/// where the binding or the sender is missing, and the codes are only
/// shown on the devices.
export function mailerOf(env) {
  const from = env.OH_MAIL_FROM;
  if (!env.EMAIL || typeof from !== 'string' || !from.includes('@')) return null;
  const replyTo = typeof env.OH_MAIL_REPLY_TO === 'string' && env.OH_MAIL_REPLY_TO.includes('@') ? env.OH_MAIL_REPLY_TO : null;
  return (to, codes) =>
    env.EMAIL.send({
      to,
      from: { email: from, name: 'Open Hearts' },
      ...(replyTo ? { replyTo } : {}),
      subject: 'Your Open Hearts backup codes',
      text: backupMailText(codes),
      html: backupMailHtml(codes),
    });
}

/// The email itself: the codes, and how to use one.
export function backupMailText(codes) {
  return [
    'Your Open Hearts backup codes:',
    '',
    ...codes.map((c) => `  ${c}`),
    '',
    'Each one brings one device onto your subscription, once. On the',
    'device: menu, Activate subscription, and type or paste a code.',
    '',
    'Any device on the subscription shows these codes under Subscription,',
    'can email them here again, and can replace them with new ones, after',
    'which the codes above stop working.',
    '',
    'Open Hearts — https://openhearts.game',
  ].join('\n');
}

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/// The same email as a page, for the mail readers that prefer one: the
/// same words, the codes set in a fixed-width face.
export function backupMailHtml(codes) {
  const code = (c) => `<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:18px;letter-spacing:1px;margin:4px 0">${escapeHtml(c)}</div>`;
  return [
    '<!doctype html><html><body style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1b1b1b">',
    '<p>Your Open Hearts backup codes:</p>',
    `<div style="margin:12px 0 16px 0">${codes.map(code).join('')}</div>`,
    '<p>Each one brings one device onto your subscription, once. On the device: menu, <b>Activate subscription</b>, and type or paste a code.</p>',
    '<p>Any device on the subscription shows these codes under Subscription, can email them here again, and can replace them with new ones, after which the codes above stop working.</p>',
    '<p style="color:#666">Open Hearts — <a href="https://openhearts.game">openhearts.game</a></p>',
    '</body></html>',
  ].join('\n');
}

/// The Durable Object a household runs in, one per subscription, named
/// by it. Exported from the relay's worker beside TagRelay
/// (service/do/worker.mjs), bound to the Pages project as HOUSEHOLD;
/// it reads and writes the same OH_STORE.
export class Household {
  constructor(state, env) {
    this.env = env;
    this.next = sequencer();
  }

  async fetch(request) {
    const op = await request.json();
    await settle(this.env);
    const store = storeOf(this.env);
    if (!store) return Response.json({ status: 503, body: { error: 'licensing not configured' } });
    return Response.json(await this.next(kindOf(op), () => householdOp(op, store, { mail: mailerOf(this.env) })));
  }
}

/// This isolate's queues, by subscription, for a project with no
/// HOUSEHOLD bound.
const households = new Map();

/// [op] run in [subscription]'s household, in its turn: {status, body}.
export async function inHousehold(env, subscription, op) {
  if (env.HOUSEHOLD) {
    const stub = env.HOUSEHOLD.get(env.HOUSEHOLD.idFromName(subscription));
    const answer = await stub.fetch('https://household/', { method: 'POST', body: JSON.stringify(op) });
    return answer.json();
  }
  const store = storeOf(env);
  if (!store) return { status: 503, body: { error: 'licensing not configured' } };
  if (!households.has(subscription)) households.set(subscription, sequencer());
  return households.get(subscription)(kindOf(op), () => householdOp(op, store, { mail: mailerOf(env) }));
}

/// Forgets this isolate's queues, for a test that starts afresh.
export const forgetHouseholds = () => households.clear();

async function ticketRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'ticket');
  if (asked instanceof Response) return asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const held = await store.get(`KEY#${asked.key}`, 'ENTITLEMENT');
  if (!held) return json(request, 402, { error: 'no subscription' });
  const { status, body: out } = await inHousehold(env, held.subscription, { op: 'ticket', key: asked.key });
  return json(request, status, out);
}

async function claimRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // The code is part of what is signed: a device binds itself with the
  // code it was shown, and nobody binds it with another.
  const asked = await signedFor(request, env, 'claim', (body) => (typeof body.ticket === 'string' ? body.ticket : ''));
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  // In the household the code is for, which the code's row says; a code
  // nobody made is said so here, without queueing anybody.
  // A backup code, typed by a person, or a code off another device's
  // screen: sixteen characters of one alphabet, or thirty-two hex.
  const backup = backupCodeOf(body.ticket);
  let claimed;
  if (backup) {
    const at = await store.get(await backupRow(backup), 'META');
    if (!at) return json(request, 404, { error: 'no such code' });
    claimed = await inHousehold(env, at.subscription, { op: 'redeem', key, code: backup });
  } else {
    if (typeof body.ticket !== 'string' || !/^[0-9a-f]{2,64}$/.test(body.ticket)) return json(request, 400, { error: 'not a code' });
    const ticket = await store.get(`TICKET#${body.ticket}`, 'META');
    if (!ticket) return json(request, 404, { error: 'no such code' });
    claimed = await inHousehold(env, ticket.subscription, { op: 'claim', key, code: body.ticket });
  }
  if (claimed.status !== 200) return json(request, claimed.status, claimed.body);
  // Straight back with the licence it was claimed for, so the device
  // that scanned a code is playing rather than waiting to be told.
  const { status, body: out } = await licence(key, env, { signer, open: openHouse(env, request) });
  return json(request, status, out);
}

/// The email Stripe holds for the customer behind [subscription], or
/// null: read when backup codes are sent, and not kept.
export async function payerEmail(store, subscription, env, fetchImpl = fetch) {
  return (await payerLookup(store, subscription, env, fetchImpl)).email;
}

/// [payerEmail], with why there is none: {email, why}. The why goes to
/// the household with the ask, which logs it beside the send it
/// stopped (the relay's log is the one that can be read afterwards).
export async function payerLookup(store, subscription, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  if (!secret) return { email: null, why: 'no Stripe key' };
  if (typeof subscription !== 'string' || !subscription.startsWith('sub_')) return { email: null, why: 'not a web subscription' };
  const customer = (await store.get(`SUB#${subscription}`, 'CUSTOMER'))?.customer;
  if (!customer) return { email: null, why: 'no customer on record' };
  try {
    const res = await fetchImpl(`${STRIPE}/customers/${encodeURIComponent(customer)}`, { headers: { authorization: `Bearer ${secret}` } });
    if (!res.ok) {
      const code = (await res.json().catch(() => null))?.error?.code;
      return { email: null, why: `Stripe said ${res.status}${code ? ` (${code})` : ''}` };
    }
    const email = (await res.json())?.email;
    return typeof email === 'string' && email.includes('@') ? { email, why: null } : { email: null, why: 'no email on the customer' };
  } catch (e) {
    return { email: null, why: `Stripe unreachable: ${e?.message ?? e}` };
  }
}

async function backupsRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'backups', (body) => (body.rotate === true ? 'rotate' : body.send === true ? 'send' : ''));
  if (asked instanceof Response) return asked;
  const { key, body } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return json(request, 402, { error: 'no subscription' });
  const rotate = body.rotate === true;
  const send = !rotate && body.send === true;
  const payer = send ? await payerLookup(store, held.subscription, env) : { email: null, why: null };
  const { status, body: out } = await inHousehold(env, held.subscription, { op: 'backups', key, rotate, send, email: payer.email, why: payer.why });
  return json(request, status, out);
}

/// A finished game's record, sent by one of its players' devices to be
/// kept (records.mjs): signed for the table it is the record of.
async function recordRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // A game's record is a few hundred kilobytes, where every other
  // signed ask is a few hundred bytes.
  const asked = await signedFor(request, env, 'record', (body) => (typeof body.table === 'string' ? body.table : ''), {
    most: recordMost + 4096,
  });
  if (asked instanceof Response) return asked;
  const { status, body } = await keepRecord(env.OH_RECORDS, asked.key, asked.body.table, asked.body.record);
  return json(request, status, body);
}

async function devicesRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'devices', (body) => (typeof body.drop === 'string' ? body.drop : ''));
  if (asked instanceof Response) return asked;
  const { key, body } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const drop = body.drop;
  if (typeof drop === 'string' && !/^[0-9a-f]{64}$/.test(drop)) return json(request, 400, { error: 'a table key, 64 hex' });
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return json(request, 402, { error: 'no subscription' });
  if (typeof drop === 'string') {
    const { status, body: out } = await inHousehold(env, held.subscription, { op: 'drop', key, device: drop });
    if (status !== 200) return json(request, status, out);
  }
  const { status, body: out } = await inHousehold(env, held.subscription, { op: 'list', key });
  return json(request, status, out);
}

// ---- who this is, where a provider will say ----------------------------
// A subscription follows a person. A code (above) is how the person
// brings their own second device in; a provider account is how they
// come back to one they no longer have — a phone in a river is not a
// phone that can show a code.
//
// What is stored of the provider is an HMAC of its subject identifier,
// never the identifier: it is opaque but stable and joins to a real
// account, so a leaked table has to join to nothing. And nothing on the
// KEY# side leads back to the provider — the key is what public records
// carry (doc 06).

const PROVIDERS = {
  apple: { iss: 'https://appleid.apple.com', jwks: 'https://appleid.apple.com/auth/keys', audience: 'OH_APPLE_AUDIENCE' },
  google: { iss: 'https://accounts.google.com', jwks: 'https://www.googleapis.com/oauth2/v3/certs', audience: 'OH_GOOGLE_AUDIENCE' },
};

/// How long a fetched key set is kept. The providers rotate slowly and
/// publish ahead of it; a miss re-fetches anyway.
const JWKS_MINUTES = 60;

const jwks = new Map();

/// Forgets the cached key sets. For the tests, which stand up a
/// provider of their own; nothing in production calls it.
export const forgetProviderKeys = () => jwks.clear();

/// A provider's signing keys, cached per isolate. [fetchImpl] is the
/// seam the tests put their own provider behind.
export async function keysOf(provider, fetchImpl = fetch, { now = Date.now() } = {}) {
  const held = jwks.get(provider);
  if (held && held.until > now) return held.keys;
  const res = await fetchImpl(PROVIDERS[provider].jwks);
  if (!res.ok) throw new Error(`${provider} keys ${res.status}`);
  const { keys } = await res.json();
  if (!Array.isArray(keys)) throw new Error(`${provider} keys are not a set`);
  jwks.set(provider, { keys, until: now + JWKS_MINUTES * 60000 });
  return keys;
}

const un64 = (s) => {
  const padded = s.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(padded + '='.repeat((4 - (padded.length % 4)) % 4)), (c) => c.charCodeAt(0));
};

const ALGS = {
  RS256: { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
  ES256: { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' },
};

/// What a provider's sign-in token says, once it has been checked
/// against that provider's own keys; null when it does not check out.
///
/// The token has to name the device it was minted for. Every provider
/// carries a caller's nonce through, so the app puts the hash of its
/// key there — without it, a token lifted from one app's traffic would
/// bind somebody else's account to the lifter's key.
export async function whoSignedIn(provider, token, key, env, fetchImpl = fetch, { now = Date.now(), open = false } = {}) {
  // Local mode's own token: a subject and nothing else, taken only
  // where the open house is (doc 06). One branch, never on in
  // production, and the rest of the path below is the same path.
  if (open && typeof token === 'string' && token.startsWith('local:')) {
    const sub = token.slice('local:'.length);
    return sub && PROVIDERS[provider] ? { provider, sub } : null;
  }
  const known = PROVIDERS[provider];
  const audience = known && env[known.audience];
  if (!known || !audience) return null;
  const claims = await jwtOf(provider, token, fetchImpl, { now });
  if (!claims) return null;
  if (claims.iss !== known.iss) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(audience)) return null;
  if (!(typeof claims.exp === 'number') || claims.exp * 1000 <= now) return null;
  if (typeof claims.sub !== 'string' || !claims.sub) return null;
  if (claims.nonce !== (await digestOf(`oh-signin/1\n${key}`))) return null;
  return { provider, sub: claims.sub };
}

/// The claims of a JWT signed by one of [provider]'s published keys;
/// null when it is not. What the claims must say is the caller's to
/// check.
export async function jwtOf(provider, token, fetchImpl = fetch, { now = Date.now() } = {}) {
  const parts = String(token ?? '').split('.');
  if (parts.length !== 3) return null;
  let header;
  let claims;
  let sig;
  try {
    header = JSON.parse(new TextDecoder().decode(un64(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(un64(parts[1])));
    sig = un64(parts[2]);
  } catch {
    return null;
  }
  const alg = ALGS[header?.alg];
  if (!alg) return null;
  let keys;
  try {
    keys = await keysOf(provider, fetchImpl, { now });
  } catch {
    return null;
  }
  // The kid names one; without one every key in the set is tried, which
  // is at most a handful and is what a rotation looks like from here.
  const candidates = keys.filter((k) => (header.kid ? k.kid === header.kid : true) && (k.alg ?? header.alg) === header.alg);
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  let ok = false;
  for (const jwk of candidates) {
    try {
      const imported = await crypto.subtle.importKey('jwk', { ...jwk, ext: true }, alg, false, ['verify']);
      if (await crypto.subtle.verify(alg.name === 'ECDSA' ? { name: 'ECDSA', hash: 'SHA-256' } : alg, imported, sig, signed)) {
        ok = true;
        break;
      }
    } catch {
      // A key that will not import is a key that did not sign this.
    }
  }
  return ok ? claims : null;
}

/// The identifier as it is stored: an HMAC, so a leaked table joins to
/// nothing. Null when there is no secret to key it with, which is a
/// service that must not be storing identifiers at all.
export async function loginRow(who, env) {
  const secret = env.OH_ID_HMAC;
  if (!secret || !who) return null;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const mac = hex(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${who.provider}:${who.sub}`))));
  return `LOGIN#${who.provider}#${mac}`;
}

/// Binds a sign-in to [key], once. A login already bound to another
/// device is a refusal rather than a second binding: moving to a new
/// device is [supersede], which says what it is replacing.
export async function attest(who, key, store, env, { now = Date.now() } = {}) {
  const login = await loginRow(who, env);
  if (!login) return { status: 503, body: { error: 'sign-in is not configured' } };
  const today = dayOf(now);
  const held = await store.get(login, 'IDENTITY');
  if (held && held.key !== key) return { status: 409, body: { error: 'that account is already on another device' } };
  if (!held) await store.put(login, 'IDENTITY', { key, created_at: today });
  // What the key's own row carries is that it was attested and when —
  // never by whom. The key is what public records carry.
  await store.put(`KEY#${key}`, 'META', { provider: who.provider, attested_at: today });
  return { status: 200, body: { attested: today } };
}

/// The same account on a new device: the entitlement of the key the
/// login was on comes forward to this one, so a licence stays one read,
/// and the login points at the new key from here.
export async function supersede(who, key, store, env, { now = Date.now() } = {}) {
  const login = await loginRow(who, env);
  if (!login) return { status: 503, body: { error: 'sign-in is not configured' } };
  const held = await store.get(login, 'IDENTITY');
  if (!held) return { status: 404, body: { error: 'that account is not on any device' } };
  const today = dayOf(now);
  if (held.key === key) return { status: 200, body: { superseded: null, at: today } };
  const was = held.key;
  await store.put(login, 'IDENTITY', { key, created_at: held.created_at, moved_at: today });
  await store.put(`KEY#${key}`, 'META', { provider: who.provider, attested_at: today });
  await store.put(`KEY#${key}`, 'SUPERSEDES', { predecessor: was, at: today });
  // The subscription the old device was on takes this one in its place.
  // A device the person still holds is not dropped by somebody else
  // signing in on a new one — but the one that was superseded is, since
  // it is the one that is gone.
  const theirs = await store.get(`KEY#${was}`, 'ENTITLEMENT');
  if (theirs) {
    const devices = await devicesOn(store, theirs.subscription);
    if (!devices.some((d) => d.key === key)) {
      if (devices.length >= S().mostDevices) await store.del(`SUB#${theirs.subscription}`, `DEVICE#${was}`);
      await store.put(`SUB#${theirs.subscription}`, `DEVICE#${key}`, { bound_at: today });
    }
    await store.put(`KEY#${key}`, 'ENTITLEMENT', { ...theirs, at: today });
  }
  return { status: 200, body: { superseded: was, at: today } };
}

/// attest and supersede are one route: the same proof, and which of the
/// two it is depends on whether the account has been somewhere before.
async function signInRoute(request, env, move) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // The token names the key its nonce was made for, and the nonce is
  // whoever asked the provider's to choose: a stranger can have his
  // own account signed over somebody else's key. The key signing the
  // request is what says it wanted that account.
  const asked = await signedFor(request, env, move ? 'supersede' : 'attest');
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const who = await whoSignedIn(body.provider, body.token, key, env, fetch, { open: openHouse(env, request) });
  if (!who) return json(request, 401, { error: 'that sign-in does not check out' });
  const { status, body: out } = await (move ? supersede : attest)(who, key, store, env);
  if (status !== 200) return json(request, status, out);
  // Straight back with the licence it is owed, if any: a device that
  // has just proved who it is should not have to ask twice.
  const licensed = await licence(key, env, { signer, open: openHouse(env, request) });
  return json(request, 200, { ...out, ...(licensed.status === 200 ? licensed.body : {}) });
}

async function checkoutRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // The device buys for itself: a checkout paid for somebody else's
  // key would move their device onto a subscription the payer can end.
  const asked = await signedFor(request, env, 'checkout');
  if (asked instanceof Response) return asked;
  const { key, body } = asked;
  const back = sameSite(body.back, request.url);
  const cancelled = sameSite(body.cancelled, request.url);
  if (!back || !cancelled) return json(request, 400, { error: 'somewhere on this site to come back to' });
  const { status, body: out } = await checkout(key, back, cancelled, env);
  return json(request, status, out);
}

async function manageRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'manage');
  if (asked instanceof Response) return asked;
  const back = sameSite(asked.body.back, request.url);
  if (!back) return json(request, 400, { error: 'somewhere on this site to come back to' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const { status, body } = await manage(asked.key, back, store, env);
  return json(request, status, body);
}

async function stripeRoute(request, env) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  const raw = await textOf(request, MOST_EVENT);
  if (raw === null) return json(request, 413, { error: 'too big' });
  if (!(await webhookSigned(request.headers.get('stripe-signature'), raw, env.OH_STRIPE_WEBHOOK_SECRET))) {
    // Nothing is read out of a body nobody signed.
    return json(request, 400, { error: 'not signed' });
  }
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    return json(request, 400, { error: 'not json' });
  }
  const done = await record(event, store);
  // A subscription just paid for: its backup codes, sent to the email
  // the checkout was paid with. Not kept: it is on the event.
  if (done?.bound) {
    const email = event.data?.object?.customer_details?.email ?? null;
    await inHousehold(env, done.subscription, { op: 'made', subscription: done.subscription, email });
  }
  // Anything not ours is still a delivery taken: a webhook that gets an
  // error back is a webhook Stripe keeps sending.
  return json(request, 200, { ok: true });
}

/// The key a handler was called with, or null.
function keyOf(body) {
  const key = body?.key;
  return typeof key === 'string' && /^[0-9a-f]{64}$/.test(key) ? key : null;
}

/// The most a handler's request may carry. Every one of them asks with
/// a key, a signature and a word or two; a body past this is not one of
/// ours, and is not parsed to find out.
const MOST_BODY = 16 * 1024;

/// Stripe's events are larger, and few: a checkout or a subscription,
/// with its line items.
const MOST_EVENT = 512 * 1024;

/// The body as text, or null when it is longer than [most] — said by its
/// length where the request says one, and counted where it does not.
async function textOf(request, most) {
  const said = Number(request.headers.get('content-length'));
  if (Number.isFinite(said) && said > most) return null;
  let text;
  try {
    text = await request.text();
  } catch {
    return null;
  }
  return text.length > most ? null : text;
}

async function bodyOf(request, most = MOST_BODY) {
  const text = await textOf(request, most);
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/// The request read and its signature checked (who is asking, above):
/// {key, body, signer}, or the response to answer with instead.
/// [whatOf] reads what the request asks for out of its body.
async function signedFor(request, env, handler, whatOf = () => '', { most = MOST_BODY } = {}) {
  const body = await bodyOf(request, most);
  if (!keyOf(body)) return json(request, 400, { error: 'a table key, 64 hex' });
  let signer;
  try {
    signer = await signerFor(request, env);
  } catch {
    return json(request, 503, { error: 'the service cannot check signatures yet' });
  }
  const asked = await askedBy(body, handler, whatOf(body), signer);
  if (!asked.key) return json(request, asked.status, asked.body);
  return { key: asked.key, body, signer };
}

/// A preflight, or null when the request is not one; [methods] is what
/// the handler takes.
function preflight(request, methods) {
  if (request.method !== 'OPTIONS') return null;
  return new Response(null, {
    status: 204,
    headers: cors(request, {
      'access-control-allow-methods': `${methods}, OPTIONS`,
      'access-control-allow-headers': 'content-type',
      'access-control-max-age': '86400',
    }),
  });
}

async function licenceRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // Signed, though a licence is for its own key and no use to anybody
  // else: whether a key pays, and until when, is the key's business.
  const asked = await signedFor(request, env, 'licence');
  if (asked instanceof Response) return asked;
  const { status, body } = await licence(asked.key, env, { signer: asked.signer, open: openHouse(env, request) });
  return json(request, status, body);
}

async function turn(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // Credentials are a relay anybody holding them can send anything
  // through for four hours, and it is billed by the gigabyte. So they
  // are a subscribed device's, as live play is, and nobody else's.
  const asked = await signedFor(request, env, 'turn');
  if (asked instanceof Response) return asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  if (!(await entitlementOf(store, asked.key, { openHouse: openHouse(env, request) }))) return json(request, 402, { error: 'no subscription' });
  const { status, body: out } = await mint(env);
  return json(request, status, out);
}

// ---- Remote config ----------------------------------------------------

/// What the app may be told without a new build (doc 06, "Remote
/// config"): one row in the store, which the operator writes and every
/// device reads at its start. What is here when there is no row — or a
/// row this worker cannot read — is what the app does with no config at
/// all, so a bad row is never worse than none.
export const CONFIG_DEFAULTS = Object.freeze({ v: 1, live: true, offer: true, relays: null, banner: null, update: null, feedback: null, privacy: null, terms: null, price: null });

/// Where the row lives: `config|app` in OH_STORE.
const CONFIG_ROW = ['config', 'app'];

const MOST_RELAYS = 8;
const LONGEST_SAY = 280;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/// A sentence in each language it is given in, English required: the
/// app shows the device's language where it is there and English where
/// it is not. Anything else is no sentence at all.
function sayingOf(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = {};
  for (const [lang, text] of Object.entries(raw)) {
    if (!/^[a-z]{2}$/.test(lang) || typeof text !== 'string') continue;
    const t = text.trim();
    if (t && t.length <= LONGEST_SAY) out[lang] = t;
  }
  return out.en ? out : null;
}

/// The row as the app may be given it: every field checked, and any
/// that does not check out left at its default rather than passed on.
export function configOf(raw) {
  const c = { ...CONFIG_DEFAULTS };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return c;
  // The doors to live play: a kill switch, and whether the paid tier is
  // offered at all to a device that has not bought it.
  if (typeof raw.live === 'boolean') c.live = raw.live;
  if (typeof raw.offer === 'boolean') c.offer = raw.offer;
  // Which relays the tables meet on, in place of the build's. wss only:
  // these carry every live game, and a relay over plain ws would carry
  // them in the open. And ours only (docs/08-own-relays.md): this is the
  // way to move the tables to another relay of ours without a release,
  // never the way back to a public one.
  if (Array.isArray(raw.relays) && raw.relays.length > 0 && raw.relays.length <= MOST_RELAYS) {
    const relays = [];
    for (const r of raw.relays) {
      try {
        const u = new URL(r);
        const ours = u.hostname === 'openhearts.game' || u.hostname.endsWith('.openhearts.game');
        if (u.protocol === 'wss:' && ours && !u.username && !u.password) relays.push(u.toString().replaceAll('%7Btag%7D', '{tag}'));
      } catch {}
    }
    if (relays.length === raw.relays.length) c.relays = relays;
  }
  // A line across the front door: a maintenance window, an outage.
  if (raw.banner && typeof raw.banner === 'object') {
    const text = sayingOf(raw.banner.text);
    const id = typeof raw.banner.id === 'string' && /^[\w.-]{1,64}$/.test(raw.banner.id) ? raw.banner.id : null;
    if (text && id) c.banner = { id, level: raw.banner.level === 'warn' ? 'warn' : 'info', text };
  }
  // Please update: a build published before this day is asked to.
  if (raw.update && typeof raw.update === 'object' && typeof raw.update.before === 'string' && DAY.test(raw.update.before)) {
    c.update = { before: raw.update.before, text: sayingOf(raw.update.text) };
  }
  // Where a player's "tell us what's broken" goes: a page, or mail.
  if (typeof raw.feedback === 'string') {
    try {
      const u = new URL(raw.feedback);
      const page = u.protocol === 'https:' && !u.username && !u.password;
      const mail = u.protocol === 'mailto:' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(u.pathname);
      if (page || mail) c.feedback = u.toString();
    } catch {}
  }
  // What a year costs, as the web shows it beside Subscribe: changed
  // with the Stripe price (`config|service`, stripePrice) it describes.
  if (typeof raw.price === 'string' && /^[^\s<>{}]{1,12}$/.test(raw.price) && /\d/.test(raw.price)) c.price = raw.price;
  // Where the privacy policy and the terms are, when not on this site.
  for (const name of ['privacy', 'terms']) {
    if (typeof raw[name] !== 'string') continue;
    try {
      const u = new URL(raw[name]);
      if (u.protocol === 'https:' && !u.username && !u.password) c[name] = u.toString();
    } catch {}
  }
  // The clocks of the tables a device starts: served only where the
  // whole of it checks out, and left out otherwise, which the app
  // reads as the standard table.
  const table = tableTimingOf(raw.table);
  if (table) c.table = table;
  return c;
}

/// What each of a table's clocks may be, in milliseconds, least and
/// most: the same bounds the table package parses a start event by
/// (packages/table/lib/src/timing.dart, TableTiming.bounds).
export const TABLE_TIMING_BOUNDS = Object.freeze({
  graceMs: [2000, 60000],
  passGraceMs: [2000, 120000],
  bankMs: [10000, 300000],
  fixedMs: [15000, 120000],
  botActsMs: [5000, 60000],
  botDealsMs: [15000, 120000],
  quorumLostMs: [10000, 120000],
  silenceMs: [30000, 600000],
  jurorSilenceMs: [10000, 120000],
});

/// A table's timing as the operator wrote it, or null: all or nothing,
/// as a seat reads it — one field of the wrong type or out of bounds,
/// and none of it is served. Names it does not know are dropped.
function tableTimingOf(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = {};
  for (const [name, [least, most]] of Object.entries(TABLE_TIMING_BOUNDS)) {
    if (!(name in raw)) continue;
    const v = raw[name];
    if (!Number.isInteger(v) || v < least || v > most) return null;
    out[name] = v;
  }
  return Object.keys(out).length ? out : null;
}

// ---- is it up ----------------------------------------------------------
// What an outside monitor asks every minute (docs/06-service.md,
// "Watching it run"): not whether this worker answers — any page would
// say that — but whether what a purchase needs does. The store is read,
// and Stripe is asked for the price with the key the service holds,
// which is the call that failed for an hour on 2 October, with the key
// expired and the worker answering everything else. The answer is kept
// for half a minute in this isolate, so asking in a loop does not put
// the asker's load on Stripe.

const HEALTH_KEPT_MS = 30 * 1000;
let health = null;

/// For a test: look again.
export const forgetHealth = () => {
  health = null;
};

/// {ok, store, stripe}: each check `ok`, or what went wrong in a few
/// words, without anything secret.
export async function healthOf(env, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (health && health.until > now) return health.said;
  const said = { ok: false, store: 'ok', stripe: 'ok' };
  try {
    const store = storeOf(env);
    if (!store) said.store = 'not bound';
    else await store.get(...CONFIG_ROW);
  } catch (e) {
    said.store = 'unreadable';
  }
  const secret = env.OH_STRIPE_SECRET;
  const named = S().stripePrice ?? env.OH_STRIPE_PRICE;
  if (!secret || typeof named !== 'string') {
    said.stripe = 'not configured';
  } else {
    try {
      const res = await fetchImpl(`${STRIPE}/prices?${new URLSearchParams({ 'lookup_keys[]': named, active: 'true', limit: '1' })}`, {
        headers: { authorization: `Bearer ${secret}` },
      });
      if (!res.ok) said.stripe = `stripe said ${res.status}`;
      else if (!(await res.json())?.data?.length) said.stripe = 'no such price';
    } catch {
      said.stripe = 'not answering';
    }
  }
  said.ok = said.store === 'ok' && said.stripe === 'ok';
  health = { said, until: now + HEALTH_KEPT_MS };
  return said;
}

async function healthRoute(request, env) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return json(request, 405, { error: 'GET' }, { allow: 'GET' });
  const said = await healthOf(env);
  return json(request, said.ok ? 200 : 503, said, { 'cache-control': 'no-store' });
}

async function configRoute(request, env) {
  const pre = preflight(request, 'GET');
  if (pre) return pre;
  if (request.method !== 'GET') return json(request, 405, { error: 'GET' }, { allow: 'GET, OPTIONS' });
  let raw = null;
  try {
    raw = (await storeOf(env)?.get(...CONFIG_ROW)) ?? null;
  } catch {
    // Unreadable is the same as absent: the defaults.
  }
  // A minute in the browser's cache: a kill switch thrown reaches every
  // device opening the app within one.
  return json(request, 200, configOf(raw), { 'cache-control': 'public, max-age=60' });
}

// ---- Watching it run -------------------------------------------------

/// The handlers by name, as /api/<name> asks for them.
// ---- buying in a store -------------------------------------------------
// On a phone, live play is the store's own subscription (doc 06, "Where
// the money comes in"). The device buys, the store hands it a proof,
// and the device brings the proof here, signed as every request is:
//
//   App Store    a StoreKit 2 signed transaction: a JWS whose
//                certificate chain ends at Apple's own root, pinned
//                below. Checked here, offline; nothing is asked of Apple.
//   Google Play  a purchase token, which proves nothing by itself: the
//                Play Developer API is asked what it is, with the
//                project's service account, and the purchase is
//                acknowledged — Play refunds one that is not, in three
//                days.
//
// A subscription bought in a store is `apple:<original transaction>` or
// `google:<hash of the purchase token>`, with its devices, its date and
// its household like any other. Renewals, lapses and refunds arrive the
// way Stripe's do, pushed: App Store Server Notifications V2 at
// /api/apple, Play's Real-time Developer Notifications at /api/play.
//
// The store's own record names the device a purchase was made for: the
// app sets Apple's appAccountToken, and Play's obfuscated account id,
// from its key (storeAccountOf). The device that paid may move onto
// what it paid for from wherever it was. Any other device bringing the
// same proof — the same Apple or Google account restoring it on a new
// phone — joins as a code would let it, within the household's count
// and not off another paid-up subscription.

/// What the store's record holds for the device with [key]: Play's
/// obfuscated account id (64 hex) and Apple's appAccountToken (a UUID
/// cut from the same hash). The app makes the same two
/// (app/lib/net/store_buying.dart); a test pins both.
export async function storeAccountOf(key) {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`oh-store/1\n${key}`)));
  const hex = [...h].map((b) => b.toString(16).padStart(2, '0')).join('');
  const u = h.slice(0, 16);
  u[6] = (u[6] & 0x0f) | 0x40;
  u[8] = (u[8] & 0x3f) | 0x80;
  const x = [...u].map((b) => b.toString(16).padStart(2, '0')).join('');
  return { google: hex, apple: `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}` };
}

// ---- certificates, as little of X.509 as a store's chain needs ----------

/// One DER element at [at]: its tag, where its content starts and ends.
function derAt(b, at) {
  if (at + 2 > b.length) throw new Error('short');
  const tag = b[at];
  let len = b[at + 1];
  let body = at + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4) throw new Error('length');
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[body++];
  }
  const end = body + len;
  if (end > b.length) throw new Error('overrun');
  return { tag, start: at, body, end };
}

function derKids(b, node) {
  const out = [];
  for (let at = node.body; at < node.end; ) {
    const kid = derAt(b, at);
    out.push(kid);
    at = kid.end;
  }
  return out;
}

function oidOf(b, node) {
  if (node.tag !== 0x06) throw new Error('not an oid');
  const parts = [Math.floor(b[node.body] / 40), b[node.body] % 40];
  let v = 0;
  for (let i = node.body + 1; i < node.end; i++) {
    v = v * 128 + (b[i] & 0x7f);
    if (!(b[i] & 0x80)) {
      parts.push(v);
      v = 0;
    }
  }
  return parts.join('.');
}

function timeOf(b, node) {
  const t = new TextDecoder().decode(b.subarray(node.body, node.end));
  const m = node.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(t) : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(t);
  if (!m) throw new Error('time');
  let y = Number(m[1]);
  if (node.tag === 0x17) y += y < 50 ? 2000 : 1900;
  return Date.UTC(y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
}

const CURVES = { '1.2.840.10045.3.1.7': { namedCurve: 'P-256', size: 32 }, '1.3.132.0.34': { namedCurve: 'P-384', size: 48 } };
const ECDSA_WITH = { '1.2.840.10045.4.3.2': 'SHA-256', '1.2.840.10045.4.3.3': 'SHA-384' };

/// A certificate, read for what a chain check needs; throws on anything
/// it cannot read, which is a certificate that is not taken.
export function certOf(der) {
  const b = der instanceof Uint8Array ? der : new Uint8Array(der);
  const cert = derAt(b, 0);
  if (cert.end !== b.length) throw new Error('trailing');
  const [tbs, sigAlg, sigVal] = derKids(b, cert);
  const t = derKids(b, tbs);
  let i = t[0].tag === 0xa0 ? 1 : 0;
  i++; // serial
  i++; // the signature algorithm again
  const issuer = t[i++];
  const validity = derKids(b, t[i++]);
  const subject = t[i++];
  const spki = t[i++];
  const [keyAlg] = derKids(b, spki);
  const [, curveOid] = derKids(b, keyAlg);
  const extensions = new Map();
  const ext = t.find((n) => n.tag === 0xa3);
  if (ext) {
    for (const e of derKids(b, derKids(b, ext)[0])) {
      const parts = derKids(b, e);
      extensions.set(oidOf(b, parts[0]), b.subarray(parts.at(-1).body, parts.at(-1).end));
    }
  }
  // basicConstraints: SEQUENCE { cA BOOLEAN DEFAULT FALSE, ... }
  let ca = false;
  const bc = extensions.get('2.5.29.19');
  if (bc && bc.length > 2) {
    const seq = derAt(bc, 0);
    const first = derKids(bc, seq)[0];
    ca = !!first && first.tag === 0x01 && bc[first.body] !== 0;
  }
  return {
    tbs: b.subarray(tbs.start, tbs.end),
    sigHash: ECDSA_WITH[oidOf(b, derKids(b, sigAlg)[0])] ?? null,
    signature: b.subarray(sigVal.body + 1, sigVal.end),
    spki: b.subarray(spki.start, spki.end),
    curve: CURVES[oidOf(b, curveOid)] ?? null,
    issuer: b.subarray(issuer.start, issuer.end),
    subject: b.subarray(subject.start, subject.end),
    notBefore: timeOf(b, validity[0]),
    notAfter: timeOf(b, validity[1]),
    extensions,
    ca,
  };
}

/// An ECDSA signature as DER (SEQUENCE of r and s) to the r‖s WebCrypto
/// verifies, each padded to the curve's [size].
function rawSignature(der, size) {
  const seq = derAt(der, 0);
  const out = new Uint8Array(size * 2);
  derKids(der, seq).forEach((n, k) => {
    let v = der.subarray(n.body, n.end);
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new Error('integer');
    out.set(v, k * size + size - v.length);
  });
  return out;
}

const sameBytes = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

/// Whether [child] was signed by [parent]'s key, and names it as issuer.
export async function signedBy(child, parent) {
  if (!child.sigHash || !parent.curve || !sameBytes(child.issuer, parent.subject)) return false;
  try {
    const key = await crypto.subtle.importKey('spki', parent.spki, { name: 'ECDSA', namedCurve: parent.curve.namedCurve }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: child.sigHash }, key, rawSignature(child.signature, parent.curve.size), child.tbs);
  } catch {
    return false;
  }
}

/// Apple Root CA - G3, as Apple publishes it
/// (apple.com/certificateauthority/AppleRootCA-G3.cer; SHA-256
/// 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79).
export const APPLE_ROOT_G3 = Uint8Array.from(atob('MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA=='), (c) => c.charCodeAt(0));

/// The roots an App Store chain may end at: Apple's, unless a test says
/// otherwise — no test can make a certificate Apple signed.
let appleRoots = [APPLE_ROOT_G3];
export const trustAppleRoots = (roots) => (appleRoots = roots);
export const forgetAppleRoots = () => (appleRoots = [APPLE_ROOT_G3]);

/// Apple marks the certificates it signs the App Store's data with:
/// the WWDR intermediate, and the leaf that signs.
const APPLE_INTERMEDIATE = '1.2.840.113635.100.6.2.1';
const APPLE_STORE_LEAF = '1.2.840.113635.100.6.11.1';

/// What an App Store JWS says, once its chain ends at one of [roots] and
/// its signature is the leaf's; null when it does not check out. The
/// certificates are checked at the moment the payload says it was
/// signed, which is how Apple's own library checks them: what Apple
/// signed while a certificate was good stays signed after it expires.
export async function appleSigned(jws, { roots = appleRoots, now = Date.now() } = {}) {
  try {
    const parts = String(jws ?? '').split('.');
    if (parts.length !== 3) return null;
    const header = JSON.parse(new TextDecoder().decode(un64(parts[0])));
    if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) return null;
    const ders = header.x5c.map((c) => Uint8Array.from(atob(c), (ch) => ch.charCodeAt(0)));
    if (!roots.some((r) => sameBytes(r, ders[2]))) return null;
    const [leaf, middle, root] = ders.map(certOf);
    const payload = JSON.parse(new TextDecoder().decode(un64(parts[1])));
    const at = Number.isFinite(payload.signedDate) ? payload.signedDate : now;
    // Not signed in the future, whatever the payload claims.
    if (at > now + 5 * 60000) return null;
    for (const c of [leaf, middle, root]) if (at < c.notBefore || at > c.notAfter) return null;
    if (!middle.ca || !middle.extensions.has(APPLE_INTERMEDIATE) || !leaf.extensions.has(APPLE_STORE_LEAF)) return null;
    if (!(await signedBy(middle, root)) || !(await signedBy(leaf, middle))) return null;
    if (leaf.curve?.namedCurve !== 'P-256') return null;
    const key = await crypto.subtle.importKey('spki', leaf.spki, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, un64(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    return ok ? payload : null;
  } catch {
    return null;
  }
}

/// A checked App Store transaction, as this service reads it: the
/// subscription, when it runs to, whether it has ended, and whom it
/// was bought for. {status, body} when it is not one of ours.
export async function appleTransaction(jws, env, { roots, now = Date.now() } = {}) {
  const bundle = env.OH_APPLE_BUNDLE_ID;
  const product = env.OH_APPLE_PRODUCT;
  if (!bundle || !product) return { status: 503, body: { error: 'the store is not set up yet' } };
  const t = await appleSigned(jws, { roots, now });
  if (!t) return { status: 401, body: { error: 'not from the store' } };
  // Another app's, another product's, or not a subscription at all.
  if (t.bundleId !== bundle || t.productId !== product || t.type !== 'Auto-Renewable Subscription') {
    return { status: 401, body: { error: 'not from the store' } };
  }
  if (typeof t.originalTransactionId !== 'string' || !/^\d{1,32}$/.test(t.originalTransactionId) || !Number.isFinite(t.expiresDate)) {
    return { status: 401, body: { error: 'not from the store' } };
  }
  return {
    subscription: `apple:${t.originalTransactionId}`,
    until: t.expiresDate,
    gone: t.revocationDate != null,
    account: typeof t.appAccountToken === 'string' ? t.appAccountToken.toLowerCase() : null,
    created: Number.isFinite(t.signedDate) ? Math.floor(t.signedDate / 1000) : null,
    txn_ref: typeof t.transactionId === 'string' ? t.transactionId : null,
  };
}

// ---- Google Play ---------------------------------------------------------

const PLAY = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
const GOOGLE_TOKEN = 'https://oauth2.googleapis.com/token';

let playAccess = null;

/// Forgets the cached Play access token, for a test.
export const forgetPlayAccess = () => (playAccess = null);

const pemBytes = (pem) => Uint8Array.from(atob(String(pem).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')), (c) => c.charCodeAt(0));
const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlText = (text) => b64url(new TextEncoder().encode(text));

/// An access token for the Play Developer API, from the service
/// account in OH_PLAY_SERVICE_ACCOUNT (its JSON key), kept until a
/// minute before it runs out.
export async function playToken(env, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (playAccess && playAccess.until > now) return playAccess.token;
  const account = JSON.parse(env.OH_PLAY_SERVICE_ACCOUNT);
  const iat = Math.floor(now / 1000);
  const head = b64urlText(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64urlText(
    JSON.stringify({ iss: account.client_email, scope: 'https://www.googleapis.com/auth/androidpublisher', aud: GOOGLE_TOKEN, iat, exp: iat + 3600 }),
  );
  const key = await crypto.subtle.importKey('pkcs8', pemBytes(account.private_key), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${claims}`)));
  const res = await fetchImpl(GOOGLE_TOKEN, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claims}.${b64url(sig)}` }).toString(),
  });
  if (!res.ok) throw new Error(`google token ${res.status}`);
  const { access_token: token, expires_in: lasts } = await res.json();
  if (typeof token !== 'string') throw new Error('google token');
  playAccess = { token, until: now + Math.max(0, (Number(lasts) || 3600) - 60) * 1000 };
  return token;
}

/// Subscription ids for Play: the purchase token, hashed, since the
/// token itself is a bearer's and is kept by no row.
const playSubscriptionOf = async (token) => `google:${await digestOf(`oh-play/1\n${token}`)}`;

/// The states a Play subscription is paid up in. CANCELED is paid up
/// too, to the end of what was paid for: cancelling stops the renewal.
const PLAY_PAID = new Set(['SUBSCRIPTION_STATE_ACTIVE', 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD', 'SUBSCRIPTION_STATE_CANCELED']);

/// What Play says of the purchase [token], as this service reads it —
/// and acknowledged, if it was not yet. {status, body} when it is not
/// one of ours or Play cannot be asked.
export async function playPurchase(token, env, fetchImpl = fetch, { now = Date.now(), store = null } = {}) {
  const pkg = env.OH_PLAY_PACKAGE;
  const product = env.OH_PLAY_PRODUCT;
  if (!pkg || !product || !env.OH_PLAY_SERVICE_ACCOUNT) return { status: 503, body: { error: 'the store is not set up yet' } };
  if (typeof token !== 'string' || !/^[A-Za-z0-9._:-]{10,1024}$/.test(token)) return { status: 401, body: { error: 'not from the store' } };
  let access;
  let res;
  try {
    access = await playToken(env, fetchImpl, { now });
    res = await fetchImpl(`${PLAY}/${encodeURIComponent(pkg)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(token)}`, {
      headers: { authorization: `Bearer ${access}` },
    });
  } catch {
    return { status: 502, body: { error: 'the store is not answering' } };
  }
  // A token Play has never heard of, or not this app's.
  if (res.status === 400 || res.status === 404 || res.status === 410) return { status: 401, body: { error: 'not from the store' } };
  if (!res.ok) return { status: 502, body: { error: 'the store is not answering' } };
  let p;
  try {
    p = await res.json();
  } catch {
    return { status: 502, body: { error: 'the store is not answering' } };
  }
  const line = Array.isArray(p.lineItems) ? p.lineItems.find((l) => l?.productId === product) : null;
  if (!line) return { status: 401, body: { error: 'not from the store' } };
  const until = Date.parse(line.expiryTime);
  // Play refunds a purchase nobody acknowledged within three days; this
  // is where it is taken, so this is where it is acknowledged.
  if (p.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING' && PLAY_PAID.has(p.subscriptionState)) {
    try {
      await fetchImpl(`${PLAY}/${encodeURIComponent(pkg)}/purchases/subscriptions/${encodeURIComponent(product)}/tokens/${encodeURIComponent(token)}:acknowledge`, {
        method: 'POST',
        headers: { authorization: `Bearer ${access}`, 'content-type': 'application/json' },
        body: '{}',
      });
    } catch {
      // Asked again on the next notification or the next device to bring it.
    }
  }
  // A token that replaced another — a resubscription, a plan change — is
  // the same subscription as the one it replaced, if that one is known.
  let subscription = await playSubscriptionOf(token);
  if (typeof p.linkedPurchaseToken === 'string' && store) {
    const before = await playSubscriptionOf(p.linkedPurchaseToken);
    if (await store.get(`SUB#${before}`, 'META')) subscription = before;
  }
  return {
    subscription,
    until: Number.isFinite(until) ? until : null,
    paid: PLAY_PAID.has(p.subscriptionState),
    gone: p.subscriptionState === 'SUBSCRIPTION_STATE_EXPIRED',
    account: p.externalAccountIdentifiers?.obfuscatedExternalAccountId ?? null,
    txn_ref: typeof p.latestOrderId === 'string' ? p.latestOrderId : null,
  };
}

/// Whether [token] is Pub/Sub's push of Play's notifications: a Google
/// ID token for the push subscription's own service account
/// (OH_PLAY_PUSH_EMAIL), made out to this endpoint (OH_PLAY_PUSH_AUDIENCE).
export async function pushedByPlay(token, env, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (!env.OH_PLAY_PUSH_AUDIENCE || !env.OH_PLAY_PUSH_EMAIL) return false;
  const claims = await jwtOf('google', token, fetchImpl, { now });
  if (!claims) return false;
  if (claims.iss !== 'https://accounts.google.com' && claims.iss !== 'accounts.google.com') return false;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(env.OH_PLAY_PUSH_AUDIENCE)) return false;
  if (typeof claims.exp !== 'number' || claims.exp * 1000 <= now) return false;
  return claims.email === env.OH_PLAY_PUSH_EMAIL && claims.email_verified === true;
}

/// A checked purchase written down and [op.key] put on it, in its
/// household's turn: dated first, whatever it says, and joined only if
/// it is paid up. {status, body}.
export async function bindPurchase(op, store, { now = Date.now() } = {}) {
  await dateSubscription(store, op.subscription, {
    source: op.source,
    txn_ref: op.txn_ref ?? null,
    until: op.until,
    gone: op.gone,
    created: op.created ?? null,
    now,
  });
  if (op.gone || !op.paid || !(op.until > now)) return { status: 402, body: { error: 'not paid' } };
  return joinSubscription(op.key, op.subscription, store, { now, moving: op.buyer === true });
}

async function storeRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // The proof is what is signed: a device brings its own purchase, and
  // nobody brings one for it.
  const asked = await signedFor(request, env, 'store', (body) => (typeof body.proof === 'string' ? body.proof : ''));
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  if (body.store !== 'apple' && body.store !== 'google') return json(request, 400, { error: 'not a store' });
  if (typeof body.proof !== 'string' || !body.proof) return json(request, 400, { error: 'no proof' });
  const now = Date.now();
  const mine = await storeAccountOf(key);
  let bought;
  if (body.store === 'apple') {
    const t = await appleTransaction(body.proof, env, { now });
    if (t.status) return json(request, t.status, t.body);
    bought = { source: 'apple', ...t, paid: !t.gone && t.until > now, buyer: t.account === mine.apple };
  } else {
    const p = await playPurchase(body.proof, env, fetch, { now, store });
    if (p.status) return json(request, p.status, p.body);
    bought = { source: 'google', ...p, created: null, buyer: p.account === mine.google };
  }
  const { account: _, ...op } = bought;
  const bound = await inHousehold(env, bought.subscription, { op: 'bind', key, ...op });
  if (bound.status !== 200) return json(request, bound.status, bound.body);
  const { status, body: out } = await licence(key, env, { signer, now });
  return json(request, status, out);
}

/// Apple's notification types after which nothing is paid for.
const APPLE_ENDED = new Set(['REFUND', 'REVOKE', 'EXPIRED', 'GRACE_PERIOD_EXPIRED']);

/// App Store Server Notifications V2: what Apple says of a
/// subscription, signed by the App Store as a transaction is. Answered
/// 200 once it has been read, ours or not, so Apple does not send it
/// again; 400 when it is not Apple's.
async function appleRoute(request, env) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  // A notification carries three JWS, each with its chain: past what an
  // ordinary request is allowed, well inside a webhook's.
  const raw = await textOf(request, MOST_EVENT);
  if (raw === null) return json(request, 413, { error: 'too big' });
  if (!env.OH_APPLE_BUNDLE_ID || !env.OH_APPLE_PRODUCT) return json(request, 503, { error: 'the store is not set up yet' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  let signedPayload;
  try {
    ({ signedPayload } = JSON.parse(raw));
  } catch {
    return json(request, 400, { error: 'not signed' });
  }
  const now = Date.now();
  const n = await appleSigned(signedPayload, { now });
  if (!n) return json(request, 400, { error: 'not signed' });
  if (n.data?.bundleId !== env.OH_APPLE_BUNDLE_ID || !n.data?.signedTransactionInfo) return json(request, 200, { recorded: null });
  const t = await appleTransaction(n.data.signedTransactionInfo, env, { now });
  if (t.status) return json(request, 200, { recorded: null });
  // A renewal that failed but is in its grace period is still paid for,
  // to the end of the grace.
  const renewal = n.data.signedRenewalInfo ? await appleSigned(n.data.signedRenewalInfo, { now }) : null;
  const grace = renewal?.gracePeriodExpiresDate;
  const until = Number.isFinite(grace) && grace > t.until ? grace : t.until;
  // Never final: a subscription that lapsed or was refunded keeps its
  // original transaction when it is bought again, and comes back.
  const recorded = await dateSubscription(store, t.subscription, {
    source: 'apple',
    txn_ref: t.txn_ref,
    until,
    gone: t.gone || APPLE_ENDED.has(n.notificationType),
    created: Number.isFinite(n.signedDate) ? Math.floor(n.signedDate / 1000) : t.created,
    now,
  });
  return json(request, 200, { recorded });
}

/// Google Play's Real-time Developer Notifications, pushed by Pub/Sub.
/// The notification names a purchase and says little else, so Play is
/// asked what the purchase is now. Answered 200 once handled, ours or
/// not; 502 when Play could not be asked, so Pub/Sub tries again.
async function playRoute(request, env) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  const bearer = /^Bearer (.+)$/.exec(request.headers.get('authorization') ?? '')?.[1];
  if (!(await pushedByPlay(bearer, env))) return json(request, 401, { error: 'not Play' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  let note;
  try {
    const pushed = JSON.parse((await textOf(request, MOST_BODY)) ?? '');
    note = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(pushed.message.data), (c) => c.charCodeAt(0))));
  } catch {
    return json(request, 400, { error: 'not a notification' });
  }
  if (note?.packageName !== env.OH_PLAY_PACKAGE) return json(request, 200, { recorded: null });
  const now = Date.now();
  const created = Number.isFinite(Number(note.eventTimeMillis)) ? Math.floor(Number(note.eventTimeMillis) / 1000) : null;
  // Voided: refunded or charged back. Nothing more to ask.
  const voided = note.voidedPurchaseNotification?.purchaseToken;
  if (typeof voided === 'string') {
    const recorded = await dateSubscription(store, await playSubscriptionOf(voided), { source: 'google', until: null, gone: true, created, now });
    return json(request, 200, { recorded });
  }
  const token = note.subscriptionNotification?.purchaseToken;
  if (typeof token !== 'string') return json(request, 200, { recorded: null });
  const p = await playPurchase(token, env, fetch, { now, store });
  if (p.status === 502) return json(request, 502, p.body);
  if (p.status) return json(request, 200, { recorded: null });
  const recorded = await dateSubscription(store, p.subscription, {
    source: 'google',
    txn_ref: p.txn_ref,
    until: p.until,
    // On hold or paused is not paid for now; it comes back with the
    // notification that says it recovered.
    gone: p.gone || !p.paid,
    created,
    now,
  });
  return json(request, 200, { recorded });
}

const ROUTES = {
  config: (request, env) => configRoute(request, env),
  health: (request, env) => healthRoute(request, env),
  turn: (request, env) => turn(request, env),
  licence: (request, env) => licenceRoute(request, env),
  checkout: (request, env) => checkoutRoute(request, env),
  stripe: (request, env) => stripeRoute(request, env),
  manage: (request, env) => manageRoute(request, env),
  store: (request, env) => storeRoute(request, env),
  apple: (request, env) => appleRoute(request, env),
  play: (request, env) => playRoute(request, env),
  ticket: (request, env) => ticketRoute(request, env),
  claim: (request, env) => claimRoute(request, env),
  backups: (request, env) => backupsRoute(request, env),
  devices: (request, env) => devicesRoute(request, env),
  attest: (request, env) => signInRoute(request, env, false),
  supersede: (request, env) => signInRoute(request, env, true),
  record: (request, env) => recordRoute(request, env),
};

/// A request out of how many is written down, by handler: one in ten
/// for the config, which every open app asks for each quarter of an
/// hour; every one of the rest, which are a person doing something.
const SAMPLED = { config: 10, health: 10 };

/// One line of numbers a request, for the operator (doc 06, "Watching
/// it run"): which handler, what it answered and how long it took — and
/// how many requests the line stands for, when only some are written.
/// Never a key, an address or anything else about who asked. Written to
/// the OH_METRICS dataset when the project binds one, and nowhere when
/// it does not.
export function measure(env, handler, status, ms, { random = Math.random } = {}) {
  const sink = env.OH_METRICS;
  if (!sink) return;
  const weight = SAMPLED[handler] ?? 1;
  if (weight > 1 && random() >= 1 / weight) return;
  try {
    sink.writeDataPoint({ indexes: [handler], blobs: [handler, String(status)], doubles: [ms, weight] });
  } catch {
    // What is watched never stops what is watched.
  }
}

/// Whether [url] is a page of the app rather than one of its files: an
/// address under /play/ with no extension, `/play/subscription` or
/// `/play/room/ABCD` (app/lib/router.dart). Each is answered with the
/// app, which reads the address and opens the page. Decided by the path,
/// not by a file being missing: the site has no 404 page, so a missing
/// file comes back as the site's front page rather than as missing.
export function appPage(url) {
  const path = url.pathname;
  if (!path.startsWith('/play/') || path === '/play/') return false;
  const last = path.slice(path.lastIndexOf('/') + 1);
  return !last.includes('.');
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const name = url.pathname.startsWith('/api/') ? url.pathname.slice('/api/'.length) : null;
    if (name === null) return env.ASSETS.fetch(appPage(url) ? new Request(new URL('/play/', url), request) : request);
    // A finished game's record, by its table's id (records.mjs).
    if (name.startsWith('record/') && request.method === 'GET') return recordResponse(env.OH_RECORDS, name.slice('record/'.length), cors(request));
    const route = Object.hasOwn(ROUTES, name) ? ROUTES[name] : null;
    const started = Date.now();
    if (route) await settle(env);
    const response = route ? await route(request, env) : json(request, 404, { error: 'no such handler' });
    measure(env, route ? name : 'unknown', response.status, Date.now() - started);
    return response;
  },
};
