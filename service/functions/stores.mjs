// Buying in a store: the App Store's and Google Play's purchases,
// checked as each store signs them.

import { REFUSED } from './refusals.mjs';
import { base64Of, bytesOf64, digestOf, hex } from './rows.mjs';
import { PROVIDERS, jwtOf } from './signin.mjs';
import { appleSigned } from './x509.mjs';

// ---- buying in a store -------------------------------------------------
// On a phone, live play is the store's own subscription
// (docs/explanation/service.md). The device buys, the store hands it a proof,
// and the device brings the proof here, signed as every request is:
//
//   App Store    a StoreKit 2 signed transaction: a JWS whose
//                certificate chain ends at Apple's own root, pinned
//                in x509.mjs. Checked here, offline; nothing is asked
//                of Apple.
//   Google Play  a purchase token, which proves nothing by itself: the
//                Play Developer API is asked what it is, with the
//                project's service account, and the purchase is
//                acknowledged — Play refunds one that is not, in three
//                days.
//
// A subscription bought in a store is `apple:<original transaction>` or
// `google:<hash of the purchase token>`, with its account, its date and
// its devices like any other. Renewals, lapses and refunds arrive the
// way Stripe's do, pushed: App Store Server Notifications V2 at
// /api/apple, Play's Real-time Developer Notifications at /api/play.
//
// The store's own record names the device a purchase was made for: the
// app sets Apple's appAccountToken, and Play's obfuscated account id,
// from its key (storeAccountOf). The device that paid may move onto
// what it paid for from wherever it was. Any other device bringing the
// same proof — the same Apple or Google account restoring it on a new
// phone — joins its account as a code would let it, within the
// account's count and not out of another paid-up one.

/// What the store's record holds for the device with [key]: Play's
/// obfuscated account id (64 hex) and Apple's appAccountToken (a UUID
/// cut from the same hash). The app makes the same two
/// (app/lib/net/store_buying.dart); a test pins both.
export async function storeAccountOf(key) {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`oh-store/1\n${key}`)));
  const u = h.slice(0, 16);
  u[6] = (u[6] & 0x0f) | 0x40;
  u[8] = (u[8] & 0x3f) | 0x80;
  const x = hex(u);
  return { google: hex(h), apple: `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}` };
}

// ---- the App Store -------------------------------------------------------

/// A checked App Store transaction, as this service reads it: the
/// subscription, when it runs to, whether it has ended, and whom it
/// was bought for. {status, body} when it is not one of ours.
export async function appleTransaction(jws, env, { now = Date.now() } = {}) {
  const bundle = env.OH_APPLE_BUNDLE_ID;
  const product = env.OH_APPLE_PRODUCT;
  if (!bundle || !product) return { status: 503, body: { error: REFUSED.storeNotSetUp } };
  const t = await appleSigned(jws, { now });
  if (!t) return { status: 401, body: { error: REFUSED.notFromStore } };
  // Another app's, another product's, or not a subscription at all.
  if (t.bundleId !== bundle || t.productId !== product || t.type !== 'Auto-Renewable Subscription') {
    return { status: 401, body: { error: REFUSED.notFromStore } };
  }
  if (typeof t.originalTransactionId !== 'string' || !/^\d{1,32}$/.test(t.originalTransactionId) || !Number.isFinite(t.expiresDate)) {
    return { status: 401, body: { error: REFUSED.notFromStore } };
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

const pemBytes = (pem) => bytesOf64(String(pem).replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
const b64url = (bytes) => base64Of(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlText = (text) => b64url(new TextEncoder().encode(text));

/// An access token for the Play Developer API, from the service
/// account in OH_PLAY_SERVICE_ACCOUNT (its JSON key), kept until a
/// minute before it runs out.
export async function playToken(env, fetchImpl = fetch, { now = Date.now() } = {}) {
  if (playAccess && playAccess.until > now) return playAccess.token;
  let account;
  try {
    account = JSON.parse(env.OH_PLAY_SERVICE_ACCOUNT);
    if (typeof account?.client_email !== 'string' || typeof account?.private_key !== 'string') throw new Error();
  } catch {
    // Said in words of its own: what JSON.parse says quotes the start of
    // the secret. Thrown on, so Play is taken as not answering and its
    // notifications are sent again until the secret is put right.
    console.log('play: OH_PLAY_SERVICE_ACCOUNT does not parse, or lacks client_email or private_key');
    throw new Error('OH_PLAY_SERVICE_ACCOUNT');
  }
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
export const playSubscriptionOf = async (token) => `google:${await digestOf(`oh-play/1\n${token}`)}`;

/// The states a Play subscription is paid up in. CANCELED is paid up
/// too, to the end of what was paid for: cancelling stops the renewal.
const PLAY_PAID = new Set(['SUBSCRIPTION_STATE_ACTIVE', 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD', 'SUBSCRIPTION_STATE_CANCELED']);

/// What Play says of the purchase [token], as this service reads it —
/// and acknowledged, if it was not yet. {status, body} when it is not
/// one of ours or Play cannot be asked.
export async function playPurchase(token, env, fetchImpl = fetch, { now = Date.now(), store = null } = {}) {
  const pkg = env.OH_PLAY_PACKAGE;
  const product = env.OH_PLAY_PRODUCT;
  if (!pkg || !product || !env.OH_PLAY_SERVICE_ACCOUNT) return { status: 503, body: { error: REFUSED.storeNotSetUp } };
  if (typeof token !== 'string' || !/^[A-Za-z0-9._:-]{10,1024}$/.test(token)) return { status: 401, body: { error: REFUSED.notFromStore } };
  let access;
  let res;
  try {
    access = await playToken(env, fetchImpl, { now });
    res = await fetchImpl(`${PLAY}/${encodeURIComponent(pkg)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(token)}`, {
      headers: { authorization: `Bearer ${access}` },
    });
  } catch {
    return { status: 502, body: { error: REFUSED.storeNotAnswering } };
  }
  // A token Play has never heard of, or not this app's.
  if (res.status === 400 || res.status === 404 || res.status === 410) return { status: 401, body: { error: REFUSED.notFromStore } };
  if (!res.ok) return { status: 502, body: { error: REFUSED.storeNotAnswering } };
  let p;
  try {
    p = await res.json();
  } catch {
    return { status: 502, body: { error: REFUSED.storeNotAnswering } };
  }
  const line = Array.isArray(p.lineItems) ? p.lineItems.find((l) => l?.productId === product) : null;
  if (!line) return { status: 401, body: { error: REFUSED.notFromStore } };
  const until = Date.parse(line.expiryTime);
  // Play refunds a purchase nobody acknowledged within three days; this
  // is where it is taken, so this is where it is acknowledged.
  if (p.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING' && PLAY_PAID.has(p.subscriptionState)) {
    // One that does not go is asked again on the next notification or
    // the next device to bring it, and said in the log: a service account
    // that may read purchases but not acknowledge them would see every
    // purchase refunded.
    try {
      const ack = await fetchImpl(`${PLAY}/${encodeURIComponent(pkg)}/purchases/subscriptions/${encodeURIComponent(product)}/tokens/${encodeURIComponent(token)}:acknowledge`, {
        method: 'POST',
        headers: { authorization: `Bearer ${access}`, 'content-type': 'application/json' },
        body: '{}',
      });
      if (!ack.ok) console.log(`play acknowledge: ${ack.status}`);
    } catch {
      console.log('play acknowledge: unreachable');
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
  if (!PROVIDERS.google.issuers.includes(claims.iss)) return false;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(env.OH_PLAY_PUSH_AUDIENCE)) return false;
  if (typeof claims.exp !== 'number' || claims.exp * 1000 <= now) return false;
  return claims.email === env.OH_PLAY_PUSH_EMAIL && claims.email_verified === true;
}
