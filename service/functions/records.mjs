// Games kept for looking at afterwards (app/lib/router.dart,
// /table/<id> on play.openhearts.game): a finished game's whole record, as one of its
// players' devices sends it, kept in R2 (OH_RECORDS) under the table's
// id, packed.
//
// Nothing here vouches for a record. Every event in it is signed, and
// whoever looks at one replays it through the verifier — every
// signature, every step of the deal — before showing a card of it
// (packages/table, game_record.dart, record.dart). What is checked here
// is only what keeps the bucket from being anybody's: the one sending
// it sat at the table, the table's id is one a table has, and it is no
// bigger than a game is. The first copy is kept; a table's other
// players send theirs and are told it is in.

/// A table's id (packages/table, spec.dart, newTableId).
export const tableIdShape = /^[0-9a-f]{32}$/;

/// The most a record may be, unpacked. A full sealed game to a hundred
/// is some 700 KB; this is room over that, and a bound on what a
/// device can make the bucket hold.
export const recordMost = 2 * 1024 * 1024;

const keyIn = (table) => `tables/${table}.json`;

/// Keeps [text], a record [key] sent for [table]: {status, body}.
export async function keepRecord(bucket, key, table, text) {
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
