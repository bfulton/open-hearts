// The buckets as the operator's tools reach them from outside the
// workers (the oh command, ops/), through Cloudflare's API: OH_RECORDS's
// kept games, and the pictures in OH_PICTURES and those a legal hold
// keeps.

import { gzipSync } from 'node:zlib';

import { NotAsSent } from '../functions/records.mjs';

/// Where a bucket's objects are in Cloudflare's API, and the header
/// that reaches them.
function objectsAt({ token, account, bucket }) {
  const base = `https://api.cloudflare.com/client/v4/accounts/${account}/r2/buckets/${bucket}/objects`;
  // A key's slashes stay in the path, as Wrangler sends them.
  return { base, auth: { authorization: `Bearer ${token}` }, at: (key) => `${base}/${key.split('/').map(encodeURIComponent).join('/')}` };
}

/// A bucket through Cloudflare's API, as Wrangler reaches one: its keys,
/// and an object's bytes read, written and deleted.
export function restObjects({ token, account, bucket, fetchImpl = fetch }) {
  const { base, auth, at } = objectsAt({ token, account, bucket });
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
    /// The object's bytes, or null when there is none.
    async read(key) {
      const res = await fetchImpl(at(key), { headers: auth });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`reading said ${res.status}`);
      return new Uint8Array(await res.arrayBuffer());
    },
    async write(key, bytes, contentType) {
      const res = await fetchImpl(at(key), { method: 'PUT', headers: { ...auth, 'content-type': contentType }, body: bytes });
      if (!res.ok) throw new Error(`writing said ${res.status}`);
    },
    /// Deleted; one already gone is no error.
    async remove(key) {
      const res = await fetchImpl(at(key), { method: 'DELETE', headers: auth });
      if (!res.ok && res.status !== 404) throw new Error(`deleting said ${res.status}`);
    },
  };
}

/// A records bucket through Cloudflare's API, behind the calls
/// anonymizeGames makes (service/functions/records.mjs): its keys, and
/// a record read and written as its JSON; and, as any bucket, an
/// object's bytes.
export function restBucket({ token, account, bucket, fetchImpl = fetch }) {
  const { auth, at } = objectsAt({ token, account, bucket });
  return {
    ...restObjects({ token, account, bucket, fetchImpl }),
    /// A record, read: it is kept gzipped (content-encoding), which
    /// fetch takes off. One that JSON.stringify would not write back as
    /// it was sent is refused ([NotAsSent]).
    async get(key) {
      const res = await fetchImpl(at(key), { headers: auth });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`reading said ${res.status}`);
      const text = await res.text();
      const record = JSON.parse(text);
      if (JSON.stringify(record) !== text) throw new NotAsSent(key);
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
