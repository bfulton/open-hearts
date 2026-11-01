// TURN for a device whose subscription stands, which is what the
// subscription pays for (worker.mjs, the turn handler): Cloudflare
// Realtime TURN credentials good for a few hours, minted from a Realtime
// TURN key — its id in config/openhearts.json (OH_TURN_KEY_ID), its
// token a project secret (OH_TURN_API_TOKEN) and never here. Without
// the secrets the handler says so (503), and the asker has no ICE
// servers. Nothing in the app asks for them yet: they are kept for the
// voice and video chat that is planned (ROADMAP.md; app/lib/net/
// turn.dart).

import { notConfigured, serviceSettings } from './settings.mjs';

const UPSTREAM = 'https://rtc.live.cloudflare.com/v1/turn/keys';

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

/// The user name and password of local mode's TURN server.
export const LOCAL_TURN = 'rig';

/// Mints credentials: the status and body to answer with.
export async function mint(env, fetchImpl = fetch) {
  const keyId = env.OH_TURN_KEY_ID;
  const token = env.OH_TURN_API_TOKEN;
  if (!keyId || !token) return { status: 503, body: notConfigured('OH_TURN_KEY_ID and OH_TURN_API_TOKEN') };
  const ttl = serviceSettings().turnTtlS;
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
