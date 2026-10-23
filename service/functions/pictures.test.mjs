// The list of pictures withheld at the relay (pictures.mjs): taken down
// by the operator or hidden by the automatic check, and allowed — put
// back after the check hid it, so that the check does not hide it
// again — until the operator takes it down.
//
//   node --test service/functions

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { WITHHELD_FOR_MS, allowedOf, allowing, releasing, stillAllowing, withheldOf, withholding } from './pictures.mjs';

const A = 'a'.repeat(64);
const B = 'b'.repeat(64);
const now = Date.UTC(2026, 9, 19);

test('pictures: allowed is put back and listed apart; withheld again only by the operator, and each runs out', () => {
  let row = withholding(withholding(null, A, now), B, now);
  assert.deepEqual([...withheldOf(row, now)], [A, B]);
  assert.deepEqual(row, { pictures: [{ sha256: A, until: now + WITHHELD_FOR_MS }, { sha256: B, until: now + WITHHELD_FOR_MS }] }, 'no allowed list when none is');

  row = allowing(row, A, now);
  assert.deepEqual([...withheldOf(row, now)], [B]);
  assert.deepEqual([...allowedOf(row, now)], [A]);
  assert.deepEqual(row.allowed, [{ sha256: A, until: now + WITHHELD_FOR_MS }]);

  // Releasing another keeps what is allowed; allowing again moves it on.
  row = releasing(row, B, now);
  assert.deepEqual([...withheldOf(row, now)], []);
  assert.deepEqual([...allowedOf(row, now)], [A]);
  row = allowing(row, A, now + 1000);
  assert.deepEqual(row.allowed, [{ sha256: A, until: now + 1000 + WITHHELD_FOR_MS }], 'once, not twice');

  // The operator taking it down overrides having allowed it.
  row = withholding(row, A, now + 2000);
  assert.deepEqual([...withheldOf(row, now + 2000)], [A]);
  assert.deepEqual([...allowedOf(row, now + 2000)], []);
  assert.equal(row.allowed, undefined);

  // Run out, an allowed picture is no longer allowed, and is dropped
  // by the next write.
  row = allowing(withholding(null, B, now), A, now);
  const later = now + WITHHELD_FOR_MS;
  assert.deepEqual([...allowedOf(row, later)], []);
  assert.deepEqual(releasing(row, B, later), { pictures: [] });
});

test('pictures: what is allowed and still copied stays allowed; the rest runs out', () => {
  const C = 'c'.repeat(64);
  const row = allowing(allowing(withholding(null, C, now), A, now), B, now);
  const later = now + 20 * 86400000;
  const kept = stillAllowing(row, [A], later);
  assert.deepEqual(kept.pictures, row.pictures, 'what is withheld, as it was');
  assert.deepEqual(kept.allowed, [{ sha256: A, until: later + WITHHELD_FOR_MS }, { sha256: B, until: now + WITHHELD_FOR_MS }]);
  assert.deepEqual([...allowedOf(kept, now + WITHHELD_FOR_MS)], [A]);
});
