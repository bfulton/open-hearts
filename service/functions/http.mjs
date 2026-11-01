// What every handler shares on the wire (worker.mjs): which origins may
// ask, answers as JSON, and a signed request read and checked ("who is
// asking", below).

import { APP_HOST } from './app_host.mjs';
import { signerFor } from './licence.mjs';
import { REFUSED } from './refusals.mjs';
import { digestOf } from './rows.mjs';
import { S, isLocal } from './settings.mjs';

/// The origin a browser may call the handlers from, echoed back, or
/// null: the site's own hosts, the app's (which calls its own origin's
/// /api/, so needs none of this, but an app's page is not the only
/// caller), and — on a dev machine only — the dev machine's own pages.
export function allowedOrigin(origin, requestUrl = null) {
  if (!origin) return null;
  let host;
  try {
    host = new URL(origin).hostname;
  } catch {
    return null;
  }
  if (host === 'localhost' || host === '127.0.0.1' || host.endsWith('.localhost')) return requestUrl && isLocal(requestUrl) ? origin : null;
  if (host === 'openhearts.game' || host === 'www.openhearts.game' || host === APP_HOST) return origin;
  if (host === 'open-hearts.pages.dev' || host.endsWith('.open-hearts.pages.dev')) return origin;
  return null;
}

export function cors(request, headers = {}) {
  const origin = allowedOrigin(request.headers.get('origin'), request.url);
  const h = { ...headers };
  if (origin) {
    h['access-control-allow-origin'] = origin;
    h['vary'] = 'origin';
  }
  return h;
}

export const json = (request, status, body, extra = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: cors(request, { 'content-type': 'application/json', 'cache-control': 'no-store', ...extra }),
  });

// ---- who is asking -----------------------------------------------------
// A handler asked with a key acts for that key: it licenses it, mints
// it TURN, makes a code against what it paid for, binds it, lists its
// account's devices and drops them, makes it the account's device in
// use. And a key is public — it signs
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
    return { status: 401, body: { error: REFUSED.clockOff } };
  }
  return { key };
}

/// The key a handler was called with, or null.
function keyOf(body) {
  const key = body?.key;
  return typeof key === 'string' && /^[0-9a-f]{64}$/.test(key) ? key : null;
}

/// The most a handler's request may carry. Every one of them asks with
/// a key, a signature and a word or two; a body past this is not one of
/// ours, and is not parsed to find out.
export const MOST_BODY = 16 * 1024;

/// Stripe's events are larger, and few: a checkout or a subscription,
/// with its line items.
export const MOST_EVENT = 512 * 1024;

/// The body as text, or null when it is longer than [most] bytes — said
/// by its length where the request says one, and counted as it is read
/// where it does not, so that a body sent with no length is never read
/// much past [most].
export async function textOf(request, most) {
  const said = Number(request.headers.get('content-length'));
  if (Number.isFinite(said) && said > most) return null;
  const chunks = [];
  let size = 0;
  try {
    // No body at all is an empty one.
    const reader = request.body?.getReader();
    while (reader) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > most) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    // A body already read, or cut off.
    return null;
  }
  return new Blob(chunks).text();
}

/// The body as JSON, or null when it is longer than [most] or not JSON.
export async function bodyOf(request, most = MOST_BODY) {
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
export async function signedFor(request, env, handler, whatOf = () => '', { most = MOST_BODY } = {}) {
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
export function preflight(request, methods) {
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
