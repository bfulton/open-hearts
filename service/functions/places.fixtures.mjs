// The store as two places see it, for a handler that answers from what
// an account's object has just written. KV is eventually consistent: a
// place keeps what it read of a key, a key that was not there included,
// and sees another place's write only once that has run out. An account's
// object runs where it was first asked for, and the handlers wherever
// the device is. So it went on preview pr38 (#38): a device asked for
// its licence at IAD as the app started and had none; seconds later its
// claim brought it in, through its account's object at ORD; and the
// handler, reading back at IAD what the object had written, answered
// 402, every time.

import { Household } from './household.mjs';

/// [kv], a KV binding, as one place sees it: what was read there of a
/// key is kept there for a minute, and what is written there is seen
/// there at once.
export function seenFrom(kv) {
  const kept = new Map();
  const keep = (at, raw) => kept.set(at, { raw, until: Date.now() + 60000 });
  return {
    ...kv,
    get: async (at, kind) => {
      if (!(kept.get(at)?.until > Date.now())) keep(at, await kv.get(at));
      const { raw } = kept.get(at);
      return kind === 'json' && raw !== null ? JSON.parse(raw) : raw;
    },
    put: async (at, raw, options) => {
      await kv.put(at, raw, options);
      keep(at, raw);
    },
    delete: async (at) => {
      await kv.delete(at);
      keep(at, null);
    },
  };
}

/// A HOUSEHOLD binding whose objects (household.mjs, Household) each see
/// the store as [there] does.
export function objectsAt(there) {
  const objects = new Map();
  return {
    idFromName: (name) => name,
    get(id) {
      if (!objects.has(id)) {
        const kept = new Map();
        const storage = { get: async (k) => kept.get(k), put: async (k, v) => void kept.set(k, structuredClone(v)) };
        objects.set(id, new Household({ storage }, { OH_STORE: there }));
      }
      return { fetch: (url, init) => objects.get(id).fetch(new Request(url, init)) };
    },
  };
}
