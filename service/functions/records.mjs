// Games kept for looking at afterwards (app/lib/router.dart,
// /table/<id> on play.openhearts.game): a finished game's whole record, as one of its
// players' devices sends it, kept in R2 (OH_RECORDS) under the table's
// id, packed.
//
// Nothing here vouches for a record. Every event in it is signed, the
// house's word on the end names the log as it stood, and whoever looks
// at one replays it through the verifier — every signature, every step
// of the deal — before showing a card of it (packages/table,
// record.dart). What is checked here is what decides whose copy is
// kept, since the first copy is the one kept and a table's other
// players are told it is in: the sender is a subscriber's device in
// use (worker.mjs, recordRoute), a seat at the table, and has signed
// moves of its own at this table into it — an event of the log whose
// author is the sender, whose id is the hash of its own content, and
// whose signature checks. A record made up by somebody who never
// played there has none, and neither has a copy of somebody else's
// game with one's key written into a seat.
// And its seats are ones the app would show: each person's carries the
// service's licence for its key (licenceProblem), which is what ties a
// name beside the record to an account, for forgetting one.

import { nameRefused } from './names.mjs';
import { dayOf } from './rows.mjs';

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

/// An account's number (rows.mjs, isAccount).
const accountShape = /^[0-9a-f]{32}$/;

/// The id an event of [table] has: the hash of what it says, as the
/// table writes it (packages/table, events.dart, `_canonical`) — the
/// body's own keys in order, nothing else reordered.
export async function eventIdOf(table, event) {
  const body = Object.fromEntries(Object.entries(event.body).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  return sha256Hex(JSON.stringify([table, event.author, event.kind, body]));
}

/// SHA-256 of [text], hex.
async function sha256Hex(text) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/// What a licence is the service's signature over: this, and then the
/// device's key, its account, its last day and the plan, a line each
/// (licence.mjs, licenceFor; packages/table, licence.dart).
const licenceStatement = 'oh-licence/2';

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
    const lines = [key, account, until, plan];
    const shaped = key === seat?.key && lines.every((v) => typeof v === 'string' && !v.includes('\n')) && /^[0-9a-f]{128}$/.test(sig ?? '');
    if (!shaped || !verify(service, await sha256Hex([licenceStatement, ...lines].join('\n')), sig)) return `seat ${s} has no licence for its key`;
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

/// Keeps [text], a record [key] sent for [table], without the name of
/// any account forgotten on request, or any the filter refuses
/// (asKept): {status, body}.
/// [verify] checks a signature: (key, digest, signature) => bool.
/// [service] is the service's public key where it signs licences
/// (licence.mjs, serviceKeys), and then every person's seat must carry
/// one (licenceProblem); where it signs none, nothing is checked, as
/// in an app built without one (licence.dart, licencesChecked).
export async function keepRecord(bucket, key, table, text, { verify, service = null }) {
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
  if (!spec.seats.some((s) => s?.key === key)) return { status: 403, body: { error: 'only a player at the table sends its record' } };
  if (!(await signedInto(record, key, table, verify))) {
    return { status: 403, body: { error: 'a record with none of your own moves in it' } };
  }
  const unlicensed = service ? await licenceProblem(spec.seats, service, verify) : null;
  if (unlicensed) return { status: 403, body: { error: unlicensed } };
  if (await bucket.head(keyIn(table))) return { status: 200, body: { kept: true, already: true } };
  const kept = await asKept(bucket, record, text);
  if (kept === null) return { status: 422, body: { error: 'a record that cannot be kept without the names taken out of it' } };
  await bucket.put(keyIn(table), await packed(kept), {
    httpMetadata: KEPT_AS,
    customMetadata: { from: key, accounts: seatedAccounts(record).join(',') },
  });
  return { status: 200, body: { kept: true } };
}

/// How a record is kept: gzipped, and said so.
const KEPT_AS = Object.freeze({ contentType: 'application/json', contentEncoding: 'gzip' });
const packed = (text) => new Response(new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer();

/// The accounts whose licences sit at [record]'s seats, each once: what
/// a kept game notes beside it (`accounts`, comma-separated), so that
/// one account's games are found without reading every game
/// (anonymizeGames).
function seatedAccounts(record) {
  return [...new Set(record.spec.seats.map((s) => s?.licence?.account).filter((a) => typeof a === 'string' && accountShape.test(a)))];
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
      const text = await new Response(kept.body.pipeThrough(new DecompressionStream('gzip'))).text();
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

/// [text], the record sent, as it is to be kept: without the names of
/// the seats whose licence names an account forgotten on request — a
/// game played while the account's last licence ran, or ended while
/// forget.mjs went through the kept games — nor any name the filter
/// refuses (names.mjs), which a device the relay would not have carried
/// it from could still put beside its game. Rewritten only if
/// JSON.stringify gives back [text] as it was sent, since an event's id
/// is a digest of its body as its reader parses it; null when it would
/// not.
async function asKept(bucket, record, text) {
  const accounts = seatedAccounts(record);
  let without = record;
  let named = 0;
  for (const account of accounts) {
    if (!(await bucket.head(forgottenKey(account)))) continue;
    const w = withoutNames(without, account);
    if (!w?.named.length) continue;
    without = w.record;
    named += w.named.length;
  }
  const refused = Object.entries(without.names ?? {}).filter(([, name]) => nameRefused(name));
  if (refused.length) {
    const { names: was, ...rest } = without;
    const names = { ...was };
    for (const [seat] of refused) delete names[seat];
    without = Object.keys(names).length ? { ...rest, names } : rest;
    named += refused.length;
  }
  if (!named) return text;
  return JSON.stringify(record) === text ? JSON.stringify(without) : null;
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
/// Its moves never change; a name beside them can go, when its account
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
