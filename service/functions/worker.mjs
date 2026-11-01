// The service's handlers as one Cloudflare Pages worker
// (docs/explanation/service.md): what runs on our side beside the static site
// and the app. deploy.sh publishes this file and the modules it
// imports as _worker.js/ at the root of the published directory, where
// Pages runs it for every request (entry.mjs first); whatever is not a
// handler is handed to the static assets.
//
// Every handler a device calls is asked with the caller's table key,
// and signed by it: {"key", "at", "sig", ...} — see "who is asking" in
// http.mjs. A key is public, so a request that only names one is
// anybody's. The rest are the config and health, which anybody may
// read, and the notifications of Stripe, the stores and Sign in with
// Apple, each checked as its sender signs it.
//
// Here are the handlers and the table of them (ROUTES); what they act
// on is in the modules they import.

import { accountOfKey, backupCodeOf, backupRow, entitlementOf } from './accounts.mjs';
import { alertReport, alertSubscribed, alertUnwritten, alertWaiting, reportOf } from './alerts.mjs';
import { APP_HOST, appHostFor, serveStatic } from './app_host.mjs';
import { CONFIG_ROW, configOf } from './config.mjs';
import { healthOf } from './health.mjs';
import { holdOf } from './holds.mjs';
import { inHousehold, inSubscription } from './household.mjs';
import { MOST_BODY, MOST_EVENT, cors, json, preflight, signedFor, textOf } from './http.mjs';
import { ACTIVATION_S, accountAsking, activationFor, heldAccount, licence, serviceKeys } from './licence.mjs';
import { loginRow } from './logins.mjs';
import { measure } from './metrics.mjs';
import { carryOutNotice, noticesOf, toldVersions } from './notices.mjs';
import { MOST_PROFILE_BODY } from './profile.mjs';
import { anonymizeGames, keepRecord, keptGames, markForgotten, recordMost, recordResponse, tableIdShape } from './records.mjs';
import { REFUSED } from './refusals.mjs';
import { bytesOf64, isAccount, storeOf } from './rows.mjs';
import { isLocal, loadServiceSettings, notConfigured, openHouse, serviceSettings } from './settings.mjs';
import { APPLE_ID_GONE, PROVIDERS, appleIdNotice, supersede, unlinkFromAccount, whoSignedIn } from './signin.mjs';
import { appleTransaction, playPurchase, playSubscriptionOf, pushedByPlay, storeAccountOf } from './stores.mjs';
import { checkout, endAtStripe, endRefunded, manage, payerLookup, record, sameSite, webSubscriptionsOf, webhookSigned } from './stripe.mjs';
import { dateSubscription } from './subscriptions.mjs';
import { SUSPENDED_WHY, isOrder, orderRow } from './suspension.mjs';
import { LOCAL_TURN, mint } from './turn.mjs';
import { appleSigned } from './x509.mjs';

async function ticketRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'ticket');
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  // The account its licence names, or the store's (licence.mjs,
  // accountAsking), whose object decides: so for each handler that
  // asks it next.
  const { account, shown } = await accountAsking(store, key, body, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  const { status, body: out } = await inHousehold(env, account, { op: 'ticket', key, account, shown });
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
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  // In the account the code is for, which the code's row says. A code
  // nobody made, or one the store here already shows spent or run out,
  // is said so here, without queueing anybody: anybody who once saw a
  // code could otherwise spend the account's allowance with it. The
  // account's turn still decides.
  // A backup code, typed by a person, or a code off another device's
  // screen: sixteen characters of one alphabet, or thirty-two hex.
  const backup = backupCodeOf(body.ticket);
  let claimed;
  if (backup) {
    const account = (await store.get(await backupRow(backup), 'META'))?.account;
    if (!isAccount(account)) return json(request, 404, { error: REFUSED.noSuchCode });
    const mine = (await store.get(`ACCOUNT#${account}`, 'BACKUP'))?.codes?.find((c) => c.code === backup);
    if (mine?.used_at) return json(request, 409, { error: REFUSED.codeUsed });
    claimed = await inHousehold(env, account, { op: 'redeem', key, code: backup });
  } else {
    if (typeof body.ticket !== 'string' || !/^[0-9a-f]{2,64}$/.test(body.ticket)) return json(request, 400, { error: REFUSED.notACode });
    const ticket = await store.get(`TICKET#${body.ticket}`, 'META');
    if (!isAccount(ticket?.account)) return json(request, 404, { error: REFUSED.noSuchCode });
    if (ticket.used_at) return json(request, 409, { error: REFUSED.codeUsed });
    if (Date.parse(ticket.expires_at) <= Date.now()) return json(request, 410, { error: REFUSED.codeRunOut });
    claimed = await inHousehold(env, ticket.account, { op: 'claim', key, code: body.ticket });
  }
  if (claimed.status !== 200) return json(request, claimed.status, claimed.body);
  // Straight back with the licence it was claimed for, so the device
  // that scanned a code is playing rather than waiting to be told:
  // signed from what the account's object wrote, which the store here
  // may not show yet.
  const { status, body: out } = await licence(key, env, { signer, open: openHouse(env, request), written: claimed.body.entitlement });
  return json(request, status, out);
}

async function backupsRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'backups', (body) => (body.rotate === true ? 'rotate' : body.send === true ? 'send' : ''));
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const { account, shown } = await accountAsking(store, key, body, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  const rotate = body.rotate === true;
  const send = !rotate && body.send === true;
  // Stripe is asked for the payer's address only for a device of the
  // account: one the store here backs, or else one the account's turn
  // holds, as for a device just brought in.
  if (send && (shown || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${key}`)))) {
    const held = await inHousehold(env, account, { op: 'held', key, account, shown });
    if (held.status !== 200) return json(request, held.status, held.body);
  }
  const subscription = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  const payer = send ? await payerLookup(store, subscription, env) : { email: null, why: null };
  const { status, body: out } = await inHousehold(env, account, { op: 'backups', key, account, rotate, send, email: payer.email, why: payer.why, shown });
  return json(request, status, out);
}

/// A finished game's record, for a device to look at (records.mjs):
/// signed for the table, and shown only to the device in use of an
/// account with a subscription — looking at games is live play — and
/// not of a game its account is at.
async function reviewRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'review', (body) => (typeof body.table === 'string' ? body.table : ''));
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  if (typeof body.table !== 'string' || !tableIdShape.test(body.table)) return json(request, 400, { error: 'a table id, 32 hex' });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  // Held by the store here, or by the object of the account its licence
  // names where the store here has yet to hear of it (licence.mjs,
  // heldAccount): so for each handler that decides here.
  const account = await heldAccount(store, key, body, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  const ok = await inHousehold(env, account, { op: 'inUse', key, account, table: body.table });
  if (ok.status !== 200) return json(request, ok.status, ok.body);
  return recordResponse(env.OH_RECORDS, body.table, cors(request));
}

/// A device taking its account up, or saying it still has it
/// (household.mjs, "one device at a time"): the activation, signed, or
/// why not.
async function activateRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // What is asked is signed: nobody else's request makes this device
  // take its account from the one in use.
  const asked = await signedFor(request, env, 'activate', (body) => `${body.want ?? ''} ${body.seated ?? ''}`);
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  if (!['open', 'take', 'renew'].includes(body.want)) return json(request, 400, { error: 'want: open, take or renew' });
  const keys = serviceKeys(env);
  const store = storeOf(env);
  if (!keys || !store) return json(request, 503, notConfigured(keys ? 'OH_STORE' : 'OH_SERVICE_KEY and OH_SERVICE_SECRET'));
  const open = openHouse(env, request);
  const now = Date.now();
  // In local mode a device nobody has heard of is licensed, and so has
  // an account, as it asks.
  if (open) await entitlementOf(store, key, { now, openHouse: true });
  // The account its licence names, or the store's: a device just brought
  // in shows the one, before the store here has the other.
  const { account, shown } = await accountAsking(store, key, body, env, { signer, now });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  const took = await inHousehold(env, account, { op: 'activate', key, account, want: body.want, ...(body.seated !== undefined ? { seated: body.seated } : {}), shown });
  if (took.status !== 200) return json(request, took.status, took.body);
  // An hour, and never past the end of the day the subscription is paid
  // to.
  const paidTo = took.body.licensed_until ? Date.parse(`${took.body.licensed_until}T00:00:00Z`) / 1000 + 86400 : 0;
  const until = Math.floor(Math.min(now / 1000 + ACTIVATION_S, paidTo || now / 1000 + ACTIVATION_S));
  const activation = await activationFor(account, key, took.body.epoch, until, { signer, ...keys });
  if (!activation) return json(request, 503, { error: 'the service key does not match its secret' });
  return json(request, 200, { activation, profile: took.body.profile, ...(took.body.took ? { took: true } : {}) });
}

/// A finished game's record, sent by one of its players' devices to be
/// kept (records.mjs): signed for the table it is the record of, by the
/// device in use of an account with a subscription — live play is what
/// leaves a record — and so many an hour, in the account's own turn.
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
  const { key, body: sent, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const account = await heldAccount(store, key, sent, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  const ok = await inHousehold(env, account, { op: 'record', key, account });
  if (ok.status !== 200) return json(request, ok.status, ok.body);
  const { status, body } = await keepRecord(env.OH_RECORDS, key, sent.table, sent.record, {
    verify: (k, d, s) => signer.verify(k, d, s),
    service: serviceKeys(env)?.service,
  });
  return json(request, status, body);
}

async function devicesRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'devices', (body) => (typeof body.drop === 'string' ? body.drop : ''));
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const drop = body.drop;
  if (typeof drop === 'string' && !/^[0-9a-f]{64}$/.test(drop)) return json(request, 400, { error: 'a table key, 64 hex' });
  const { account, shown } = await accountAsking(store, key, body, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  if (typeof drop === 'string') {
    const { status, body: out } = await inHousehold(env, account, { op: 'drop', key, account, device: drop, shown });
    if (status !== 200) return json(request, status, out);
  }
  const { status, body: out } = await inHousehold(env, account, { op: 'list', key, account, shown });
  return json(request, status, out);
}

/// The account's profile: read with nothing asked, or written with
/// `profile`, the profile as the device's own text — which is what it
/// signs, so nobody else's request writes this one's name. Both in the
/// account's turn: a read among its reads, a write with an allowance of
/// its own.
async function profileRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'profile', (body) => (typeof body.profile === 'string' ? body.profile : ''), {
    most: MOST_PROFILE_BODY,
  });
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  if (body.profile !== undefined && typeof body.profile !== 'string') return json(request, 400, { error: 'not a profile' });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const { account, shown } = await accountAsking(store, key, body, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  const { status, body: out } = await inHousehold(env, account, { op: 'profile', key, account, ...(body.profile !== undefined ? { profile: body.profile } : {}), shown });
  return json(request, status, out);
}

/// attest and supersede are one route: the same proof, and which of the
/// two it is depends on whether the person is linking the account they
/// are in, or coming into the one they linked.
async function signInRoute(request, env, move) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // The token names the key its nonce was made for, and the nonce is
  // whoever asked the provider's to choose: a stranger can have his
  // own account signed over somebody else's key. The key signing the
  // request is what says it wanted that account, so it signs the
  // provider and the token themselves (`<provider> <token>`): a request
  // somebody captured cannot be sent again with a token of their own
  // choosing in its place, nor one signed as these were when they
  // signed nothing.
  const asked = await signedFor(request, env, move ? 'supersede' : 'attest', (body) => `${body.provider} ${body.token}`);
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  // What is signed is the text of the two, so a token that is not text
  // (an array of one, which would read as it) is not one.
  if (typeof body.provider !== 'string' || typeof body.token !== 'string') return json(request, 401, { error: REFUSED.signInRefused });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const who = await whoSignedIn(body.provider, body.token, key, env, fetch, { open: openHouse(env, request) });
  if (!who) return json(request, 401, { error: REFUSED.signInRefused });
  const login = await loginRow(who, env);
  // In local mode a device nobody has heard of has an account, as it
  // asks for anything.
  if (openHouse(env, request)) await entitlementOf(store, key, { openHouse: true });
  const { account: mine, shown } = await accountAsking(store, key, body, env, { signer });
  const { status, body: out, entitlement } = move
    ? await supersede(who, key, store, env, login)
    : mine
      ? await inHousehold(env, mine, { op: 'attest', who, key, account: mine, login, shown })
      : { status: 402, body: { error: REFUSED.noSubscription } };
  if (status !== 200) return json(request, status, out);
  // Straight back with the licence it is owed, if any: a device that
  // has just proved who it is should not have to ask twice. One brought
  // in is licensed from what its account's object wrote.
  const licensed = await licence(key, env, { signer, open: openHouse(env, request), written: entitlement });
  return json(request, 200, { ...out, ...(licensed.status === 200 ? licensed.body : {}) });
}

/// Sign in with Apple's server-to-server notifications. Answered 200
/// once it has been read, whatever its type, so Apple does not send it
/// again; 400 when it is not Apple's; 503 when what it asks could not be
/// done, so that if Apple sends it again it is done then. Quiet: the
/// operator is not mailed, and the line `measure` writes, under this
/// handler's name, is the count.
async function appleIdRoute(request, env) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  // One token of a kilobyte or so: an ordinary request's bound is room
  // and to spare.
  const raw = await textOf(request, MOST_BODY);
  if (raw === null) return json(request, 413, { error: 'too big' });
  if (!env[PROVIDERS.apple.audience]) return json(request, 503, { error: 'sign-in is not set up yet' });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  let payload;
  try {
    ({ payload } = JSON.parse(raw));
  } catch {
    return json(request, 400, { error: 'not signed' });
  }
  const notice = await appleIdNotice(payload, env);
  if (!notice) return json(request, 400, { error: 'not signed' });
  if (!APPLE_ID_GONE.has(notice.type)) return json(request, 200, { unlinked: null });
  const login = await loginRow({ provider: 'apple', sub: notice.sub }, env);
  if (!login) return json(request, 503, notConfigured('OH_ID_HMAC'));
  const done = await unlinkFromAccount(env, store, login);
  if (done.status !== 200) return json(request, 503, { error: 'not unlinked yet' });
  return json(request, 200, done.body);
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
  // A suspended account's device is not sold a subscription it could
  // not play on (suspension.mjs).
  const store = storeOf(env);
  if ((await store?.get(`KEY#${key}`, 'ENTITLEMENT'))?.suspended) return json(request, 403, { error: SUSPENDED_WHY, suspended: true });
  const { status, body: out } = await checkout(key, back, cancelled, env, fetch, { lang: body.lang });
  return json(request, status, out);
}

/// An operator's order, carried out in its account's turn
/// (suspension.mjs), or, for a notice of a change to the terms, here
/// (notices.mjs): `{order}`, the id the operator's tool wrote it under.
/// The order is read here first, so a request that names none wakes no
/// account's object. A termination the relay orders when Arachnid
/// Shield matches a picture (service/do/known.mjs) says `endWeb`: once the
/// account is ended, so is each of its web subscriptions in Stripe,
/// with nothing refunded, as for any serious breach. Stripe not
/// answering is a 502, and the relay orders it again.
async function orderRoute(request, env) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  let id = null;
  try {
    id = JSON.parse((await textOf(request, 256)) ?? 'null')?.order;
  } catch {
    // Not JSON: no order.
  }
  if (!isOrder(id)) return json(request, 400, { error: 'an order, 32 hex' });
  const order = await store.get(...orderRow(id));
  if (order?.act === 'notice') {
    const { status, body } = await carryOutNotice(order, store, env);
    return json(request, status, body);
  }
  if (!order || !isAccount(order.account)) return json(request, 404, { error: 'no such order' });
  const { status, body } = await inHousehold(env, order.account, { op: 'order', account: order.account, order: id });
  if (status !== 200 || order.act !== 'terminate' || order.endWeb !== true) return json(request, status, body);
  const web = webSubscriptionsOf(await store.get(`ACCOUNT#${order.account}`, 'META'));
  return (await endWebSubscriptions(request, env, web, 'terminated under the terms')) ?? json(request, 200, { ...body, endedWeb: web });
}

/// Each of [web], an account's web subscriptions, ended in Stripe with
/// [comment] as the reason: null once they are, or the answer when they
/// could not be, 503 without the Stripe key and 502 when Stripe did not
/// answer, so that the asker asks again.
async function endWebSubscriptions(request, env, web, comment) {
  if (web.length && !env.OH_STRIPE_SECRET) return json(request, 503, notConfigured('OH_STRIPE_SECRET'));
  try {
    for (const sub of web) await endAtStripe(sub, env.OH_STRIPE_SECRET, comment);
  } catch {
    return json(request, 502, { error: 'the shop is not answering' });
  }
  return null;
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
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const { status, body } = await manage(asked.key, back, store, env);
  return json(request, status, body);
}

async function stripeRoute(request, env, ctx) {
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST' });
  const raw = await textOf(request, MOST_EVENT);
  if (raw === null) return json(request, 413, { error: 'too big' });
  if (!(await webhookSigned(request.headers.get('stripe-signature'), raw, env.OH_STRIPE_WEBHOOK_SECRET))) {
    // Nothing is read out of a body nobody signed.
    return json(request, 400, { error: 'not signed' });
  }
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    return json(request, 400, { error: 'not json' });
  }
  // A refund, by anyone, ends the subscription it was for: answered
  // with an error when Stripe could not be asked, so Stripe sends it
  // again.
  if (event?.type === 'charge.refunded') {
    const ended = await endRefunded(event.data?.object, store, env);
    return json(request, ended.status, ended.status === 200 ? { ok: true } : ended.body);
  }
  // A paid checkout is bound in its subscription's own turn, where its
  // account is found or made once, however many deliveries overlap.
  const done = await record(event, store, { bind: (subscription, key) => inSubscription(env, subscription, { op: 'paid', subscription, key }) });
  if (done?.bound && triedAgain(done.status)) return json(request, 503, { error: 'not bound yet' });
  if (done?.bound) await after(ctx, alertSubscribed(env, store, { subscription: done.subscription, source: 'stripe', key: done.bound }));
  // A subscription just paid for: its account's backup codes, sent to
  // the email the checkout was paid with, with what it paid. Not kept:
  // it is on the event.
  if (done?.bound && done.account) {
    const paid = event.data?.object;
    const email = paid?.customer_details?.email ?? null;
    const charge = Number.isSafeInteger(paid?.amount_total) && typeof paid?.currency === 'string' ? { amount: paid.amount_total, currency: paid.currency } : null;
    const made = await inHousehold(env, done.account, { op: 'made', account: done.account, subscription: done.subscription, email, charge });
    if (triedAgain(made.status)) return json(request, 503, { error: 'backup codes not made yet' });
  }
  // Anything not ours is still a delivery taken: a webhook that gets an
  // error back is a webhook Stripe keeps sending.
  return json(request, 200, { ok: true });
}

/// Whether an account's turn answering [status] is worth Stripe sending
/// the event again: over the hour's allowance, the turn failing, or a
/// relay deployed before this site that does not know the op yet (400,
/// which the ops asked here never answer otherwise). A refusal that would
/// come out the same, such as a full account, is taken as the answer.
/// Every step of a delivery can run twice.
const triedAgain = (status) => status === 400 || status === 429 || status >= 500;

async function licenceRoute(request, env, ctx) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // Signed, though a licence is for its own key and no use to anybody
  // else: whether a key pays, and until when, is the key's business.
  const asked = await signedFor(request, env, 'licence');
  if (asked instanceof Response) return asked;
  const open = openHouse(env, request);
  const { status, body } = await licence(asked.key, env, { signer: asked.signer, open });
  return json(request, status, body);
}

/// A subscriber's device, finding its pool empty, waiting for a person
/// rather than playing bots (packages/table, matching.dart): the
/// operator is told, so that someone can come and play (alerts.mjs).
/// Signed for the pool and the game, by a device of an account with a
/// subscription. The answer says nothing of whether anybody was told.
async function waitingRoute(request, env, ctx) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'waiting', (body) => `${body.pool ?? ''} ${body.target ?? ''}`);
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  if (typeof body.pool !== 'string' || !/^[a-z]{1,16}$/.test(body.pool) || !Number.isInteger(body.target) || body.target < 1 || body.target > 100) {
    return json(request, 400, { error: 'a pool and the score its game runs to' });
  }
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const account = await heldAccount(store, key, body, env, { signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  if (!openHouse(env, request)) await after(ctx, alertWaiting(env, store, { key, account, pool: body.pool, target: body.target }));
  return json(request, 200, { ok: true });
}

/// A subscriber's report of another player (alerts.mjs, alertReport):
/// emailed to the operator at once. 429 for one too many in a day; 503
/// when it could not be sent, so the app can say so.
async function reportRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'report', (body) => `${body.about ?? ''} ${body.what ?? ''}`);
  if (asked instanceof Response) return asked;
  const report = reportOf(asked.body);
  if (!report) return json(request, 400, { error: 'a report: who, for what, and a short note at most' });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  const account = await heldAccount(store, asked.key, asked.body, env, { signer: asked.signer });
  if (!account) return json(request, 402, { error: REFUSED.noSubscription });
  if (report.about === account) return json(request, 400, { error: 'a report is of somebody else' });
  // Local mode tells nobody, as for a wait.
  if (openHouse(env, request)) return json(request, 200, { ok: true });
  const said = await alertReport(env, store, { key: asked.key, account, ...report });
  if (said === 'limit') return json(request, 429, { error: 'too many reports today' });
  if (said === 'unsent') return json(request, 503, { error: 'the report could not be sent' });
  return json(request, 200, { ok: true });
}

/// The account of the device asking, deleted: by any device of it, as
/// any may drop another (docs/explanation/service.md, "Deleting an
/// account's data"). Signed for `delete`. What is outside the store
/// goes first, so that a run that stops part way finds the account
/// still there when the device asks again: each web subscription of it
/// still running is ended in Stripe, the time left on it with it (the
/// terms, "Ending these terms"); the account is marked forgotten, and
/// its name taken off the games it played (records.mjs). Then its rows,
/// in its turn (deletion.mjs, deleteAccount). A game that would not be
/// written back as it was sent keeps the name, and the operator is told
/// (alerts.mjs). 404 for a device in no account: one whose deletion is
/// done. Under a legal hold, only the asking is noted.
async function deleteRoute(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  const asked = await signedFor(request, env, 'delete');
  if (asked instanceof Response) return asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  // The store's word alone, never a licence's (licence.mjs,
  // accountAsking): what is outside the store is done here, before the
  // account's object is asked anything, and a device dropped from the
  // account still holds its licence until its day.
  const account = await accountOfKey(store, asked.key);
  if (!account || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${asked.key}`))) return json(request, 404, { error: 'no account' });
  if (!(await holdOf(store, account))) {
    const unended = await endWebSubscriptions(request, env, webSubscriptionsOf(await store.get(`ACCOUNT#${account}`, 'META')), 'account deleted');
    if (unended) return unended;
    if (env.OH_RECORDS) {
      await markForgotten(env.OH_RECORDS, account);
      const unwritten = [];
      await anonymizeGames(keptGames(env.OH_RECORDS), account, { refused: (key) => unwritten.push(key) });
      await alertUnwritten(env, { account, keys: unwritten });
    }
  }
  // With the changes a subscription may have been told of, from the
  // ledger this deploy published, which the account's turn has not.
  const { status, body } = await inHousehold(env, account, { op: 'delete', key: asked.key, account, notices: toldVersions(env.OH_LEDGER) });
  return json(request, status, body);
}

async function turn(request, env) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // Credentials are a relay anybody holding them can send anything
  // through until they run out (turnTtlS), and it is billed by the
  // gigabyte. So they
  // are a subscribed device's, as live play is, and nobody else's.
  const asked = await signedFor(request, env, 'turn');
  if (asked instanceof Response) return asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  if (!(await heldAccount(store, asked.key, asked.body, env, { signer: asked.signer, openHouse: openHouse(env, request) }))) {
    return json(request, 402, { error: REFUSED.noSubscription });
  }
  // Local mode's own TURN server, where OH_TURN_LOCAL names one, kept
  // for voice and video chat: the browser rig sets none now.
  if (openHouse(env, request) && env.OH_TURN_LOCAL) {
    return json(request, 200, { iceServers: [{ urls: [env.OH_TURN_LOCAL], username: LOCAL_TURN, credential: LOCAL_TURN }], ttl: serviceSettings().turnTtlS });
  }
  const { status, body: out } = await mint(env);
  return json(request, status, out);
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
  // device opening the app within one. With the operator's row, the
  // changes to the terms and the privacy policy every device is told of
  // (notices.mjs), from the ledger this deploy published.
  return json(request, 200, { ...configOf(raw), notices: noticesOf(env.OH_LEDGER) }, { 'cache-control': 'public, max-age=60' });
}

async function storeRoute(request, env, ctx) {
  const pre = preflight(request, 'POST');
  if (pre) return pre;
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  // The proof is what is signed: a device brings its own purchase, and
  // nobody brings one for it.
  const asked = await signedFor(request, env, 'store', (body) => (typeof body.proof === 'string' ? body.proof : ''));
  if (asked instanceof Response) return asked;
  const { key, body, signer } = asked;
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  if (body.store !== 'apple' && body.store !== 'google') return json(request, 400, { error: REFUSED.notAStore });
  if (typeof body.proof !== 'string' || !body.proof) return json(request, 400, { error: REFUSED.noProof });
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
  const known = await store.get(`SUB#${bought.subscription}`, 'META');
  const bound = await inSubscription(env, bought.subscription, { op: 'bind', key, ...op });
  if (bound.status !== 200) return json(request, bound.status, bound.body);
  if (!known) await after(ctx, alertSubscribed(env, store, { subscription: bought.subscription, source: bought.source, key, now }));
  const { status, body: out } = await licence(key, env, { signer, now, written: bound.body.entitlement });
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
  if (!env.OH_APPLE_BUNDLE_ID || !env.OH_APPLE_PRODUCT) return json(request, 503, { error: REFUSED.storeNotSetUp });
  const store = storeOf(env);
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
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
  if (!store) return json(request, 503, notConfigured('OH_STORE'));
  let note;
  try {
    const pushed = JSON.parse((await textOf(request, MOST_BODY)) ?? '');
    note = JSON.parse(new TextDecoder().decode(bytesOf64(pushed.message.data)));
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

/// [work] finished after the answer has gone, where the runtime lets
/// it (ctx.waitUntil); awaited where it does not, as in the tests.
async function after(ctx, work) {
  if (ctx?.waitUntil) ctx.waitUntil(work);
  else await work;
}

/// The handlers by name, as /api/<name> asks for them.
const ROUTES = {
  config: (request, env) => configRoute(request, env),
  health: (request, env) => healthRoute(request, env),
  turn: (request, env) => turn(request, env),
  licence: (request, env, ctx) => licenceRoute(request, env, ctx),
  checkout: (request, env) => checkoutRoute(request, env),
  stripe: (request, env, ctx) => stripeRoute(request, env, ctx),
  manage: (request, env) => manageRoute(request, env),
  store: (request, env, ctx) => storeRoute(request, env, ctx),
  apple: (request, env) => appleRoute(request, env),
  play: (request, env) => playRoute(request, env),
  ticket: (request, env) => ticketRoute(request, env),
  claim: (request, env) => claimRoute(request, env),
  backups: (request, env) => backupsRoute(request, env),
  devices: (request, env) => devicesRoute(request, env),
  profile: (request, env) => profileRoute(request, env),
  waiting: (request, env, ctx) => waitingRoute(request, env, ctx),
  report: (request, env) => reportRoute(request, env),
  delete: (request, env) => deleteRoute(request, env),
  attest: (request, env) => signInRoute(request, env, false),
  supersede: (request, env) => signInRoute(request, env, true),
  'apple-id': (request, env) => appleIdRoute(request, env),
  activate: (request, env) => activateRoute(request, env),
  record: (request, env) => recordRoute(request, env),
  review: (request, env) => reviewRoute(request, env),
  order: (request, env) => orderRoute(request, env),
};

/// Whether this deployment answers /api/ at [url]. A preview answers on
/// whatever address it is reached by; production, on the app's host and
/// on this machine's, and nowhere else. The zone's rate limit is on the
/// app's host (infra/cloudflare.mjs), and a production deployment is
/// reachable at open-hearts.pages.dev too, and at an address of its own
/// for as long as it is kept, where that limit does not reach.
const answersApi = (env, url) => env.OH_DEPLOYMENT === 'preview' || url.hostname === APP_HOST || isLocal(url.href);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const name = url.pathname.startsWith('/api/') ? url.pathname.slice('/api/'.length) : null;
    if (name === null) return serveStatic(request, env);
    // Said in the handlers' own way, so an app still open at the old
    // address shows it rather than "could not reach the service".
    if (appHostFor(url.hostname)) {
      return Response.json({ error: `the service has moved to ${appHostFor(url.hostname)}` }, { status: 404, headers: { 'cache-control': 'no-store' } });
    }
    if (!answersApi(env, url)) return json(request, 404, { error: 'no such handler' });
    const route = Object.hasOwn(ROUTES, name) ? ROUTES[name] : null;
    const started = Date.now();
    if (route) await loadServiceSettings(env);
    let response;
    try {
      response = route ? await route(request, env, ctx) : json(request, 404, { error: 'no such handler' });
    } catch (e) {
      // A handler that throws is counted as the 500 the runtime answers
      // for it, and thrown on, so the runtime answers and logs it as before.
      measure(env, name, 500, Date.now() - started);
      throw e;
    }
    measure(env, route ? name : 'unknown', response.status, Date.now() - started);
    return response;
  },
};
