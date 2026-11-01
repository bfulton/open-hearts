// A table's referee: the one place its events are put in order
// (packages/table, log.dart; docs/explanation/live-play.md).
//
// A table's tag is a relay of its own (worker.mjs), and on it the
// referee keeps the table's log: every event a seat or the house sends
// it, numbered in the order it came and stamped with this clock; a
// seat's last connection to the log closing, and its first opening
// again; and the time, when a side asks for it because a deadline is
// due. It sees no cards and decides nothing. Every side runs the same
// rules over the same entries (packages/table, rules.dart), so they all
// come to the same table — and anybody checking the game later comes
// there too, from the log alone.
//
// What it checks is what it takes: the first start that names this
// table and is said by one of its people, naming this relay's house if
// it names one, and after that events from the start's people and its
// house alone, each once. Every event's id must be the hash of its
// canonical bytes (packages/table, events.dart, as
// functions/records.mjs, eventIdOf, makes them) and carry its author's
// signature. So an id stands for one event only, and nobody can keep
// another's event out of the log by saying its id first. An event the
// rules do not read, of a kind or shape this build does not know, is
// logged as it came and changes nothing, at every side alike (log.dart,
// LogEntry.unread).
//
// Each person's events may fill only so much of the log ([authorMost]),
// so one seat cannot grow the table's object until it fails for
// everybody, nor make every side that reads the log read without end.
//
// But for the start, which every side has to read as the same table
// for anything after it to mean anything: a log that began with one
// they could not would be no table at all, for any of them. So the
// start is taken only as Dart wrote it (startRefusal): its text as it
// comes out written again, and its spec the one the table's id names
// (packages/table, spec.dart, TableSpec.id). The table is the one
// everybody was seated at, and one person cannot start it as another.
//
// The simulator's referee (packages/table_sim, sim_referee.dart) is
// this, on the simulator's clock: a table played there is a table played
// here.

import { eventIdOf, recordMost } from '../functions/records.mjs';

/// The kind a table event rides in: its JSON as the content, signed by
/// its author (packages/table, nostr.dart, TableKinds.log).
export const logKind = 4250;

/// The least time between ticks: a side asks once a second while a
/// deadline it is waiting on has not moved the table, and every side
/// waiting on it asks at once.
export const tickGapMs = 250;

/// A table's tag (packages/table, spec.dart, newTableId): the only tags
/// that keep a log.
export const tableTag = /^[0-9a-f]{32}$/;

/// The most of a table's log one person's events may fill, in
/// characters as the log keeps them: as much as a whole kept game may be
/// ([recordMost]). A person's share of a game to a hundred is some
/// 400 KiB: the game in packages/table/test/fixtures/refereed_four.json.gz
/// holds about 72 KiB of each person's over three hands, and no game to
/// a hundred lasts more than sixteen. The house deals and plays every bot
/// seat, and its key is the operator's, so it is not held to this.
export const authorMost = recordMost;

const hex64 = /^[0-9a-f]{64}$/;

/// How often one table wakes its house: as the table starts, and then
/// while the house is away, at most this often.
export const wakeEveryMs = 20 * 1000;

/// [fn] in [ms], on a timer that does not hold a node process open.
function unheld(fn, ms) {
  const timer = setTimeout(fn, ms);
  timer?.unref?.();
  return timer;
}

/// A table's wakes of its house, at most one every [everyMs]: [wake]
/// wakes it. One wanted sooner is made when the time is up, not dropped,
/// if [stillWanted] says it still is then — the house's socket closing
/// just after the table started is a wake wanted then, and the next
/// entry may be the house's turn running out.
export function wakeLimiter({ wake, stillWanted, everyMs = wakeEveryMs, now = Date.now, later = unheld }) {
  let wokeAt = -Infinity;
  let pending = null;
  const want = () => {
    const t = now();
    if (t - wokeAt >= everyMs) {
      wokeAt = t;
      wake();
      return;
    }
    pending ??= later(async () => {
      pending = null;
      if (await stillWanted()) want();
    }, wokeAt + everyMs - t);
  };
  return want;
}

/// Who may write to the log a start's [spec] begins, for [table] at a
/// relay whose house is [house]: its people, and its house. Null for a
/// spec this referee does not begin a log with — another table's, one
/// without four seats or without a person, one naming a house that is
/// not this relay's, or a sealed one naming none, whose deal no house
/// would hold.
export function writersOf(spec, table, house) {
  if (!spec || typeof spec !== 'object' || Array.isArray(spec) || spec.id !== table) return null;
  if (!Array.isArray(spec.seats) || spec.seats.length !== 4) return null;
  const people = new Set();
  for (const seat of spec.seats) {
    if (seat && typeof seat === 'object' && typeof seat.key === 'string' && hex64.test(seat.key)) people.add(seat.key);
    else if (!(seat && typeof seat === 'object' && typeof seat.bot === 'string')) return null;
  }
  if (!people.size) return null;
  const named = spec.house ?? null;
  if (named !== null && (typeof named !== 'string' || named !== house)) return null;
  if (spec.sealed === true && named === null) return null;
  return { people, house: named, writers: new Set(named ? [...people, named] : people) };
}

/// SHA-256 of [text], in hex.
async function sha256Hex(text) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/// The id of the table [spec] names: the first 32 hex digits of the
/// SHA-256 of all it says but its id, as it is written (packages/table,
/// spec.dart, TableSpec.idOf).
export async function specIdOf(spec) {
  const { id, ...written } = spec;
  return (await sha256Hex(JSON.stringify(written))).slice(0, 32);
}

/// Why [content], a [logKind] event's text, is no start for the log of
/// [table] to begin with; null for one that is, or for content that is
/// no start at all. A start is taken as Dart wrote it and every side
/// reads it: its text as it comes out written again, so that the bytes
/// hashed here are the bytes hashed there; saying a spec and nothing
/// else, its id first; and that spec the one [table] names. Its id is
/// checked as every event's is ([tableReferee], take).
export async function startRefusal(content, table) {
  let said;
  try {
    said = JSON.parse(content);
  } catch {
    return null;
  }
  if (!said || typeof said !== 'object' || said.kind !== 'start') return null;
  if (JSON.stringify(said) !== content) return 'invalid: a start is taken as it was written';
  const { body } = said;
  const spec = body && typeof body === 'object' && !Array.isArray(body) ? body.spec : null;
  if (Object.keys(body ?? {}).length !== 1 || !spec || typeof spec !== 'object' || Array.isArray(spec) || Object.keys(spec)[0] !== 'id') {
    return 'invalid: a start says its spec and nothing else';
  }
  if (spec.id !== table || (await specIdOf(spec)) !== table) return 'blocked: not the table this id names';
  return null;
}

/// The table event a [logKind] event carries, the fields a table event
/// has and nothing else; null for content that is not one.
function eventIn(content) {
  let said;
  try {
    said = JSON.parse(content);
  } catch {
    return null;
  }
  if (!said || typeof said !== 'object' || Array.isArray(said)) return null;
  const { id, table, author, kind, body, sig } = said;
  if (typeof id !== 'string' || !hex64.test(id) || typeof author !== 'string' || !hex64.test(author) || typeof sig !== 'string') return null;
  return { id, table, author, kind, body, sig };
}

/// The referee of [table]. [verify] checks a signature over an id;
/// [house] is this relay's house key, or null for none; [entries] is the
/// log as kept, from the first entry, which the referee goes on from;
/// [keep] is told of each entry as it is added, to write it down;
/// [wanted] is told whenever the house is wanted and is not on the log
/// — a start that names it, and every entry after while it is away,
/// until its word on how the game came out is in; [send] sends text to
/// a socket, [admitted] says whether a socket may be carried now.
export function tableReferee({ table, verify, house = null, now = Date.now, entries: kept = [], keep = null, wanted = null, send = () => {}, admitted = () => true }) {
  const entries = [];
  /// The start's writers ([writersOf]), once there is a start.
  let spec = null;
  /// Every event id in the log.
  const ids = new Set();
  /// socket -> {sub, key}: who follows the log, under which
  /// subscription, and the key it answered the relay's challenge with.
  const listeners = new Map();
  /// key -> how many of its sockets follow the log.
  const open = new Map();
  /// The writers whose last connection's close is the last thing the
  /// log says of them.
  const downLogged = new Set();
  /// Whether the house's word on the game is in.
  let said = false;
  /// author -> how many characters of the log its events fill.
  const filled = new Map();

  const lastAt = () => (entries.length ? entries[entries.length - 1].t : -Infinity);

  /// [entry] as the log it is in has it, noted.
  function note(entry) {
    entries.push(entry);
    const e = entry.e;
    if (e) {
      ids.add(e.id);
      filled.set(e.author, (filled.get(e.author) ?? 0) + JSON.stringify(e).length);
      if (entry.n === 0) spec = writersOf(e.body?.spec, table, house);
      if (e.kind === 'result' && spec?.house && e.author === spec.house) said = true;
    }
    if (entry.up) downLogged.delete(entry.up);
    if (entry.down) downLogged.add(entry.down);
  }

  // The log as kept, as far as it runs on without a gap.
  for (const entry of kept) {
    if (!entry || entry.n !== entries.length) break;
    note(entry);
  }

  const houseHere = () => !!spec?.house && (open.get(spec.house) ?? 0) > 0;

  /// Whether the table wants its house and the house is not on the log:
  /// a sealed table whose house has not said its word.
  const wantsHouse = () => !!spec?.house && !said && !houseHere();

  /// One more entry: numbered, stamped, written down, and sent to
  /// everyone following the log.
  function append(fields) {
    // This clock as the log has it: never before the entry before.
    const entry = { n: entries.length, t: Math.max(now(), lastAt()), ...fields };
    note(entry);
    keep?.(entry);
    const text = `,${JSON.stringify(entry)}]`;
    for (const [socket, l] of listeners) {
      if (admitted(socket)) send(socket, `["LOG",${JSON.stringify(l.sub)}${text}`);
    }
    if (wantsHouse()) wanted?.();
    return entry;
  }

  /// [socket], answered as [key], following the log one more time.
  function opened(key) {
    if (!key) return;
    const count = (open.get(key) ?? 0) + 1;
    open.set(key, count);
    if (count === 1 && downLogged.has(key)) append({ up: key });
  }

  return {
    /// The log as it stands.
    get entries() {
      return entries;
    },

    /// Whether the table wants its house and the house is not there.
    get wantsHouse() {
      return wantsHouse();
    },

    /// Whether [key] holds a seat in person, by the table's start: null
    /// while the log has not begun.
    seated(key) {
      return spec ? spec.people.has(key) : null;
    },

    /// A [logKind] event, its own id and signature already checked:
    /// {ok, why}, as the relay answers it. Waits on the hash of the
    /// table event it carries, and on a start's checks while the log has
    /// not begun; what it decides after each wait is decided on the log
    /// as it stands then.
    async take(event) {
      const e = eventIn(event.content);
      if (!e) return { ok: false, why: 'invalid: not a table event' };
      if (e.table !== table) return { ok: false, why: `blocked: this log is table ${table}'s` };
      if (event.pubkey !== e.author) return { ok: false, why: 'blocked: a table event is said by its author' };
      if ((await eventIdOf(table, e)) !== e.id) return { ok: false, why: 'invalid: an event\'s id is the hash of what it says' };
      if (ids.has(e.id)) return { ok: true, why: 'duplicate: already in the log' };
      if (!verify(e.author, e.id, e.sig)) return { ok: false, why: 'invalid: not signed by its author' };
      if (!entries.length) {
        if (e.kind !== 'start') return { ok: false, why: 'blocked: the log begins with the table\'s start' };
        const writers = writersOf(e.body?.spec, table, house);
        if (!writers) return { ok: false, why: 'blocked: not a table this relay referees' };
        if (!writers.people.has(e.author)) return { ok: false, why: 'blocked: a table is started by one of its people' };
        const refused = await startRefusal(event.content, table);
        if (refused) return { ok: false, why: refused };
        // Another start may have begun the log meanwhile: the same
        // table, since only one spec is this table's.
        if (entries.length) return { ok: true, why: 'duplicate: the table has started' };
        append({ e });
        return { ok: true, why: '' };
      }
      if (e.kind === 'start') return { ok: true, why: 'duplicate: the table has started' };
      if (!spec?.writers.has(e.author)) return { ok: false, why: 'blocked: not one of the table\'s people or its house' };
      if (e.author !== spec.house && (filled.get(e.author) ?? 0) + JSON.stringify(e).length > authorMost) {
        return { ok: false, why: 'blocked: this author has filled its share of the log' };
      }
      append({ e });
      return { ok: true, why: '' };
    },

    /// [socket] asking for the log from entry [from] under [sub], having
    /// answered the relay's challenge as [key]: everything from there,
    /// the end of it, and then each entry as it is added. A key's first
    /// socket on the log, after its last had closed, is noted first.
    follow(socket, sub, from, key = null) {
      const was = listeners.get(socket);
      if (!was) opened(key);
      listeners.set(socket, { sub, key: was ? was.key : key });
      for (let n = from; n < entries.length; n++) send(socket, `["LOG",${JSON.stringify(sub)},${JSON.stringify(entries[n])}]`);
      send(socket, JSON.stringify(['LOGEND', sub, entries.length]));
    },

    /// [socket] following the log under [sub] as it was before the
    /// object slept: nothing noted, since nothing changed.
    resume(socket, sub, key = null) {
      if (listeners.has(socket)) return;
      listeners.set(socket, { sub, key });
      if (key) open.set(key, (open.get(key) ?? 0) + 1);
    },

    /// The sockets handed back are all there are: a writer with none,
    /// the log last saying it was there, was cut off while the object
    /// was gone — evicted, or deployed again — and it is noted as gone.
    settle() {
      if (!spec) return;
      for (const key of spec.writers) {
        if ((open.get(key) ?? 0) === 0 && !downLogged.has(key)) append({ down: key });
      }
      if (wantsHouse()) wanted?.();
    },

    /// [socket] no longer following the log: closed, or its
    /// subscription closed under [sub] (any, when null). A writer's last
    /// is noted.
    unfollow(socket, sub = null) {
      const l = listeners.get(socket);
      if (!l || (sub !== null && l.sub !== sub)) return;
      listeners.delete(socket);
      if (!l.key) return;
      const left = (open.get(l.key) ?? 1) - 1;
      if (left > 0) return open.set(l.key, left);
      open.delete(l.key);
      if (spec?.writers.has(l.key) && !downLogged.has(l.key)) append({ down: l.key });
    },

    /// The subscription [socket] follows the log under, for it to carry
    /// through hibernation, or null.
    followed(socket) {
      return listeners.get(socket)?.sub ?? null;
    },

    /// A tick, if the log has begun and its last entry is [tickGapMs] old.
    tick() {
      if (!entries.length || now() - lastAt() < tickGapMs) return null;
      return append({});
    },
  };
}
