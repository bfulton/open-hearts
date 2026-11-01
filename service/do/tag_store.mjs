// What a tag's object keeps (docs/explanation/relay.md): the lobby kind, in
// the object's own storage, so a room, a seating or a result is still
// there when the object wakes from eviction; kept a day, the results for
// good. And a table's log (referee.mjs), entry by entry as it is added,
// so a table goes on where it was after the object is evicted or
// deployed again; kept a day after its last entry, by which time every
// device that played it has kept the game it wanted (packages/table,
// record.dart). Apart from worker.mjs so it can be tested without the
// runtime.

import { memoryStore, presenceTag, resultsTag, storedKeep } from './relay.mjs';

/// How long a tag's stored events are kept, but the results', and how
/// often the sweep looks.
export const KEPT_MS = 24 * 60 * 60 * 1000;
export const SWEEP_EVERY_MS = 60 * 60 * 1000;

/// A stored event's key: by when it was made, then by id.
export const keyOf = (event) => `ev:${String(event.created_at).padStart(12, '0')}:${event.id}`;

/// A log entry's key: by its place in the log.
export const entryKey = (n) => `log:${String(n).padStart(9, '0')}`;

/// How many keys one delete is given.
const DELETE_MOST = 128;

/// [storage] is the object's (state.storage): get, put, delete, list,
/// getAlarm, setAlarm.
export function tagStore(storage, tag) {
  return {
    /// The memory store a relay for this tag starts with: the newest
    /// [storedKeep] of what storage holds, oldest first, read and no
    /// more. Presence keeps nothing.
    async load() {
      if (tag === presenceTag) return null;
      const store = memoryStore(storedKeep(tag));
      const rows = await storage.list({ prefix: 'ev:', reverse: true, limit: storedKeep(tag) });
      for (const event of [...rows.values()].reverse()) store.add(event);
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

    /// An event the relay let go of before its time, a withheld picture
    /// (withheld.mjs), gone from storage too.
    async forget(event) {
      await storage.delete(keyOf(event));
    },

    /// The table's log as written down, in order: every entry, from the
    /// first. Presence and the lobbies keep none.
    async loadLog() {
      if (tag === presenceTag || tag === resultsTag) return [];
      return [...(await storage.list({ prefix: 'log:' })).values()];
    },

    /// An entry of the table's log, written down; a sweep an hour out.
    /// What is sent after it waits for the write (the object's output
    /// gate), so nobody is told of an entry that a restart would lose.
    async keepEntry(entry, { now = Date.now() } = {}) {
      await storage.put(entryKey(entry.n), entry);
      if ((await storage.getAlarm()) === null) await storage.setAlarm(now + SWEEP_EVERY_MS);
    },

    /// What is a day old goes: stored events a day after they were made,
    /// a table's log a day after its last entry. True when anything
    /// went, so the relay in memory is built again; another sweep while
    /// anything is left.
    async sweep({ now = Date.now() } = {}) {
      if (tag === resultsTag || tag === presenceTag) return false;
      const before = keyOf({ created_at: Math.floor((now - KEPT_MS) / 1000), id: '' });
      const old = await storage.list({ prefix: 'ev:', end: before });
      if (old.size) await storage.delete([...old.keys()]);
      const last = [...(await storage.list({ prefix: 'log:', reverse: true, limit: 1 })).values()][0];
      let logGone = false;
      if (last && now - last.t >= KEPT_MS) {
        const keys = [...(await storage.list({ prefix: 'log:' })).keys()];
        for (let i = 0; i < keys.length; i += DELETE_MOST) await storage.delete(keys.slice(i, i + DELETE_MOST));
        logGone = true;
      }
      const left = (await storage.list({ prefix: 'ev:', limit: 1 })).size + (logGone || !last ? 0 : 1);
      if (left) await storage.setAlarm(now + SWEEP_EVERY_MS);
      return old.size > 0 || logGone;
    },
  };
}
