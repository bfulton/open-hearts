// OH_STORE as the operator's tools reach it from outside the worker
// (the oh command, ops/).

/// OH_STORE through Cloudflare's API, behind the calls the worker's
/// store makes (service/functions/rows.mjs, storeOf).
export function restStore({ token, account, namespace, fetchImpl = fetch }) {
  const base = `https://api.cloudflare.com/client/v4/accounts/${account}/storage/kv/namespaces/${namespace}`;
  const auth = { authorization: `Bearer ${token}` };
  const at = (pk, sk) => encodeURIComponent(`${pk}|${sk}`);
  const list = async (prefix) => {
    const names = [];
    let cursor = '';
    do {
      const res = await fetchImpl(`${base}/keys?prefix=${encodeURIComponent(prefix)}&limit=1000${cursor ? `&cursor=${cursor}` : ''}`, { headers: auth });
      const page = await res.json();
      if (!page.success) throw new Error(`listing said ${res.status}`);
      for (const { name } of page.result) names.push(name);
      cursor = page.result_info?.cursor ?? '';
    } while (cursor);
    return names;
  };
  return {
    list,
    async get(pk, sk) {
      const res = await fetchImpl(`${base}/values/${at(pk, sk)}`, { headers: auth });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`reading said ${res.status}`);
      return res.json();
    },
    /// [ttl], in seconds (at least 60, KV's least), is how long KV keeps
    /// the row, as the worker's store takes it (rows.mjs).
    async put(pk, sk, value, { ttl } = {}) {
      const res = await fetchImpl(`${base}/values/${at(pk, sk)}${ttl ? `?expiration_ttl=${ttl}` : ''}`, {
        method: 'PUT',
        headers: { ...auth, 'content-type': 'application/json' },
        body: JSON.stringify(value),
      });
      if (!res.ok) throw new Error(`writing said ${res.status}`);
    },
    async del(pk, sk) {
      const res = await fetchImpl(`${base}/values/${at(pk, sk)}`, { method: 'DELETE', headers: auth });
      if (!res.ok && res.status !== 404) throw new Error(`deleting said ${res.status}`);
    },
    async under(pk, prefix) {
      return (await list(`${pk}|${prefix}`)).map((n) => n.slice(`${pk}|`.length));
    },
  };
}
