// The service's handlers as one Cloudflare Pages worker
// (docs/06-service.md): what runs on our side beside the static site
// and the app. deploy.sh copies this file to _worker.js at the root of
// the published directory, where Pages runs it for every request;
// whatever is not a handler is handed to the static assets.
//
// turn-creds: POST /api/turn with {"key": <the caller's table key>}
// answers {"iceServers": [...], "ttl": seconds} — Cloudflare Realtime
// TURN credentials good for a few hours, minted from a TURN key that
// lives in the project's secrets (OH_TURN_KEY_ID, OH_TURN_API_TOKEN) and
// never here. Without them the handler says so (503) and the app falls
// back to STUN alone. The key is taken as given: attesting it is the
// sign-in handler's job, which is not built yet.
//
// licence: POST /api/licence with the same key answers {"licence":
// {key, until, plan, sig}} — a month, signed by the service key
// (OH_SERVICE_SECRET, with OH_SERVICE_KEY beside it as the public half
// the app has baked in), or 402 when no subscription stands behind the
// key. What is read is one row, and the second only around a renewal.
//
// No imports, so nothing is bundled: the file is the worker. The curve
// is the one the whole project signs on, so the signing is the app's
// own wasm, fetched from the static assets this worker serves.

const DEFAULT_TTL = 4 * 60 * 60;
const UPSTREAM = 'https://rtc.live.cloudflare.com/v1/turn/keys';

/// The origin a browser may call the handlers from, echoed back, or
/// null: the site's own hosts, and a dev machine.
export function allowedOrigin(origin) {
  if (!origin) return null;
  let host;
  try {
    host = new URL(origin).hostname;
  } catch {
    return null;
  }
  if (host === 'localhost' || host === '127.0.0.1') return origin;
  if (host === 'open-hearts.pages.dev' || host.endsWith('.open-hearts.pages.dev')) return origin;
  return null;
}

function cors(request, headers = {}) {
  const origin = allowedOrigin(request.headers.get('origin'));
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
  const ttl = DEFAULT_TTL;
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
const LICENCE_DAYS = 31;
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
    async put(pk, sk, value) {
      await kv.put(at(pk, sk), JSON.stringify(value));
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
  const { memory, alloc, reset, sign, verify } = (await WebAssembly.instantiate(bytes, {})).instance.exports;
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
function signerFor(request, env) {
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
    const renews_at = dayAfter(now, LICENCE_DAYS);
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
export async function licence(key, env, { signer, now = Date.now() } = {}) {
  const secret = env.OH_SERVICE_SECRET;
  const service = env.OH_SERVICE_KEY;
  if (!/^[0-9a-f]{64}$/.test(secret ?? '') || !/^[0-9a-f]{64}$/.test(service ?? '')) {
    return { status: 503, body: { error: 'licensing not configured' } };
  }
  const store = storeOf(env);
  if (!store) return { status: 503, body: { error: 'licensing not configured' } };
  const held = await entitlementOf(store, key, { now, openHouse: !!env.OH_OPEN_HOUSE });
  if (!held) return { status: 402, body: { error: 'no subscription' } };
  const until = earlier(dayAfter(now, LICENCE_DAYS), held.licensed_until);
  const signed = await licenceFor(key, until, { signer, secret, service });
  if (!signed) return { status: 503, body: { error: 'the service key does not match its secret' } };
  return { status: 200, body: { licence: signed } };
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

/// How far out of date a webhook's own timestamp may be. Stripe signs
/// the moment it sends; a replay from last week is not a payment.
const WEBHOOK_TOLERANCE_S = 300;

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

/// A checkout session for [key], as Stripe answers: {status, body}.
export async function checkout(key, back, cancelled, env, fetchImpl = fetch) {
  const secret = env.OH_STRIPE_SECRET;
  const price = env.OH_STRIPE_PRICE;
  if (!secret || !price) return { status: 503, body: { error: 'the shop is not open yet' } };
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
  if (Math.abs(now / 1000 - t) > WEBHOOK_TOLERANCE_S) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const mac = hex(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`))));
  // Every v1 offered, since a secret being rotated signs with two.
  return v1.some((offered) => offered.length === mac.length && offered === mac);
}

/// What a Stripe event means here, written down. Returns what was
/// recorded, or null when the event is not one of ours — a webhook
/// carries everything the account does, and most of it is not this.
export async function record(event, store, { now = Date.now() } = {}) {
  const object = event?.data?.object ?? {};
  const today = dayOf(now);
  if (event?.type === 'checkout.session.completed') {
    if (object.payment_status !== 'paid' && object.status !== 'complete') return null;
    const key = object.metadata?.key ?? object.client_reference_id;
    const subscription = typeof object.subscription === 'string' ? object.subscription : object.subscription?.id;
    if (!/^[0-9a-f]{64}$/.test(key ?? '') || !subscription) return null;
    // The date is the subscription's to say, and its own event may not
    // have arrived yet: bound now, dated on the first ask after it has.
    const known = await store.get(`SUB#${subscription}`, 'META');
    await store.put(`SUB#${subscription}`, `DEVICE#${key}`, { bound_at: today });
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
    const period = object.current_period_end ?? object.items?.data?.[0]?.current_period_end;
    // Ended: Stripe deleted it, or dunning gave up, or it was refunded
    // out. A subscription that is merely *cancelling* is not this — it
    // runs to the end of what was paid for, which is what renews_at
    // already says.
    const gone = event.type.endsWith('.deleted') || ENDED.has(object.status);
    const renews_at = gone ? today : period ? dayOf(period * 1000) : null;
    await store.put(`SUB#${subscription}`, 'META', {
      source: 'stripe',
      txn_ref: object.latest_invoice ?? null,
      renews_at,
      cancelled_at: object.canceled_at ? dayOf(object.canceled_at * 1000) : gone ? today : null,
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
  return null;
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

const MOST_DEVICES = 5;

/// How long a code is worth anything. Long enough to walk a phone over,
/// short enough that a photograph of the screen is not a key.
const TICKET_MINUTES = 10;

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

/// A code for a new device to arrive with: {status, body}.
export async function ticketFor(key, store, { now = Date.now() } = {}) {
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return { status: 402, body: { error: 'no subscription' } };
  const devices = await devicesOn(store, held.subscription);
  if (devices.length >= MOST_DEVICES) {
    return { status: 409, body: { error: 'five devices already', devices: devices.length, most: MOST_DEVICES } };
  }
  const code = nonce();
  const expires_at = new Date(now + TICKET_MINUTES * 60000).toISOString();
  await store.put(`TICKET#${code}`, 'META', { subscription: held.subscription, expires_at, used_at: null, made_by: key });
  return { status: 200, body: { ticket: code, expires_at, devices: devices.length, most: MOST_DEVICES } };
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
  const devices = await devicesOn(store, ticket.subscription);
  const already = devices.some((d) => d.key === key);
  if (!already && devices.length >= MOST_DEVICES) {
    return { status: 409, body: { error: 'five devices already', devices: devices.length, most: MOST_DEVICES } };
  }
  const today = dayOf(now);
  await store.put(`TICKET#${code}`, 'META', { ...ticket, used_at: today, used_by: key });
  // A device that was on another subscription leaves it rather than
  // counting against both.
  const was = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (was && was.subscription !== ticket.subscription) await store.del(`SUB#${was.subscription}`, `DEVICE#${key}`);
  const sub = await store.get(`SUB#${ticket.subscription}`, 'META');
  if (!already) await store.put(`SUB#${ticket.subscription}`, `DEVICE#${key}`, { bound_at: today });
  await store.put(`KEY#${key}`, 'ENTITLEMENT', {
    subscription: ticket.subscription,
    licensed_until: sub?.renews_at ?? null,
    at: today,
  });
  return { status: 200, body: { subscription: ticket.subscription } };
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
  return { status: 200, body: { devices: (await devicesOn(store, held.subscription)).length, most: MOST_DEVICES } };
}

async function ticketRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const body = await bodyOf(request);
  const key = keyOf(body);
  if (!key) return json(request, 400, { error: 'a table key, 64 hex' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const { status, body: out } = await ticketFor(key, store);
  return json(request, status, out);
}

async function claimRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const body = await bodyOf(request);
  const key = keyOf(body);
  if (!key) return json(request, 400, { error: 'a table key, 64 hex' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const claimed = await claimWith(key, body?.ticket, store);
  if (claimed.status !== 200) return json(request, claimed.status, claimed.body);
  // Straight back with the licence it was claimed for, so the device
  // that scanned a code is playing rather than waiting to be told.
  let signer;
  try {
    signer = await signerFor(request, env);
  } catch {
    return json(request, 503, { error: 'licensing not configured' });
  }
  const { status, body: out } = await licence(key, env, { signer });
  return json(request, status, out);
}

async function devicesRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const body = await bodyOf(request);
  const key = keyOf(body);
  if (!key) return json(request, 400, { error: 'a table key, 64 hex' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const drop = body?.drop;
  if (typeof drop === 'string') {
    if (!/^[0-9a-f]{64}$/.test(drop)) return json(request, 400, { error: 'a table key, 64 hex' });
    const { status, body: out } = await dropDevice(key, drop, store);
    if (status !== 200) return json(request, status, out);
  }
  const held = await store.get(`KEY#${key}`, 'ENTITLEMENT');
  if (!held) return json(request, 402, { error: 'no subscription' });
  return json(request, 200, { devices: await devicesOn(store, held.subscription), most: MOST_DEVICES });
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
export async function whoSignedIn(provider, token, key, env, fetchImpl = fetch, { now = Date.now() } = {}) {
  // Local mode's own token: a subject and nothing else, taken only
  // where the open house is (doc 06). One branch, never on in
  // production, and the rest of the path below is the same path.
  if (env.OH_OPEN_HOUSE && typeof token === 'string' && token.startsWith('local:')) {
    const sub = token.slice('local:'.length);
    return sub && PROVIDERS[provider] ? { provider, sub } : null;
  }
  const known = PROVIDERS[provider];
  const audience = known && env[known.audience];
  if (!known || !audience) return null;
  const parts = String(token ?? '').split('.');
  if (parts.length !== 3) return null;
  let header;
  let claims;
  try {
    header = JSON.parse(new TextDecoder().decode(un64(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(un64(parts[1])));
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
  const sig = un64(parts[2]);
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
  if (!ok) return null;
  if (claims.iss !== known.iss) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(audience)) return null;
  if (!(typeof claims.exp === 'number') || claims.exp * 1000 <= now) return null;
  if (typeof claims.sub !== 'string' || !claims.sub) return null;
  if (claims.nonce !== (await digestOf(`oh-signin/1\n${key}`))) return null;
  return { provider, sub: claims.sub };
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
      if (devices.length >= MOST_DEVICES) await store.del(`SUB#${theirs.subscription}`, `DEVICE#${was}`);
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
  const body = await bodyOf(request);
  const key = keyOf(body);
  if (!key) return json(request, 400, { error: 'a table key, 64 hex' });
  const store = storeOf(env);
  if (!store) return json(request, 503, { error: 'licensing not configured' });
  const who = await whoSignedIn(body?.provider, body?.token, key, env);
  if (!who) return json(request, 401, { error: 'that sign-in does not check out' });
  const { status, body: out } = await (move ? supersede : attest)(who, key, store, env);
  if (status !== 200) return json(request, status, out);
  // Straight back with the licence it is owed, if any: a device that
  // has just proved who it is should not have to ask twice.
  let signer;
  try {
    signer = await signerFor(request, env);
  } catch {
    return json(request, 200, out);
  }
  const licensed = await licence(key, env, { signer });
  return json(request, 200, { ...out, ...(licensed.status === 200 ? licensed.body : {}) });
}

async function checkoutRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const body = await bodyOf(request);
  const key = keyOf(body);
  if (!key) return json(request, 400, { error: 'a table key, 64 hex' });
  const back = sameSite(body?.back, request.url);
  const cancelled = sameSite(body?.cancelled, request.url);
  if (!back || !cancelled) return json(request, 400, { error: 'somewhere on this site to come back to' });
  const { status, body: out } = await checkout(key, back, cancelled, env);
  return json(request, status, out);
}

async function stripeRoute(request, env) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  const raw = await request.text();
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
  await record(event, store);
  // Anything not ours is still a delivery taken: a webhook that gets an
  // error back is a webhook Stripe keeps sending.
  return json(request, 200, { ok: true });
}

/// The key a handler was called with, or null.
function keyOf(body) {
  const key = body?.key;
  return typeof key === 'string' && /^[0-9a-f]{64}$/.test(key) ? key : null;
}

async function bodyOf(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
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
  const key = keyOf(await bodyOf(request));
  if (!key) return json(request, 400, { error: 'a table key, 64 hex' });
  let signer;
  try {
    signer = await signerFor(request, env);
  } catch {
    return json(request, 503, { error: 'licensing not configured' });
  }
  const { status, body } = await licence(key, env, { signer });
  return json(request, status, body);
}

async function turn(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  if (!keyOf(await bodyOf(request))) return json(request, 400, { error: 'a table key, 64 hex' });
  const { status, body: out } = await mint(env);
  return json(request, status, out);
}

// ---- Remote config ----------------------------------------------------

/// What the app may be told without a new build (doc 06, "Remote
/// config"): one row in the store, which the operator writes and every
/// device reads at its start. What is here when there is no row — or a
/// row this worker cannot read — is what the app does with no config at
/// all, so a bad row is never worse than none.
export const CONFIG_DEFAULTS = Object.freeze({ v: 1, live: true, offer: true, relays: null, banner: null, update: null, feedback: null });

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
  // them in the open.
  if (Array.isArray(raw.relays) && raw.relays.length > 0 && raw.relays.length <= MOST_RELAYS) {
    const relays = [];
    for (const r of raw.relays) {
      try {
        const u = new URL(r);
        if (u.protocol === 'wss:' && !u.username && !u.password) relays.push(u.toString());
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
  return c;
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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/api/config') return configRoute(request, env);
    if (url.pathname === '/api/turn') return turn(request, env);
    if (url.pathname === '/api/licence') return licenceRoute(request, env);
    if (url.pathname === '/api/checkout') return checkoutRoute(request, env);
    if (url.pathname === '/api/stripe') return stripeRoute(request, env);
    if (url.pathname === '/api/ticket') return ticketRoute(request, env);
    if (url.pathname === '/api/claim') return claimRoute(request, env);
    if (url.pathname === '/api/devices') return devicesRoute(request, env);
    if (url.pathname === '/api/attest') return signInRoute(request, env, false);
    if (url.pathname === '/api/supersede') return signInRoute(request, env, true);
    if (url.pathname.startsWith('/api/')) return json(request, 404, { error: 'no such handler' });
    return env.ASSETS.fetch(request);
  },
};
