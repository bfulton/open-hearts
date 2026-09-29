// A NIP-01 relay with no runtime of its own: the subset the table
// speaks (docs/06-service.md), written as plain functions over
// anything that can send a string. The Cloudflare object
// (worker.mjs) and a plain node host (host.mjs) both drive this file,
// so what the app meets on Cloudflare is what the Dart suites — the
// same ones that have always run against the Dart relay — run against
// here.
//
// Nothing is imported: no node, no Cloudflare. Signatures are checked
// by the wasm the app already carries (app/web/schnorr.wasm, built
// from measurements/sign), handed in already compiled, because a
// Worker may not compile wasm at runtime and because BIP-340 is not
// worth a second implementation in a third language.

/// Kinds 20000–29999 are ephemeral: forwarded to whoever is listening
/// and then forgotten. Every kind presence uses is one of these, which
/// is why an object carrying presence never writes anything down.
export const ephemeral = (kind) => kind >= 20000 && kind < 30000;

/// How many subscriptions one socket may hold. A hibernating socket
/// carries its subscriptions with it — that ride has a size limit and
/// is the only place they survive — so the count is bounded here and
/// the oldest goes as a new one arrives. Bounded as it is written is
/// the whole trick: nothing accumulates, so nothing needs sweeping.
/// Eight is four times what any client in this repo opens.
export const maxSubscriptions = 8;

/// How many event ids are remembered to answer a duplicate with the
/// `duplicate:` a client expects. Ephemeral events are the traffic and
/// are never stored, so this is the one set that would otherwise grow
/// without end; past the cap it drops back to the ids actually kept.
export const rememberedIds = 40000;

/// What may name an object: one path segment, and the characters a
/// table id, a pool or a topic are made of. A tag is a name in a
/// global namespace, so it is worth being strict about — everything
/// under one tag shares one object, and nothing else can reach it.
const tagShape = /^[A-Za-z0-9._:@+-]{1,128}$/;

/// The tag a path names: '' for the root, which names no tag at all,
/// and null for a path that could not name one. The object host and
/// the node host both ask this, so a client that reaches one reaches
/// the other by the same URL.
export function tagOf(pathname) {
  let path;
  try {
    path = decodeURIComponent(pathname).replace(/^\/+/, '');
  } catch {
    return null; // escapes that are not escapes
  }
  if (path === '') return '';
  // A name that reads as a step up a tree: object names have no tree
  // to step up, but a URL that says otherwise is not answered.
  if (path === '.' || path === '..') return null;
  return tagShape.test(path) ? path : null;
}

const hex64 = /^[0-9a-f]{64}$/;
const hex128 = /^[0-9a-f]{128}$/;
const encoder = new TextEncoder();

/// BIP-340 verification through the wasm: `verify(pubkey, digest, sig)`
/// over lowercase hex. Takes a compiled `WebAssembly.Module` — what a
/// Worker gets from importing the file — or the bytes themselves,
/// which is what node has. Throws if the wasm does not agree with
/// BIP-340's first vector, since a verifier that says yes to
/// everything would pass every test that only checks good signatures.
export async function schnorrVerifier(wasm) {
  const module = wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm);
  const { memory, alloc, reset, verify } = new WebAssembly.Instance(module, {}).exports;
  reset();
  const msg = alloc(32);
  const sig = alloc(64);
  const pk = alloc(32);
  const put = (at, hex) => {
    const mem = new Uint8Array(memory.buffer);
    for (let i = 0; i < hex.length; i += 2) mem[at + i / 2] = parseInt(hex.slice(i, i + 2), 16);
  };
  const check = (pubkey, digest, signature) => {
    // Hex the wasm cannot read would be written as zeroes, which is a
    // signature nobody claimed; refuse it here instead.
    if (!hex64.test(pubkey) || !hex64.test(digest) || !hex128.test(signature)) return false;
    put(pk, pubkey);
    put(msg, digest);
    put(sig, signature);
    return verify(pk, msg, sig) === 1;
  };
  const vector = {
    pk: 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9',
    msg: '0'.repeat(64),
    sig: 'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0',
  };
  const tampered = `${vector.sig.slice(0, 127)}1`;
  if (!check(vector.pk, vector.msg, vector.sig) || check(vector.pk, vector.msg, tampered)) {
    throw new Error('schnorr wasm does not agree with BIP-340');
  }
  return check;
}

/// NIP-01's id: the SHA-256 of `[0, pubkey, created_at, kind, tags,
/// content]` as compact JSON, in lowercase hex.
export async function idOf(pubkey, createdAt, kind, tags, content) {
  const canonical = encoder.encode(JSON.stringify([0, pubkey, createdAt, kind, tags, content]));
  const digest = await crypto.subtle.digest('SHA-256', canonical);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const strings = (v) => Array.isArray(v) && v.every((s) => typeof s === 'string');

/// Parses and checks an event: the shape, then that the id is the hash
/// of what it carries, then the signature. Null for anything
/// malformed, misidentified or not signed by its claimed author —
/// which is as far as anything unchecked gets into this relay.
export async function checkEvent(json, verify) {
  if (!json || typeof json !== 'object' || Array.isArray(json)) return null;
  const { id, pubkey, created_at: createdAt, kind, tags, content, sig } = json;
  if (typeof id !== 'string' || typeof pubkey !== 'string' || typeof content !== 'string' || typeof sig !== 'string') return null;
  if (!Number.isInteger(createdAt) || !Number.isInteger(kind)) return null;
  if (!Array.isArray(tags) || !tags.every(strings)) return null;
  const computed = await idOf(pubkey, createdAt, kind, tags, content);
  if (computed !== id) return null;
  if (!verify(pubkey, computed, sig)) return null;
  return { id, pubkey, created_at: createdAt, kind, tags, content, sig };
}

/// A NIP-01 filter: every listed condition must hold, a list matches
/// any of its values, and `#x` matches events with a tag `x` of any of
/// the values. Null for a filter that is not one — a client that sends
/// nonsense is told so rather than quietly served everything.
export function parseFilter(json) {
  if (!json || typeof json !== 'object' || Array.isArray(json)) return null;
  const filter = { tags: {} };
  for (const [key, value] of Object.entries(json)) {
    if (key.length === 2 && key[0] === '#') {
      if (!strings(value)) return null;
      filter.tags[key[1]] = value;
      continue;
    }
    switch (key) {
      case 'ids':
      case 'authors':
        if (!strings(value)) return null;
        filter[key] = value;
        break;
      case 'kinds':
        if (!Array.isArray(value) || !value.every(Number.isInteger)) return null;
        filter.kinds = value;
        break;
      case 'since':
      case 'until':
      case 'limit':
        if (!Number.isInteger(value)) return null;
        filter[key] = value;
        break;
      default:
        // NIP-01 leaves a relay free to ignore what it does not know.
        break;
    }
  }
  return filter;
}

/// Whether [event] answers [filter]. Ids and authors match on a
/// prefix, as NIP-01 allows and the table's clients rely on.
export function matches(filter, event) {
  if (filter.ids && !filter.ids.some((p) => event.id.startsWith(p))) return false;
  if (filter.authors && !filter.authors.some((p) => event.pubkey.startsWith(p))) return false;
  if (filter.kinds && !filter.kinds.includes(event.kind)) return false;
  if (filter.since !== undefined && event.created_at < filter.since) return false;
  if (filter.until !== undefined && event.created_at > filter.until) return false;
  for (const [name, values] of Object.entries(filter.tags)) {
    if (!event.tags.some((t) => t.length >= 2 && t[0] === name && values.includes(t[1]))) return false;
  }
  return true;
}

/// What a relay keeps of the kinds that are not ephemeral: a list in
/// memory, newest last, the oldest dropped as the newest arrives so
/// the cap holds by construction. `add` hands back whatever it evicted,
/// since the relay forgets that id as well.
export function memoryStore(keep = 10000) {
  const events = [];
  return {
    get size() {
      return events.length;
    },
    add(event) {
      events.push(event);
      return events.length > keep ? events.shift() : null;
    },
    /// Everything matching, oldest first, cut to [limit] from the
    /// newest end — which is the end a limit means.
    matching(filters, limit) {
      const found = events.filter((e) => filters.some((f) => matches(f, e)));
      return limit !== null && found.length > limit ? found.slice(found.length - limit) : found;
    },
    ids() {
      return events.map((e) => e.id);
    },
  };
}

/// The relay itself. [verify] checks a signature, [refuse] is a policy
/// that may turn an event away with a reason — a public relay
/// demanding proof of work, or an object that carries only the kinds
/// it can carry for free — and [store] is where the kinds that are not
/// ephemeral go, or null for a relay that keeps nothing at all.
///
/// A socket is anything with `send(text)`. The relay holds the set of
/// them, so a host that wakes with sockets it did not open — a
/// hibernating object — hands each one back through [open] with the
/// subscriptions it was carrying. [refuse] may answer with a promise:
/// the node host asks the Dart test that installed the policy.
export function createRelay({ verify, store = memoryStore(), refuse = null, log = null }) {
  /// socket -> subscription id -> {raw, filters}. The raw filters are
  /// kept beside the parsed ones because a hibernating socket has to
  /// carry them somewhere and JSON is what it can carry.
  const sockets = new Map();
  /// socket -> the promise of everything it has already said. Checking
  /// an event is asynchronous, so without this a burst from one client
  /// could answer out of order — and a REQ that overtook the EVENT
  /// before it would miss it.
  const turns = new Map();
  const seen = new Set();

  const send = (socket, message) => {
    try {
      socket.send(JSON.stringify(message));
    } catch {
      // A socket on its way out; its close will drop it.
    }
  };

  async function publish(from, json) {
    const event = await checkEvent(json, verify);
    if (!event) {
      const id = json && typeof json === 'object' ? json.id : null;
      log?.(`rejected ${typeof id === 'string' ? id.slice(0, 6) : '?'}`);
      return send(from, ['OK', typeof id === 'string' ? id : '', false, 'invalid: bad id or signature']);
    }
    const why = await refuse?.(event);
    if (why) {
      log?.(`refused ${event.id.slice(0, 6)}: ${why}`);
      return send(from, ['OK', event.id, false, why]);
    }
    if (seen.has(event.id)) return send(from, ['OK', event.id, true, 'duplicate: already have this event']);
    seen.add(event.id);
    if (!ephemeral(event.kind)) {
      const gone = store?.add(event);
      if (gone) seen.delete(gone.id);
    } else if (seen.size > rememberedIds) {
      // Ephemeral ids are remembered only to answer duplicates. They
      // are the traffic, so this is the set that would grow for ever:
      // drop it back to what is stored rather than let it.
      const stored = store ? store.ids() : [];
      seen.clear();
      for (const id of stored) seen.add(id);
    }
    send(from, ['OK', event.id, true, '']);
    for (const [socket, subscriptions] of sockets) {
      for (const [id, sub] of subscriptions) {
        if (sub.filters.some((f) => matches(f, event))) {
          send(socket, ['EVENT', id, event]);
          break;
        }
      }
    }
  }

  function request(socket, message) {
    const id = message[1];
    const filters = [];
    for (const raw of message.slice(2)) {
      const parsed = parseFilter(raw);
      if (!parsed) return send(socket, ['NOTICE', 'bad filter']);
      filters.push(parsed);
    }
    const subscriptions = sockets.get(socket);
    if (!subscriptions) return;
    subscriptions.set(id, { raw: message.slice(2), filters });
    // The oldest goes when a client holds more than it may.
    while (subscriptions.size > maxSubscriptions) subscriptions.delete(subscriptions.keys().next().value);
    log?.(`sub ${id}: ${message.slice(2).map((f) => JSON.stringify(f)).join(' ')}`);
    // Stored history first, oldest first, honouring the largest limit
    // asked for; then the mark that says the history is done.
    const limit = filters.reduce((a, f) => (f.limit === undefined ? a : a === null ? f.limit : Math.max(a, f.limit)), null);
    for (const event of store ? store.matching(filters, limit) : []) send(socket, ['EVENT', id, event]);
    send(socket, ['EOSE', id]);
  }

  async function handle(socket, raw) {
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return send(socket, ['NOTICE', 'not JSON']);
    }
    if (!Array.isArray(message) || !message.length || typeof message[0] !== 'string') {
      return send(socket, ['NOTICE', 'not a message']);
    }
    switch (message[0]) {
      case 'EVENT':
        if (message.length !== 2) return send(socket, ['NOTICE', 'EVENT takes one event']);
        return publish(socket, message[1]);
      case 'REQ':
        if (message.length < 3 || typeof message[1] !== 'string') return send(socket, ['NOTICE', 'REQ takes an id and filters']);
        return request(socket, message);
      case 'CLOSE':
        if (message.length === 2 && typeof message[1] === 'string') sockets.get(socket)?.delete(message[1]);
        return;
      default:
        return send(socket, ['NOTICE', `unknown message ${message[0]}`]);
    }
  }

  return {
    /// A socket the host has accepted, with the subscriptions it was
    /// already carrying if it is one that woke from hibernation.
    open(socket, carried = null) {
      const subscriptions = new Map();
      for (const [id, raw] of Object.entries(carried ?? {})) {
        const filters = [];
        for (const f of raw) {
          const parsed = parseFilter(f);
          if (parsed) filters.push(parsed);
        }
        if (filters.length) subscriptions.set(id, { raw, filters });
      }
      sockets.set(socket, subscriptions);
      log?.(`connected (${sockets.size})`);
    },

    /// One message from [socket], in its turn behind that socket's
    /// earlier ones. The promise is for a host that wants to know when
    /// the message has been answered.
    message(socket, raw) {
      const turn = (turns.get(socket) ?? Promise.resolve())
        .then(() => handle(socket, raw))
        .catch((e) => log?.(`relay: ${e}`));
      turns.set(socket, turn);
      return turn;
    },

    close(socket) {
      sockets.delete(socket);
      turns.delete(socket);
      log?.(`closed (${sockets.size})`);
    },

    /// What [socket] must carry to survive hibernation, as JSON.
    subscriptionsOf(socket) {
      const subscriptions = sockets.get(socket);
      if (!subscriptions) return {};
      return Object.fromEntries([...subscriptions].map(([id, sub]) => [id, sub.raw]));
    },

    get connections() {
      return sockets.size;
    },

    get stored() {
      return store ? store.size : 0;
    },
  };
}
