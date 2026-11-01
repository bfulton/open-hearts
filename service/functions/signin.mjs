// Signing in with a provider: its token checked against the keys it
// publishes, and the sign-in linked to an account; and Apple's notice
// that a sign-in is gone.

import { inHousehold } from './household.mjs';
import { linkedAccount } from './logins.mjs';
import { REFUSED } from './refusals.mjs';
import { dayOf, digestOf, un64 } from './rows.mjs';
import { notConfigured } from './settings.mjs';

// ---- who this is, where a provider will say ----------------------------
// An account is a person. A code (accounts.mjs) is how the person
// brings their own second device in, and a backup code how they come
// back without one; a sign-in with Apple or Google is the same as a
// backup code that is never used up — a phone in a river is not a
// phone that can show a code. One sign-in is linked to one account,
// and one account to one sign-in (logins.mjs, attest); signing in on
// any device brings it into that account ([supersede], by its old
// name).
//
// What is stored of the provider is an HMAC of its subject identifier,
// never the identifier: it is opaque but stable and joins to a real
// account, so a leaked table has to join to nothing. And nothing on the
// KEY# side leads back to the provider — the key is what public records
// carry (docs/explanation/service.md).

export const PROVIDERS = {
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
  // where the open house is (docs/explanation/service.md). One branch, never on
  // in production, and the rest of the path below is the same path.
  if (open && typeof token === 'string' && token.startsWith('local:')) {
    const sub = token.slice('local:'.length);
    return sub && PROVIDERS[provider] ? { provider, sub } : null;
  }
  const known = PROVIDERS[provider];
  // One audience or several, comma-separated: Apple's token names the
  // bundle on an iPhone and the Services ID on the web, and both are us.
  const audiences = known ? String(env[known.audience] ?? '').split(',').map((a) => a.trim()).filter(Boolean) : [];
  if (!audiences.length) return null;
  const claims = await jwtOf(provider, token, fetchImpl, { now });
  if (!claims) return null;
  if (claims.iss !== known.iss) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.some((a) => audiences.includes(a))) return null;
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

/// Signing in on a device: it comes into the account the sign-in is
/// linked to, as a backup code would bring it — by the same rules, in
/// the account's turn. {status, body}, with the account; and the
/// device's row as the account's object wrote it, [entitlement], for
/// its licence (accounts.mjs, entitlementOf), which the device is not
/// sent.
export async function supersede(who, key, store, env, login, { now = Date.now() } = {}) {
  if (!login) return { status: 503, body: notConfigured('OH_ID_HMAC') };
  const account = await linkedAccount(store, login);
  if (!account) return { status: 404, body: { error: REFUSED.accountNowhere } };
  const joined = await inHousehold(env, account, { op: 'join', key, account, now });
  if (joined.status !== 200) return joined;
  return { status: 200, body: { account, at: dayOf(now) }, entitlement: joined.body.entitlement };
}

// ---- when Apple says a sign-in is gone -----------------------------------
// Sign in with Apple tells the app's server when a person stops using it
// with the app (their Apple Account's settings, Sign in with Apple, Stop
// Using) or deletes their Apple Account, and when they turn forwarding
// to a hidden address on or off. Apple POSTs {"payload": <JWT>} to the
// address registered on the primary App ID, signed with the keys it
// signs ID tokens with, for that App ID as its audience, and with an
// `events` claim — a JSON string, as it arrives, or the object Apple's
// own page shows — holding the type, the person's subject and when.
//
// A sign-in that is gone is unlinked from its account: it no longer
// brings a device in, and the account can be linked again. That is all.
// The account stays, with its devices and its backup codes, which still
// bring devices in, and with its subscription, which is the store's or
// Stripe's to end. We hold no email from Apple, so the notices about
// forwarding change nothing here.
//
// Nothing is kept to spot a notice seen before (its jti): one sent again,
// by Apple or by anybody holding a copy, only unlinks what is already
// unlinked.

/// The types after which the person's Apple identity no longer signs in
/// to this app. Apple's page names the deletion `account-deleted`; it
/// once said `account-delete`, and both are taken.
export const APPLE_ID_GONE = new Set(['consent-revoked', 'account-deleted', 'account-delete']);

/// How long a notice is good for when its token gives no expiry: the
/// day Apple's own carry.
const APPLE_ID_NOTICE_S = 24 * 60 * 60;

/// What a Sign in with Apple notification says, once its token has
/// checked out against Apple's published keys, its issuer, one of our
/// audiences and its date: {type, sub}. Null when it is not that — a
/// forgery, somebody else's app's, run out, or a token that is not a
/// notification at all, such as an ID token from a sign-in, which is
/// signed by the same keys for the same audience but carries no events.
export async function appleIdNotice(payload, env, fetchImpl = fetch, { now = Date.now() } = {}) {
  const audiences = String(env[PROVIDERS.apple.audience] ?? '').split(',').map((a) => a.trim()).filter(Boolean);
  if (!audiences.length) return null;
  const claims = await jwtOf('apple', payload, fetchImpl, { now });
  if (!claims) return null;
  if (claims.iss !== PROVIDERS.apple.iss) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.some((a) => audiences.includes(a))) return null;
  const until = typeof claims.exp === 'number' ? claims.exp : typeof claims.iat === 'number' ? claims.iat + APPLE_ID_NOTICE_S : null;
  if (until === null || until * 1000 <= now) return null;
  let events = claims.events;
  if (typeof events === 'string') {
    try {
      events = JSON.parse(events);
    } catch {
      return null;
    }
  }
  if (typeof events?.type !== 'string' || typeof events.sub !== 'string' || !events.sub) return null;
  return { type: events.type, sub: events.sub };
}

/// [login] unlinked from the account it is linked to: in that account's
/// turn, since linking it is done in that turn too.
export async function unlinkFromAccount(env, store, login) {
  const account = await linkedAccount(store, login);
  if (!account) return { status: 200, body: { unlinked: false } };
  return inHousehold(env, account, { op: 'unlink', account, login });
}
