// What a tag's object keeps (docs/08-own-relays.md): the lobby kind, in
// the object's own storage, so a room, a seating or a result is still
// there when the object wakes from eviction; kept a day, the results for
// good. Apart from worker.mjs so it can be tested without the runtime.

import { memoryStore, presenceTag, resultsTag, storedKeep } from './relay.mjs';

/// How long a tag's stored events are kept, but the results', and how
/// often the sweep looks.
export const KEPT_MS = 24 * 60 * 60 * 1000;
export const SWEEP_EVERY_MS = 60 * 60 * 1000;

/// A stored event's key: by when it was made, then by id.
export const keyOf = (event) => `ev:${String(event.created_at).padStart(12, '0')}:${event.id}`;

/// [storage] is the object's (state.storage): get, put, delete, list,
/// getAlarm, setAlarm.
export function tagStore(storage, tag) {
  return {
    /// The memory store a relay for this tag starts with: what storage
    /// holds, oldest first, the newest [storedKeep] of it. Presence
    /// keeps nothing.
    async load() {
      if (tag === presenceTag) return null;
      const store = memoryStore(storedKeep(tag));
      const rows = await storage.list({ prefix: 'ev:' });
      for (const event of rows.values()) store.add(event);
      return store;
    },

    /// An event the relay stored, written down; one it let go of from
    /// memory, gone — but a result, which storage keeps for good. A
    /// sweep an hour out, for every tag but the results.
    async keep(event, gone, { now = Date.now() } = {}) {
      await storage.put(keyOf(event), event);
      if (gone && tag !== resultsTag) await storage.delete(keyOf(gone));
      if (tag !== resultsTag && (await storage.getAlarm()) === null) await storage.setAlarm(now + SWEEP_EVERY_MS);
    },

    /// What is a day old goes. True when anything went, so the relay in
    /// memory is built again; another sweep while anything is left.
    async sweep({ now = Date.now() } = {}) {
      if (tag === resultsTag || tag === presenceTag) return false;
      const before = keyOf({ created_at: Math.floor((now - KEPT_MS) / 1000), id: '' });
      const old = await storage.list({ prefix: 'ev:', end: before });
      if (old.size) await storage.delete([...old.keys()]);
      const left = await storage.list({ prefix: 'ev:', limit: 1 });
      if (left.size) await storage.setAlarm(now + SWEEP_EVERY_MS);
      return old.size > 0;
    },
  };
}
