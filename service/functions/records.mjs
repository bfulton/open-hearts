// Games kept for looking at afterwards (app/lib/router.dart,
// /table/<id> on play.openhearts.game): a finished game's whole record, as one of its
// players' devices sends it, kept in R2 (OH_RECORDS) under the table's
// id, packed.
//
// Nothing here vouches for a record. Every event in it is signed, and
// whoever looks at one replays it through the verifier — every
// signature, every step of the deal — before showing a card of it
// (packages/table, game_record.dart, record.dart). What is checked here
// is what decides whose copy is kept, since the first copy is the one
// kept and a table's other players are told it is in: the sender is
// a subscriber's device in use (worker.mjs, recordRoute), a seat at
// the table, and has signed moves of its own at this table into it —
// an event of the record whose author is the sender, whose id is the
// hash of its own content, and whose signature checks. A record made
// up by somebody who never played there has none, and neither has a
// copy of somebody else's game with one's key written into a seat.

/// A table's id (packages/table, spec.dart, newTableId).
export const tableIdShape = /^[0-9a-f]{32}$/;

/// The most a record may be, unpacked. A full sealed game to a hundred
/// is some 700 KB; this is room over that, and a bound on what a
/// device can make the bucket hold.
export const recordMost = 2 * 1024 * 1024;

const keyIn = (table) => `tables/${table}.json`;

/// The id an event of [table] has: the hash of what it says, as the
/// table writes it (packages/table, events.dart, `_canonical`) — the
/// body's own keys in order, nothing else reordered.
export async function eventIdOf(table, event) {
  const body = Object.fromEntries(Object.entries(event.body).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  const text = JSON.stringify([table, event.author, event.kind, body]);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/// How many of the sender's own events are looked at before giving up:
/// any one that checks is enough, and a record is mostly the sender's.
const triedAtMost = 8;

/// Whether [record] holds an event [key] signed at [table]. [verify] is
/// the service's BIP-340 check (worker.mjs, signerOn).
async function signedInto(record, key, table, verify) {
  let tried = 0;
  for (const d of record.record) {
    const e = d?.event;
    if (e?.author !== key || typeof e.id !== 'string' || typeof e.sig !== 'string' || typeof e.kind !== 'string') continue;
    if (!e.body || typeof e.body !== 'object' || Array.isArray(e.body)) continue;
    if (tried++ >= triedAtMost) return false;
    if ((await eventIdOf(table, e)) === e.id && /^[0-9a-f]{128}$/.test(e.sig) && verify(key, e.id, e.sig)) return true;
  }
  return false;
}

/// Keeps [text], a record [key] sent for [table]: {status, body}.
/// [verify] checks a signature: (key, digest, signature) => bool.
export async function keepRecord(bucket, key, table, text, { verify }) {
  if (!bucket) return { status: 503, body: { error: 'records are not kept here' } };
  if (typeof table !== 'string' || !tableIdShape.test(table)) return { status: 400, body: { error: 'a table id, 32 hex' } };
  if (typeof text !== 'string' || text.length > recordMost) return { status: 413, body: { error: 'not a record this size' } };
  let record;
  try {
    record = JSON.parse(text);
  } catch {
    return { status: 400, body: { error: 'not a record' } };
  }
  const spec = record?.spec;
  if (record?.v !== 1 || spec?.id !== table || !Array.isArray(spec?.seats) || !Array.isArray(record?.record)) {
    return { status: 400, body: { error: 'not this table\'s record' } };
  }
  if (!spec.seats.some((s) => s?.key === key)) return { status: 403, body: { error: 'only a player at the table sends its record' } };
  if (!(await signedInto(record, key, table, verify))) {
    return { status: 403, body: { error: 'a record with none of your own moves in it' } };
  }
  if (await bucket.head(keyIn(table))) return { status: 200, body: { kept: true, already: true } };
  const packed = await new Response(new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer();
  await bucket.put(keyIn(table), packed, {
    httpMetadata: { contentType: 'application/json', contentEncoding: 'gzip' },
    customMetadata: { from: key },
  });
  return { status: 200, body: { kept: true } };
}

/// The record kept for [table], as a response: packed, as it is kept,
/// and for good — a finished game does not change.
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
