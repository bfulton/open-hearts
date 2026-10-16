// OH_RECORDS as the operator's tools reach it from outside the worker
// (the oh command, ops/): kept games through Cloudflare's API.

import { gzipSync } from 'node:zlib';

/// A records bucket through Cloudflare's API, behind the calls
/// anonymizeGames makes (service/functions/records.mjs): its keys, and
/// a record read and written as its JSON.
export function restBucket({ token, account, bucket, fetchImpl = fetch }) {
  const base = `https://api.cloudflare.com/client/v4/accounts/${account}/r2/buckets/${bucket}/objects`;
  const auth = { authorization: `Bearer ${token}` };
  const at = (key) => `${base}/${encodeURIComponent(key)}`;
  return {
    async list(prefix) {
      const keys = [];
      let cursor = '';
      do {
        const res = await fetchImpl(`${base}?prefix=${encodeURIComponent(prefix)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`, { headers: auth });
        const page = await res.json();
        if (!page.success) throw new Error(`listing said ${res.status}`);
        for (const { key } of page.result) keys.push(key);
        cursor = page.result_info?.is_truncated ? page.result_info.cursor : '';
      } while (cursor);
      return keys;
    },
    /// A record, read: it is kept gzipped (content-encoding), which
    /// fetch takes off. One that JSON.stringify would not write back as
    /// it was sent is refused: an event's id is a digest of its body as
    /// its reader parses it, and a number written another way can parse
    /// to another value (Dart reads 2.0 and 2 apart).
    async get(key) {
      const res = await fetchImpl(at(key), { headers: auth });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`reading said ${res.status}`);
      const text = await res.text();
      const record = JSON.parse(text);
      if (JSON.stringify(record) !== text) throw new Error(`${key} would not be written back as it was sent`);
      return record;
    },
    /// A record, written as records.mjs keeps one: gzipped, and said so.
    async put(key, record) {
      const res = await fetchImpl(at(key), {
        method: 'PUT',
        headers: { ...auth, 'content-type': 'application/json', 'content-encoding': 'gzip' },
        body: gzipSync(JSON.stringify(record)),
      });
      if (!res.ok) throw new Error(`writing said ${res.status}`);
    },
  };
}
