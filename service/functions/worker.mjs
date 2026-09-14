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
// No imports, so nothing is bundled: the file is the worker.

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
  // OH_-prefixed; the old unprefixed names are still read so a project
  // whose dashboard has not been renamed yet keeps working.
  const keyId = env.OH_TURN_KEY_ID ?? env.TURN_KEY_ID;
  const token = env.OH_TURN_API_TOKEN ?? env.TURN_API_TOKEN;
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

async function turn(request, env) {
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: cors(request, {
        'access-control-allow-methods': 'POST, OPTIONS',
        'access-control-allow-headers': 'content-type',
        'access-control-max-age': '86400',
      }),
    });
  }
  if (request.method !== 'POST') return json(request, 405, { error: 'POST' }, { allow: 'POST, OPTIONS' });
  let body;
  try {
    body = await request.json();
  } catch {
    body = null;
  }
  const key = body?.key;
  if (typeof key !== 'string' || !/^[0-9a-f]{64}$/.test(key)) return json(request, 400, { error: 'a table key, 64 hex' });
  const { status, body: out } = await mint(env);
  return json(request, status, out);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/api/turn') return turn(request, env);
    if (url.pathname.startsWith('/api/')) return json(request, 404, { error: 'no such handler' });
    return env.ASSETS.fetch(request);
  },
};
