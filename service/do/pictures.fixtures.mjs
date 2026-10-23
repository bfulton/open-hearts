// What the tests of the pictures accounts set share
// (profile_pictures.test.mjs, review.test.mjs): an R2 bucket in memory,
// Workers AI answering as told, and pictures that differ by a byte.

import { lobbyKind } from './relay.mjs';

export const DAY = 24 * 60 * 60 * 1000;
export const ADA = '0a'.repeat(16);
export const BAO = '0b'.repeat(16);
export const CY = '0c'.repeat(16);
export const KEY = 'cd'.repeat(32);

/// A JPEG's base64, different for each [n]: the bytes are not looked at.
export const jpeg = (n) => Buffer.from([0xff, 0xd8, 0xff, 0xe0, n & 0xff, n >> 8]).toString('base64');

/// A lobby event carrying [jpeg(n)], as a pool or a room puts one out.
export const picture = (n, kind = lobbyKind) => ({ kind, content: JSON.stringify({ kind: 'picture', jpeg: jpeg(n) }) });

/// An R2 bucket binding in memory, with [clock] for when each object
/// was written; it lists two at a time, so that paging is used. Each
/// write gives the object a new etag, and a put `onlyIf` an etag is
/// refused, as R2 refuses it, when the object has another or is gone.
/// [meanwhile], when a test sets it, runs once before the next put
/// that names an etag, as another writer would between the read and
/// the write.
export function bucket(clock) {
  const objects = new Map();
  let etags = 0;
  const view = (key) => {
    const o = objects.get(key);
    return { key, etag: o.etag, uploaded: new Date(o.uploaded), customMetadata: { ...o.customMetadata }, httpMetadata: o.httpMetadata };
  };
  return {
    objects,
    heads: 0,
    meanwhile: null,
    async head(key) {
      this.heads++;
      return objects.has(key) ? view(key) : null;
    },
    async get(key) {
      if (!objects.has(key)) return null;
      const bytes = objects.get(key).bytes;
      return { ...view(key), arrayBuffer: async () => new Uint8Array(bytes).buffer };
    },
    async put(key, bytes, { customMetadata = {}, httpMetadata, onlyIf } = {}) {
      if (onlyIf && this.meanwhile) {
        const run = this.meanwhile;
        this.meanwhile = null;
        await run();
      }
      if (onlyIf?.etagMatches !== undefined && objects.get(key)?.etag !== onlyIf.etagMatches) return null;
      const kept = typeof bytes === 'string' ? new TextEncoder().encode(bytes) : new Uint8Array(bytes);
      objects.set(key, { bytes: kept, customMetadata: { ...customMetadata }, httpMetadata, uploaded: clock(), etag: `e${++etags}` });
      return view(key);
    },
    async list({ prefix, cursor }) {
      const all = [...objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const from = cursor ? Number(cursor) : 0;
      const page = all.slice(from, from + 2);
      const more = from + 2 < all.length;
      return { objects: page.map(view), truncated: more, ...(more ? { cursor: String(from + 2) } : {}) };
    },
    async delete(keys) {
      for (const k of [keys].flat()) objects.delete(k);
    },
  };
}

/// Workers AI's binding, answering each picture (its base64) as
/// [answer] says: {sexual, gore, hate}, or an Error to throw.
export function fakeAi(answer) {
  const calls = [];
  return {
    calls,
    async run(model, input) {
      calls.push({ model, input });
      const said = answer(input.images[0].slice('data:image/jpeg;base64,'.length));
      if (said instanceof Error) throw said;
      return { model: 'clef-flash', answers: Object.fromEntries(Object.entries(said).map(([id, p]) => [id, { type: 'noul', noul: p }])) };
    },
  };
}

export const harmless = { sexual: 0.01, gore: 0.01, hate: 0.01 };
