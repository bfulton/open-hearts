// Games kept for looking at afterwards (app/lib/router.dart,
// /table/<id> on play.openhearts.game): a finished game's whole record, as one of its
// players' devices sends it, kept in R2 (OH_RECORDS) under the table's
// id, packed.
//
// Nothing here replays a record. Every event in it is signed, the
// house's word on the end names the log as it stood, and whoever looks
// at one replays it through the verifier — every signature, every step
// of the deal — before showing a card of it (packages/table,
// record.dart). What is checked here is what decides whose copy is
// kept: the sender is a subscriber's device in use (worker.mjs,
// recordRoute), a seat at the table, and has signed moves of its own at
// this table into it — an event of the log whose author is the sender,
// whose id is the hash of its own content, and whose signature checks.
// A record made up by somebody who never played there has none, and
// neither has a copy of somebody else's game with one's key written
// into a seat. And its seats are ones the app would show: each person's
// carries the service's licence for its key (licenceProblem), which is
// what ties a name beside the record to an account, for forgetting one.
//
// Which copy is kept is the one that carries the house's checked result
// (vouches), marked `vouched` beside it in R2. The first copy is kept
// while none is vouched: a game that failed has no result, and a log
// that holds an event this build does not read is not checked this far,
// so those copies stay as they were first come. But a copy any seat can
// make before the game is over (a log cut short, which nobody can open)
// is never kept in the way of the whole game: a vouched copy replaces an
// unvouched one, and nothing replaces a vouched one. The replacement is
// made on the etag of the copy that was read, so two devices sending at
// once cannot put one over the other unseen.
//
// A name beside a record is unsigned, so it is kept from nobody but its
// own seat: the sender's own seat's name is kept from each copy, and
// every other seat's is left to that seat's own device, which merges it
// in when it sends (mergedInto). Until it has, a seat shows what the app
// shows for a seat with no name.

import { nameRefused } from './names.mjs';
import { PROFILE_NAME_MOST } from './profile.mjs';
import { dayOf, digestOf, isAccount, licenceStatement } from './rows.mjs';

/// A table's id (packages/table, spec.dart, newTableId).
export const tableIdShape = /^[0-9a-f]{32}$/;

/// The most a record may be, unpacked: room over a full sealed game to
/// a hundred (docs/explanation/live-play.md), and a bound on what a
/// device can make the bucket hold.
export const recordMost = 2 * 1024 * 1024;

/// The form of record kept (packages/table, record.dart,
/// GameRecord.version): the table's spec and its referee's log, every
/// entry as it came. Games kept in the forms before the referee stay as
/// they were (legacy/v2_record.dart there); none is kept in them now.
export const recordVersion = 3;

const keyIn = (table) => `tables/${table}.json`;

/// Where an account forgotten on request is marked in the bucket
/// (`oh account delete`, service/tool/forget.mjs, writes it): a game kept after the mark is
/// kept without the account's name. R2 reads what was last written, so
/// a record checked after the mark is in sees it.
export const forgottenKey = (account) => `forgotten/${account}`;

/// [account] marked forgotten in [binding], OH_RECORDS as the worker
/// reaches it, for an account deleted from the app (worker.mjs,
/// deleteRoute), as `oh account delete` marks one.
export async function markForgotten(binding, account, { now = Date.now() } = {}) {
  if (await binding.head(forgottenKey(account))) return;
  await binding.put(forgottenKey(account), JSON.stringify({ forgotten: dayOf(now) }), { httpMetadata: { contentType: 'application/json' } });
}

/// The id an event of [table] has: the hash of what it says, as the
/// table writes it (packages/table, events.dart, `_canonical`): every
/// object's keys in order, at every depth.
export async function eventIdOf(table, event) {
  return digestOf(inOrder([table, event.author, event.kind, event.body]));
}

/// [json] written out with every object's keys in order at every depth,
/// as Dart writes an event for its id (packages/table, events.dart,
/// _canonical). Written here a key at a time, not by JSON.stringify of
/// an object built in that order: an object puts a key like "2" ahead of
/// every other, whatever order it is given its keys in.
function inOrder(json) {
  if (Array.isArray(json)) return `[${json.map(inOrder).join(',')}]`;
  if (json === null || typeof json !== 'object') return JSON.stringify(json);
  const keys = Object.keys(json).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${keys.map((k) => `${JSON.stringify(k)}:${inOrder(json[k])}`).join(',')}}`;
}

/// Why [seats] are not seats the app would show, or null: every
/// person's seat carries a licence the service ([service], its public
/// key) signed for the seat's key, and no account sits twice, as the
/// app checks a record before showing it (packages/table, spec.dart,
/// licenceProblem). Not the licence's date: a record is read long after
/// it ran out. [verify] writes what it is given into fixed buffers, so
/// a signature is held to its shape first.
async function licenceProblem(seats, service, verify) {
  const seated = new Set();
  for (const [s, seat] of seats.entries()) {
    if (typeof seat?.bot === 'string') continue;
    const { key, account, until, plan, sig } = seat?.licence ?? {};
    const shaped = key === seat?.key && [key, account, until, plan].every((v) => typeof v === 'string' && !v.includes('\n')) && /^[0-9a-f]{128}$/.test(sig ?? '');
    if (!shaped || !verify(service, await digestOf(licenceStatement(key, account, until, plan)), sig)) return `seat ${s} has no licence for its key`;
    if (seated.has(account)) return `seat ${s} is an account already seated`;
    seated.add(account);
  }
  return null;
}

/// How many of the sender's own events are looked at before giving up:
/// any one that checks is enough, and a record is mostly the sender's.
const triedAtMost = 8;

/// Whether [record]'s log holds an event [key] signed at [table].
/// [verify] is the service's BIP-340 check (licence.mjs, signerOn).
async function signedInto(record, key, table, verify) {
  let tried = 0;
  for (const entry of record.log) {
    const e = entry?.e;
    if (e?.author !== key || typeof e.id !== 'string' || typeof e.sig !== 'string' || typeof e.kind !== 'string') continue;
    if (!e.body || typeof e.body !== 'object' || Array.isArray(e.body)) continue;
    if (tried++ >= triedAtMost) return false;
    if ((await eventIdOf(table, e)) === e.id && /^[0-9a-f]{128}$/.test(e.sig) && verify(key, e.id, e.sig)) return true;
  }
  return false;
}

// ---- the house's checked result ------------------------------------------

const is64 = (v) => typeof v === 'string' && /^[0-9a-f]{64}$/.test(v);
const is128 = (v) => typeof v === 'string' && /^[0-9a-f]{128}$/.test(v);
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = Number.isSafeInteger;

/// What a record, an entry of its log and an event of one have, and no
/// more: the keys the app writes (packages/table, record.dart, log.dart,
/// events.dart), which the referee writes an entry with, and takes an
/// event with (service/do/referee.mjs). A copy that carries more carries
/// what nothing vouches for.
const recordKeys = new Set(['v', 'spec', 'log', 'names']);
const entryKeys = new Set(['n', 't', 'e', 'up', 'down']);
const eventKeys = ['author', 'body', 'id', 'kind', 'sig', 'table'];

/// How deep an event may nest, counting itself: the referee takes none
/// deeper, and no side reads one (events.dart, TableEvent.deepest;
/// service/do/referee.mjs, deepest).
const deepest = 32;

/// Whether [value] nests no deeper than [deepest], counted without
/// recursion.
function shallow(value) {
  const stack = [[value, 1]];
  while (stack.length) {
    const [v, depth] = stack.pop();
    if (!v || typeof v !== 'object') continue;
    if (depth > deepest) return false;
    for (const child of Object.values(v)) stack.push([child, depth + 1]);
  }
  return true;
}

/// Whether [body] is a result as the table reads one (packages/table,
/// events.dart, TableEvent.wellFormed, EventKind.result): the house's
/// word is taken from no other.
const resultReads = (body) =>
  isInt(body.n) && typeof body.hash === 'string' && typeof body.state === 'string' && Array.isArray(body.totals) && body.totals.every(isInt);

/// What an entry adds to the log's running hash (packages/table, log.dart,
/// LogEntry.digestInput): an event by its id, a connection by its key, a
/// tick by nothing.
export function digestInput({ n, t, e, up, down }) {
  if (e != null) return `${n}|${t}|e|${e.id}`;
  if (up != null) return `${n}|${t}|up|${up}`;
  if (down != null) return `${n}|${t}|down|${down}`;
  return `${n}|${t}|tick`;
}

/// The log's running hash (log.dart, LogHash) after none of its entries,
/// then after each of the first [count] in turn: each entry folded into
/// the one before. The house signs it with the game's result, so a log
/// kept afterwards is the one the referee gave, entry for entry, or it
/// does not check. A test holds this to Dart's, on one file of cases
/// both read (packages/table/test/log_hash.vectors.json).
export async function logHashes(log, count = log.length) {
  const hashes = [await digestOf('open-hearts/log/1')];
  for (const entry of log.slice(0, count)) hashes.push(await digestOf(`${hashes.at(-1)}|${digestInput(entry)}`));
  return hashes;
}

/// Whether [text] is how the app writes [record] but for the names, which
/// come last and are never copied from it: everything else as JSON.stringify
/// writes it, so that it can be written again with other names beside
/// it and every event still read as it was sent. An event's id is a
/// digest of its body as its reader parses it, and a number written
/// another way can parse to another value (Dart reads 2.0 and 2 apart).
function writtenAsSent(record, text) {
  const body = text.trim();
  const { names: _, ...rest } = record;
  const written = JSON.stringify(rest);
  return Object.hasOwn(record, 'names') ? body.startsWith(`${written.slice(0, -1)},"names":`) && body.endsWith('}') : body === written;
}

/// [record] with [names] beside its seats, or none if there are none.
function withNames(record, names) {
  const { names: _, ...rest } = record;
  return Object.keys(names).length ? { ...rest, names } : rest;
}

/// Whether [record], sent as [text] for [table], carries the house's
/// checked result: the log is the one the house signed for, whole as far
/// as the house saw it, and nothing in it is more than the referee took.
///
///  - the record is how the app writes one, nothing in it but what it
///    writes, and its spec is the one the log's start says;
///  - every entry is numbered by where it is, and holds at most one of an
///    event, a connection opening and one closing;
///  - every event is shaped as the referee takes one (service/do/referee.mjs,
///    eventIn, take): table [table]'s, from one of the table's writers (its
///    people and its house), the keys of an event and no more, not nested
///    deeper than any is, its id the hash of what it says and its
///    signature on the id checking. Whether the table reads it is not
///    asked: an event of a kind it does not know, or of a body none of
///    its kind has, is an entry every side skips (log.dart, LogEntry.unread;
///    kept_records_test.dart holds that such a record opens), and its id
///    is in the hash like any;
///  - a result by the table's house, the house this service has
///    ([house], OH_HOUSE_KEY), is among them, naming no more of the log
///    than came before it, and the hash of that many entries is the hash
///    it names (logHashes).
///
/// A game with no result in it (one that failed) is not this, and stays
/// as it comes.
async function vouches(record, text, table, house, verify) {
  const { spec, log } = record;
  if (!is64(house) || spec.house !== house) return false;
  if (!Object.keys(record).every((k) => recordKeys.has(k)) || !shallow(spec) || !writtenAsSent(record, text)) return false;
  const writers = new Set([house, ...spec.seats.flatMap((seat) => (is64(seat?.key) ? [seat.key] : []))]);
  const results = [];
  for (const [i, entry] of log.entries()) {
    if (!isObject(entry) || !Object.keys(entry).every((k) => entryKeys.has(k)) || entry.n !== i || !isInt(entry.t)) return false;
    const { e, up, down } = entry;
    if ([e, up, down].filter((x) => x != null).length > 1) return false;
    if ((up != null && !is64(up)) || (down != null && !is64(down))) return false;
    if (e == null) continue;
    if (!isObject(e) || Object.keys(e).sort().join() !== eventKeys.join() || !shallow(e)) return false;
    if (!is128(e.sig) || e.table !== table || !writers.has(e.author)) return false;
    if (e.kind === 'result' && e.author === house && isObject(e.body) && resultReads(e.body) && e.body.n <= i) results.push(e);
  }
  // The log starts the table the record says, as a verifier holds it to.
  const start = log[0]?.e;
  if (start?.kind !== 'start' || inOrder(start.body?.spec) !== inOrder(spec)) return false;
  if (!results.length) return false;
  const hashes = await logHashes(log, Math.max(...results.map((e) => e.body.n)));
  if (!results.some((e) => hashes[e.body.n] === e.body.hash)) return false;
  // The work: left to the last, since a log that is not the house's has
  // failed by now.
  for (const { e } of log) {
    if (e != null && ((await eventIdOf(table, e)) !== e.id || !verify(e.author, e.id, e.sig))) return false;
  }
  return true;
}

// ---- keeping a record -----------------------------------------------------

/// How many times a copy is tried against the one kept, which another
/// device may change between reading it and writing: devices of one
/// table send at about the same time, and no more than four of them are
/// at it.
const triesMost = 5;

/// Keeps [text], a record [key] sent for [table]: {status, body}. The copy
/// carrying the house's checked result is the one kept (vouches): the
/// first, if none is kept; in the place of one kept that does not, which
/// is how a stub of the game is not in the way of the game; and not at
/// all if the one kept does. What is left of a copy that is not kept is
/// its sender's own name, which goes in beside the one that is (mergedInto).
/// What is kept of the names is the sender's own seat's, and not the name
/// of any account forgotten on request or any the filter refuses (ownNames).
/// [verify] checks a signature: (key, digest, signature) => bool.
/// [service] is the service's public key where it signs licences
/// (licence.mjs, serviceKeys), and then every person's seat must carry
/// one (licenceProblem); where it signs none, nothing is checked, as
/// in an app built without one (licence.dart, licencesChecked).
/// [house] is the house's public key (OH_HOUSE_KEY): without one no copy
/// is vouched, and the first is kept.
export async function keepRecord(bucket, key, table, text, { verify, service = null, house = null }) {
  if (!bucket) return { status: 503, body: { error: 'records are not kept here' } };
  if (typeof table !== 'string' || !tableIdShape.test(table)) return { status: 400, body: { error: 'a table id, 32 hex' } };
  if (typeof text !== 'string' || text.length > recordMost) return { status: 413, body: { error: 'not a record this size' } };
  let record;
  try {
    record = JSON.parse(text);
  } catch {
    return { status: 400, body: { error: 'not a record' } };
  }
  if (record?.v !== recordVersion) return { status: 400, body: { error: `a record of form ${recordVersion}` } };
  const spec = record?.spec;
  if (spec?.id !== table || !Array.isArray(spec?.seats) || !Array.isArray(record?.log)) {
    return { status: 400, body: { error: 'not this table\'s record' } };
  }
  // A name beside each seat at most, which the app only ever puts there.
  const { names } = record;
  if (names !== undefined && (names === null || typeof names !== 'object' || Array.isArray(names) || Object.keys(names).length > spec.seats.length)) {
    return { status: 400, body: { error: 'not a record' } };
  }
  if (!spec.seats.some((s) => s?.key === key)) return { status: 403, body: { error: 'only a player at the table sends its record' } };
  if (!(await signedInto(record, key, table, verify))) {
    return { status: 403, body: { error: 'a record with none of your own moves in it' } };
  }
  const unlicensed = service ? await licenceProblem(spec.seats, service, verify) : null;
  if (unlicensed) return { status: 403, body: { error: unlicensed } };

  const mine = await ownNames(bucket, record, key);
  // Worked out once, and only if it decides anything: a copy is not
  // looked at so far when the one kept already carries the house's word.
  let vouched;
  const vouchedCopy = async () => {
    if (vouched === undefined) {
      try {
        vouched = await vouches(record, text, table, house, verify);
      } catch {
        // A record too deep to read is not one.
        vouched = false;
      }
    }
    return vouched;
  };
  /// This copy written, on the condition [onlyIf]: whether it was, or
  /// null for a copy that cannot be kept.
  const write = async (onlyIf) => {
    const kept = asKept(record, text, mine);
    if (kept === null) return null;
    const put = await bucket.put(keyIn(table), await packed(kept), {
      httpMetadata: KEPT_AS,
      customMetadata: { from: key, accounts: seatedAccounts(record).join(','), ...((await vouchedCopy()) ? { vouched: '1' } : {}) },
      onlyIf,
    });
    return !!put;
  };
  for (let tries = 0; tries < triesMost; tries++) {
    const there = await bucket.head(keyIn(table));
    let written;
    if (!there) {
      // Kept only if none is by the time it is written: if another device
      // has kept one first, the next try finds it.
      written = await write({ etagDoesNotMatch: '*' });
    } else if (there.customMetadata?.vouched === '1' || !(await vouchedCopy())) {
      if ((await mergedInto(bucket, table, key, record, mine)) === 'again') continue;
      return { status: 200, body: { kept: true, already: true } };
    } else {
      written = await write({ etagMatches: there.etag });
    }
    if (written === null) return { status: 422, body: { error: 'a record that cannot be kept without the names taken out of it' } };
    if (written) return { status: 200, body: { kept: true } };
  }
  return { status: 409, body: { error: 'the record changed while it was being kept' } };
}

/// How a record is kept: gzipped, and said so.
const KEPT_AS = Object.freeze({ contentType: 'application/json', contentEncoding: 'gzip' });
const packed = (text) => new Response(new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer();
const unpacked = (body) => new Response(body.pipeThrough(new DecompressionStream('gzip'))).text();

/// What [record] says the seats [key] holds are called, of the names that
/// may be kept beside them: {seat: name}. Not a name that could not be a
/// person's beside its seat ([nameFits]), nor one the filter refuses, nor
/// the name of an account forgotten on request, which is marked in
/// [bucket]: a game a forgotten account's last licence let it finish is
/// sent after the mark is in.
async function ownNames(bucket, record, key) {
  const own = {};
  for (const [s, seat] of record.spec.seats.entries()) {
    const name = record.names?.[s];
    if (seat?.key !== key || !nameFits(record.spec.seats, String(s), name) || nameRefused(name)) continue;
    if (isAccount(seat.licence?.account) && (await bucket.head(forgottenKey(seat.licence.account)))) continue;
    own[s] = name;
  }
  return own;
}

/// [text], the record sent, as it is to be kept: with the sender's own
/// seat's name beside it, [mine], and no other's. As it was sent, byte for
/// byte, if that is what it has; otherwise rewritten, if the rest of it
/// is as JSON.stringify writes it ([writtenAsSent]); null when it is not.
function asKept(record, text, mine) {
  const sent = record.names ?? {};
  const same = Object.keys(sent).length === Object.keys(mine).length && Object.entries(mine).every(([s, name]) => sent[s] === name);
  if (same) return text;
  return writtenAsSent(record, text) ? JSON.stringify(withNames(record, mine)) : null;
}

/// The sender's own name, [mine] from the record it sent, put beside the
/// seat it holds in the record kept for [table]: 'done', or 'again' when
/// the record kept changed after it was read, which is not written over
/// (the write is on the etag read). A name is the sender's alone to say,
/// at the seat that holds its key in the record kept, and is left out
/// where that record cannot be written as it was kept (writtenAsSent),
/// or is not of this form.
async function mergedInto(bucket, table, key, record, mine) {
  if (!Object.keys(mine).length) return 'done';
  const got = await bucket.get(keyIn(table));
  if (!got) return 'again';
  const text = await unpacked(got.body);
  let kept;
  try {
    kept = JSON.parse(text);
  } catch {
    return 'done';
  }
  const seats = kept?.v === recordVersion ? kept.spec?.seats : null;
  if (!Array.isArray(seats)) return 'done';
  const was = isObject(kept.names) ? kept.names : {};
  const names = { ...was };
  for (const [s, name] of Object.entries(mine)) {
    const account = seats[s]?.licence?.account;
    if (seats[s]?.key !== key) continue;
    if (isAccount(account) && (await bucket.head(forgottenKey(account)))) continue;
    names[s] = name;
  }
  if (Object.keys(names).length === Object.keys(was).length && Object.entries(names).every(([s, name]) => was[s] === name)) return 'done';
  if (!writtenAsSent(kept, text)) return 'done';
  const put = await bucket.put(keyIn(table), await packed(JSON.stringify(withNames(kept, names))), {
    httpMetadata: KEPT_AS,
    customMetadata: got.customMetadata,
    onlyIf: { etagMatches: got.etag },
  });
  return put ? 'done' : 'again';
}

/// The accounts whose licences sit at [record]'s seats, each once: what
/// a kept game notes beside it (`accounts`, comma-separated), so that
/// one account's games are found without reading every game
/// (anonymizeGames).
function seatedAccounts(record) {
  return [...new Set(record.spec.seats.map((s) => s?.licence?.account).filter(isAccount))];
}

/// Thrown for a kept record that JSON.stringify would not write back as
/// it was sent: an event's id is a digest of its body as its reader
/// parses it, and a number written another way can parse to another
/// value (Dart reads 2.0 and 2 apart). Such a record is never rewritten.
export class NotAsSent extends Error {
  constructor(key) {
    super(`${key} would not be written back as it was sent`);
    this.key = key;
  }
}

/// OH_RECORDS, an R2 binding, behind the calls anonymizeGames makes, as
/// the worker reaches it: the kept games listed with the accounts noted
/// beside each (null for a game kept before they were), and a record
/// read and written as its JSON, kept as keepRecord keeps it, with what
/// was noted beside it.
export function keptGames(binding) {
  const noted = new Map();
  return {
    async list(prefix) {
      const found = [];
      let cursor;
      do {
        const page = await binding.list({ prefix, cursor, include: ['customMetadata'] });
        for (const o of page.objects) {
          const accounts = o.customMetadata?.accounts;
          found.push({ key: o.key, accounts: typeof accounts === 'string' ? accounts.split(',').filter(Boolean) : null });
        }
        cursor = page.truncated ? page.cursor : undefined;
      } while (cursor);
      return found;
    },
    async get(key) {
      const kept = await binding.get(key);
      if (!kept) return null;
      const text = await unpacked(kept.body);
      const record = JSON.parse(text);
      if (JSON.stringify(record) !== text) throw new NotAsSent(key);
      noted.set(key, kept.customMetadata ?? {});
      return record;
    },
    async put(key, record) {
      await binding.put(key, await packed(JSON.stringify(record)), {
        httpMetadata: KEPT_AS,
        customMetadata: { ...noted.get(key), accounts: seatedAccounts(record).join(',') },
      });
    },
  };
}

/// Whether [name], beside [seat], could be a person's name there: a
/// person's seat, and a name as a profile holds one (profile.mjs). The
/// app copies its peers' names as they said them, so a modified peer's
/// name of any length can be in an honest player's record; it is taken
/// off, as a refused name is, before the filter is run over it.
function nameFits(seats, seat, name) {
  const at = /^\d+$/.test(seat) ? seats[Number(seat)] : undefined;
  return !!at && typeof at.bot !== 'string' && typeof name === 'string' && [...name].length <= PROFILE_NAME_MOST && !/\p{Cc}/u.test(name);
}

/// [record] with the names of the seats [account] sat in taken out:
/// {record, named}, where [named] are the seats whose name went, or
/// null when the account sat in none. A seat is the account's when its
/// licence names it: every person's seat in a kept game has one
/// (licenceProblem). The names are kept beside the record unsigned, as
/// each device said it was called, so the record verifies as before and
/// stays the other players' game, with no name on those seats.
export function withoutNames(record, account) {
  const seats = (record?.spec?.seats ?? []).flatMap((seat, i) => (seat?.licence && seat.licence.account === account ? [i] : []));
  if (!seats.length) return null;
  const { names: was, ...rest } = record;
  const names = { ...(was ?? {}) };
  const named = seats.filter((i) => String(i) in names);
  for (const i of named) delete names[String(i)];
  return { record: Object.keys(names).length ? { ...rest, names } : rest, named };
}

/// Every kept game [account] sat in, by its licence, with its name
/// taken off it: for a deletion asked for. [bucket] lists, reads and
/// writes records as the operator's tool reaches R2
/// (service/tool/r2.mjs), or the worker ([keptGames]), a record as its
/// JSON; a game listed with the accounts noted beside it is read only
/// if it names this one. With [dry], writes nothing. A record that
/// would not be written back as it was sent ([NotAsSent]) stops the
/// run, unless [refused] is given, which is told its key and the run
/// goes on. Returns {key, named} for each game changed, or that would
/// be.
export async function anonymizeGames(bucket, account, { dry = false, refused = null } = {}) {
  const changed = [];
  for (const listed of await bucket.list('tables/')) {
    const { key, accounts = null } = typeof listed === 'string' ? { key: listed } : listed;
    if (accounts && !accounts.includes(account)) continue;
    let record;
    try {
      record = await bucket.get(key);
    } catch (e) {
      if (!(e instanceof NotAsSent) || !refused) throw e;
      refused(key);
      continue;
    }
    const without = withoutNames(record, account);
    if (!without?.named.length) continue;
    changed.push({ key, named: without.named });
    if (!dry) await bucket.put(key, without.record);
  }
  return changed;
}

/// The record kept for [table], as a response: packed, as it is kept.
/// The moves of a copy that carries the house's word never change (one
/// that does not is replaced by one that does); a name beside them can
/// come, as each seat's device sends its own, and go, when its account
/// is forgotten, and a copy a browser kept before then is that
/// browser's, as any copy a device keeps is its own.
export async function recordResponse(bucket, table, headers = {}) {
  if (!bucket) return Response.json({ error: 'records are not kept here' }, { status: 503, headers });
  if (typeof table !== 'string' || !tableIdShape.test(table)) return Response.json({ error: 'a table id, 32 hex' }, { status: 400, headers });
  const kept = await bucket.get(keyIn(table));
  if (!kept) return Response.json({ error: 'no record for that table' }, { status: 404, headers: { ...headers, 'cache-control': 'no-store' } });
  return new Response(kept.body, {
    headers: {
      ...headers,
      'content-type': 'application/json',
      'content-encoding': 'gzip',
      'cache-control': 'public, max-age=31536000, immutable',
    },
    encodeBody: 'manual',
  });
}
