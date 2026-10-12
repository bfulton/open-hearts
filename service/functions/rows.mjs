// OH_STORE as every module reads it (storeOf), and what its rows hold:
// days, account numbers, digests and base64url.

export const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');

/// A day as the statement spells it: an ISO date, UTC.
export const dayOf = (at) => new Date(at).toISOString().slice(0, 10);

/// [days] after [at], as a day.
export const dayAfter = (at, days) => dayOf(new Date(at).getTime() + days * 86400000);

/// The earlier of two days, which is how a licence is kept inside what
/// was paid for.
export const earlier = (a, b) => (a < b ? a : b);

/// An account's id: 32 hex, random (docs/explanation/service.md).
export const isAccount = (a) => typeof a === 'string' && /^[0-9a-f]{32}$/.test(a);
export const newAccount = () => hex(crypto.getRandomValues(new Uint8Array(16)));

/// Everything the service keeps, as one key-value table
/// (docs/explanation/service.md): a lookup by key, never a scan. Cloudflare KV in
/// production; a Map stands in for the tests and for local mode.
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
    /// lives under one account: its few devices (mostDevices).
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

export async function digestOf(text) {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))));
}

export const un64 = (s) => {
  const padded = s.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(padded + '='.repeat((4 - (padded.length % 4)) % 4)), (c) => c.charCodeAt(0));
};
