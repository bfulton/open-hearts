// A NIP-01 relay with no runtime of its own: the subset the table
// speaks (docs/explanation/service.md), written as plain functions over
// anything that can send a string. The Cloudflare object
// (worker.mjs) and a plain node host (host.mjs) both drive this file,
// so what the app meets on Cloudflare is what the Dart and browser
// suites run against.
//
// What is imported is plain functions too — the service's name filter
// and hashing, the kinds (kinds.mjs), a table's referee (referee.mjs)
// and a pool's watch (pool.mjs) — with no node and no Cloudflare.
// Signatures are checked by the wasm the app already carries
// (app/web/schnorr.wasm, built from crypto/schnorr_wasm), handed in
// already compiled, because a Worker may not compile wasm at runtime
// and because BIP-340 is not worth a second implementation in a third
// language.

import { nameRefused } from '../functions/names.mjs';
import { digestOf, hex } from '../functions/rows.mjs';
import { lobbyKind, waitingKind, watchKind } from './kinds.mjs';
import { logKind, tableReferee, tableTag } from './referee.mjs';
import { isPoolTag, poolWatch, seatingHeld } from './pool.mjs';

export { lobbyKind, watchKind };

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

/// What presence's object (worker.mjs, and host.mjs with --object) holds
/// one socket to; every other tag's holds it to [tableLimits]. Presence's
/// largest event is a beat with the device's activation in it, under a
/// kilobyte, for everyone on the tag at once, and the tag takes a socket
/// from anybody. Cloudflare hands an object messages of up to 32 MiB,
/// and an event that matches presence is sent on to every device
/// listening, on the one thread they all share.
export const objectLimits = Object.freeze({
  /// The longest message read at all, in characters.
  message: 64 * 1024,
  /// The longest REQ: its id and its filters are what the socket
  /// carries through hibernation, and eight of these sit well inside
  /// the 16 KiB an attachment may be.
  request: 1024,
  /// Events one socket may publish at once, and then each second. A
  /// device beats every five seconds; a flood is refused before its
  /// signature is checked.
  burst: 30,
  perSecond: 2,
});

/// How far the operator may move each of [objectLimits], from the row
/// `config|relay` (docs/explanation/service.md). The edges are
/// where a limit stops being a tuning: a REQ past 1,536 characters
/// times eight no longer fits the 16 KiB a socket carries through
/// hibernation, and a message past 256 KiB is a socket holding the
/// shared thread for anybody.
export const objectLimitBounds = Object.freeze({
  message: [8 * 1024, 256 * 1024],
  request: [256, 1536],
  burst: [5, 200],
  perSecond: [1, 20],
});

/// The row, checked: each limit that is a whole number within its
/// bounds, and [objectLimits]' own for the rest.
export function objectLimitsOf(raw) {
  const limits = { ...objectLimits };
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [name, [least, most]] of Object.entries(objectLimitBounds)) {
      const v = raw[name];
      if (Number.isInteger(v) && v >= least && v <= most) limits[name] = v;
    }
  }
  return Object.freeze(limits);
}

/// The relay's limits as the operator last set them: the row
/// `config|relay` in OH_STORE, checked ([objectLimitsOf]); the
/// defaults with no store, no row, or a store that is down. Read when
/// the relay is built, which is after every wake, so a change reaches
/// an object the next time it is evicted and woken.
export async function limitsFrom(env) {
  try {
    return objectLimitsOf(await env.OH_STORE?.get('config|relay', 'json'));
  } catch {
    return objectLimitsOf(null);
  }
}

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
  return digestOf(JSON.stringify([0, pubkey, createdAt, kind, tags, content]));
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
    /// The event with [id] let go of, if it was held: what it was, or
    /// null.
    drop(id) {
      const at = events.findIndex((e) => e.id === id);
      return at < 0 ? null : events.splice(at, 1)[0];
    },
  };
}

// ---- who may use it ---------------------------------------------------
// Live play is a subscription's, and an account is played on one device
// at a time (docs/explanation/service.md). So the relay carries a device only on
// the service's word that it is the account's device in use now: the
// activation the service signed for it (packages/table, licence.dart).
// It asks for one on every socket, before anything else (NIP-42's AUTH:
// a challenge, answered by an event the device's key signs with the
// activation in its tags), holds whatever the socket says until the
// answer is in, and carries nothing for a socket without one. A
// device's activation names its account and an epoch, the count of
// times the account has been taken up: the relay closes the socket of
// any device of an account the moment a later epoch of that account is
// shown to it, or the account's turn tells it one was given
// ([createRelay], `revoke`), and opens none for an earlier one. Asking
// a device to stop would leave a modified one going; refusing it does
// not. The house is the one key carried without an activation: the
// operator's own, it shows nothing but its answer, signed by that key.

/// The kind of a device's answer to the relay's challenge (NIP-42).
export const authKind = 22242;

/// The activation [raw] says, as {account, key, epoch, until}, when the
/// service ([service], its public key) signed it and it has not run out
/// at [nowS]; null otherwise. The statement is the service's
/// (service/functions/licence.mjs, activationFor).
export async function activationOf(raw, service, verify, nowS) {
  if (!raw || typeof raw !== 'object' || !hex64.test(service ?? '')) return null;
  const { account, key, epoch, until, sig } = raw;
  if (typeof account !== 'string' || !/^[0-9a-f]{32}$/.test(account) || typeof key !== 'string' || !hex64.test(key)) return null;
  if (!Number.isSafeInteger(epoch) || epoch < 0 || !Number.isSafeInteger(until) || typeof sig !== 'string') return null;
  if (until <= nowS) return null;
  const digest = await digestOf(`oh-active/1\n${account}\n${key}\n${epoch}\n${until}`);
  return verify(service, digest, sig) ? { account, key, epoch, until } : null;
}

/// How long the house's answer is taken for, in seconds, before it is
/// asked again.
const houseSeconds = 24 * 60 * 60;

/// The gate a relay holds its sockets to ([createRelay], `gate`): a
/// fresh challenge per socket, and who answered it — {account, key,
/// epoch, until} — or {refused: reason}. [service] is the service's
/// public key, [house] the house's, or null for none: the house belongs
/// to no account, and its answer, signed by its key, is all it shows;
/// [seen] asks the account's turn whether an activation is still the
/// one in use, answering a reason when it is not, or null.
export function serviceGate({ service, verify, house = null, seen = null, now = Date.now }) {
  return {
    challenge: () => hex(crypto.getRandomValues(new Uint8Array(16))),
    async admit(event) {
      const said = (name) => event.tags.find((t) => t[0] === name)?.[1];
      if (house && event.pubkey === house) return { account: null, key: house, epoch: 0, until: Math.floor(now() / 1000) + houseSeconds };
      let raw = null;
      try {
        raw = JSON.parse(said('activation') ?? 'null');
      } catch {
        // Not one.
      }
      const who = await activationOf(raw, service, verify, Math.floor(now() / 1000));
      if (!who || who.key !== event.pubkey) return { refused: 'auth-required: this device has no current activation' };
      const why = await seen?.(who);
      return why ? { refused: why } : who;
    },
  };
}

/// [serviceGate]'s `seen` from the accounts' own objects ([household],
/// their namespace; service/functions/household.mjs, seenAt): yes on a
/// 200, no on a 409 with the reason it gives. Any other answer, or none
/// at all, leaves the service's signature standing until its hour is
/// up, and is logged with [log], since the device is then let in on the
/// signature alone.
export function householdSeen(household, tag, log = console.log) {
  return async (who) => {
    let answer;
    try {
      const stub = household.get(household.idFromName(who.account));
      const op = { op: 'seen', account: who.account, key: who.key, epoch: who.epoch, tag };
      answer = await (await stub.fetch('https://household/', { method: 'POST', body: JSON.stringify(op) })).json();
    } catch (e) {
      log(`gate: a device let in unchecked: ${e?.message ?? e}`);
      return null;
    }
    if (answer?.status === 409) return answer.body?.error ?? supersededWhy;
    if (answer?.status !== 200) log(`gate: a device let in unchecked: ${answer?.status} ${answer?.body?.error ?? ''}`.trim());
    return null;
  };
}

/// How many messages, and how many characters of them, a socket may say
/// before its answer to the challenge is in: a client sends its
/// subscriptions at once, and maybe the few events it has said that it
/// has not yet seen taken (packages/table, relay_line.dart, `_opened`);
/// past this it is not a client waiting for an answer. The characters
/// bound what a socket that never answers makes the object hold: two of
/// a table's longest messages.
const heldMost = 32;
const heldMostChars = 256 * 1024;

/// How old a device's answer to the challenge may be, in seconds.
const answerFreshS = 600;

/// What a device is told as its sockets close because another device
/// of its account has taken the account up.
const supersededWhy = 'superseded: another device of this account is in use';

/// Whether [why] is a refusal the relay will not change its mind about
/// for this device: superseded, its account suspended
/// (service/functions/suspension.mjs) or deleted
/// (service/functions/deletion.mjs). The app
/// goes by the same first word (packages/table, relays.dart,
/// turnedAway).
const finalWhy = (why) => typeof why === 'string' && why.length <= 120 && /^(superseded|suspended|deleted): /.test(why);

/// The relay itself. [verify] checks a signature, [refuse] is a policy
/// that may turn an event away with a reason — an object that carries
/// only the kinds its tag may hold — and [store] is where the kinds
/// that are not ephemeral go, or null for a relay that keeps nothing at
/// all.
///
/// A socket is anything with `send(text)`. The relay holds the set of
/// them, so a host that wakes with sockets it did not open — a
/// hibernating object — hands each one back through [open] with the
/// subscriptions it was carrying. [refuse] may answer with a promise:
/// the node host asks the Dart test that installed the policy.
///
/// [limits] is [objectLimits] or [tableLimits], or null for none; [now]
/// is the clock the rate is measured by. [count], if given, is told what
/// became of each message — `count('events')`, `count('delivered', n)` —
/// and nothing about who sent it: what the operator watches (worker.mjs).
///
/// [gate], when given, is who may use it ([serviceGate]): every socket
/// is asked, and carried nothing until it has answered. A socket may
/// then also have `close()`, for the relay to end it.
///
/// [withhold], when given, says of an event (or a promise of saying)
/// why the relay keeps it to itself, or null: one the operator took
/// down (service/do/withheld.mjs). Published, such an event is answered
/// as taken — `OK true` with the reason, so that the device is not
/// counted as refused — and neither stored nor passed on; already held,
/// it is let go of before a subscription is served, and [forget] tells
/// the host to let go of its copy too.
///
/// [screen], when given, is asked first of each event published, with
/// who said it, and answers as [withhold] does: a picture that is not
/// its account's picture now (service/do/profile_pictures.mjs). What is
/// already held was screened as it came, so only [withhold] is asked of
/// that.
///
/// [referee], when given, makes the referee of the table this relay is
/// the tag of (referee.mjs, tableReferee) from the relay's own `send`
/// and `admitted`: the relay then takes the table's events
/// ([logKind]) for its log, and answers `["LOG", sub, from]` with the
/// log from there and `["TICK"]` with the time.
///
/// [watcher], when given, makes what watches a pool's want of its house
/// (pool.mjs, poolWatch) from the relay's own `holds`: it is told of
/// each event the relay took, and says whether the pool wants its house
/// ([wantsHouse]).
export function createRelay({ verify, store = memoryStore(), refuse = null, log = null, limits = null, now = Date.now, count = null, kept = null, gate = null, withhold = null, screen = null, forget = null, referee = null, watcher = null }) {
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
  /// socket -> {tokens, at}: what it may still publish under [limits].
  const buckets = new Map();
  /// socket -> {challenge, who, held, refused}: what the gate asked it,
  /// who answered, what it said meanwhile, and why it is refused.
  const auths = new Map();
  /// account -> the newest epoch this relay has seen of it, and why the
  /// devices before it were cut off.
  const epochs = new Map();
  const epochOf = (account) => epochs.get(account)?.epoch ?? -1;

  const sendText = (socket, text) => {
    try {
      socket.send(text);
    } catch {
      // A socket on its way out; its close will drop it.
    }
  };
  const send = (socket, message) => sendText(socket, JSON.stringify(message));

  const nowS = () => Math.floor(now() / 1000);

  /// Whether [socket] may be carried now: no gate, or an answer that has
  /// not run out.
  const admitted = (socket) => {
    if (!gate) return true;
    const who = auths.get(socket)?.who;
    return !!who && who.until > nowS();
  };

  /// The table's referee, on a table's tag.
  const table = referee?.({ send: sendText, admitted }) ?? null;

  /// Why [event] is not carried when it is a view of the table from a
  /// key that holds no seat at it: a view is a seated player's to say
  /// (packages/table, watch.dart), and the watchers believe it, so once
  /// the start says who sits there, nobody else's is carried.
  const viewRefusal = (event) =>
    table && event.kind === watchKind && table.seated(event.pubkey) === false && namingContent(event)?.view !== undefined ? VIEW_NOT_SEATED_WHY : null;

  /// Whether a socket that answered the gate as [key], for no account,
  /// is carried now: the house, on this tag. Nobody, with no gate.
  const holds = (key) => {
    for (const [socket, a] of auths) {
      if (a.who && !a.who.account && a.who.key === key && admitted(socket)) return true;
    }
    return false;
  };

  /// What watches a pool's want of its house, on a pool's tag.
  const watching = watcher?.({ holds }) ?? null;

  /// A fresh challenge for [socket], whose answer ran out or never came.
  function challenge(socket) {
    const a = { challenge: gate.challenge(), who: null, held: [], refused: null };
    auths.set(socket, a);
    send(socket, ['AUTH', a.challenge]);
    return a;
  }

  /// [socket] cut off for [why]: nothing more carried to it or from it,
  /// and the socket ended where the host lets it be.
  function cutOff(socket, why) {
    const a = auths.get(socket);
    if (a) {
      a.who = null;
      a.refused = why;
      a.held = [];
    }
    sockets.get(socket)?.clear();
    send(socket, ['NOTICE', why]);
    try {
      socket.close?.(4001, why.slice(0, 120));
    } catch {
      // Gone already.
    }
  }

  /// Every socket of [account] from before [epoch] closed, saying
  /// [why], and [epoch] kept as the newest of it, with [why] for any of
  /// its devices from before that comes back.
  function supersede(account, epoch, why = supersededWhy) {
    if (epochOf(account) < epoch) epochs.set(account, { epoch, why });
    for (const [socket, a] of auths) {
      if (a.who?.account === account && a.who.epoch < epoch) {
        count?.('superseded');
        log?.(`superseded a device of ${account.slice(0, 6)}`);
        cutOff(socket, why);
      }
    }
  }

  /// [socket]'s answer to its challenge. An answer is the one message a
  /// socket can send that has its signatures checked before anything has
  /// let it in, so only one that names the socket's challenge is
  /// checked, and the challenge is answered once, taken or not: a socket
  /// that answers it again is told no without a signature checked.
  async function authenticate(socket, json) {
    const a = auths.get(socket);
    if (!gate || !a) return send(socket, ['NOTICE', 'this relay asks nobody who they are']);
    const answering = !!a.challenge && Array.isArray(json?.tags) && json.tags.some((t) => Array.isArray(t) && t[0] === 'challenge' && t[1] === a.challenge);
    if (answering) a.challenge = null;
    const event = answering ? await checkEvent(json, verify) : null;
    const id = event?.id ?? (json && typeof json === 'object' && typeof json.id === 'string' ? json.id : '');
    let who = null;
    let why = null;
    if (!event || event.kind !== authKind) {
      why = 'auth-required: not an answer to this relay\'s challenge';
    } else if (Math.abs(nowS() - event.created_at) > answerFreshS) {
      why = 'auth-required: an old answer';
    } else {
      const said = await gate.admit(event);
      if (said.refused) why = said.refused;
      else if (said.account && said.epoch < epochOf(said.account)) why = epochs.get(said.account).why;
      else who = said;
    }
    const held = a.held;
    a.held = [];
    if (!who) {
      count?.('refused');
      log?.(`turned away ${event?.pubkey?.slice(0, 6) ?? '?'}: ${why}`);
      a.refused = why;
      send(socket, ['OK', id, false, why]);
      for (const raw of held) await handle(socket, raw);
      if (finalWhy(why)) cutOff(socket, why);
      return;
    }
    if (who.account) supersede(who.account, who.epoch);
    a.who = who;
    a.refused = null;
    send(socket, ['OK', id, true, '']);
    for (const raw of held) await handle(socket, raw);
  }

  /// Whether [message] from [socket] waits for its answer, or is
  /// refused for want of one; false when the socket may say it.
  function heldBack(socket, message, raw) {
    if (admitted(socket)) return false;
    let a = auths.get(socket);
    // An answer that ran out is asked for again: the device answers with
    // the activation it has been given since.
    if (a?.who) a = challenge(socket);
    if (a && !a.refused) {
      const chars = a.held.reduce((n, r) => n + r.length, raw.length);
      if (a.held.length >= heldMost || chars > heldMostChars) return send(socket, ['NOTICE', 'auth-required: answer the challenge first']), true;
      a.held.push(raw);
      return true;
    }
    const why = a?.refused ?? 'auth-required: answer the challenge first';
    if (message[0] === 'EVENT') {
      const id = message[1] && typeof message[1] === 'object' && typeof message[1].id === 'string' ? message[1].id : '';
      send(socket, ['OK', id, false, why]);
    } else if (message[0] === 'REQ' || message[0] === 'LOG') {
      send(socket, ['CLOSED', typeof message[1] === 'string' ? message[1] : '', why]);
    }
    return true;
  }

  /// Whether [socket] may publish one more event, subscribe once more,
  /// or ask for a table's log once more, now, taking it if so. The bucket refills with time;
  /// a socket that went quiet has its whole burst back.
  function spend(socket) {
    if (!limits) return true;
    const t = now();
    const bucket = buckets.get(socket) ?? { tokens: limits.burst, at: t };
    bucket.tokens = Math.min(limits.burst, bucket.tokens + ((t - bucket.at) / 1000) * limits.perSecond);
    bucket.at = t;
    buckets.set(socket, bucket);
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  async function publish(from, json) {
    // Before the signature, which is the expensive part of an event.
    if (!spend(from)) {
      count?.('rateLimited');
      const id = json && typeof json === 'object' && typeof json.id === 'string' ? json.id : '';
      return send(from, ['OK', id, false, 'rate-limited: slow down']);
    }
    const event = await checkEvent(json, verify);
    if (!event) {
      count?.('invalid');
      const id = json && typeof json === 'object' ? json.id : null;
      log?.(`rejected ${typeof id === 'string' ? id.slice(0, 6) : '?'}`);
      return send(from, ['OK', typeof id === 'string' ? id : '', false, 'invalid: bad id or signature']);
    }
    // A table's event is the referee's, and nobody else's: it goes into
    // the log, which everybody reads, and nowhere else.
    if (event.kind === logKind && table) {
      const { ok, why } = await table.take(event);
      count?.(ok ? (why ? 'duplicate' : 'events') : why.startsWith('invalid') ? 'invalid' : 'refused');
      if (!ok) log?.(`not logged ${event.id.slice(0, 6)}: ${why}`);
      return send(from, ['OK', event.id, ok, why]);
    }
    const why = viewRefusal(event) ?? (await refuse?.(event));
    if (why) {
      count?.('refused');
      log?.(`refused ${event.id.slice(0, 6)}: ${why}`);
      return send(from, ['OK', event.id, false, why]);
    }
    const held = (await screen?.(event, auths.get(from)?.who ?? null)) ?? (await withhold?.(event));
    if (held) {
      count?.('withheld');
      log?.(`withheld ${event.id.slice(0, 6)}: ${held}`);
      return send(from, ['OK', event.id, true, held]);
    }
    if (seen.has(event.id)) {
      count?.('duplicate');
      return send(from, ['OK', event.id, true, 'duplicate: already have this event']);
    }
    count?.('events');
    seen.add(event.id);
    if (!ephemeral(event.kind)) {
      const gone = store?.add(event);
      if (gone) seen.delete(gone.id);
      // And for a host that keeps it beyond this process: the object
      // writes it to its own storage (worker.mjs).
      kept?.(event, gone ?? null);
    } else if (seen.size > rememberedIds) {
      // Ephemeral ids are remembered only to answer duplicates. They
      // are the traffic, so this is the set that would grow for ever:
      // drop it back to what is stored rather than let it.
      const stored = store ? store.ids() : [];
      seen.clear();
      for (const id of stored) seen.add(id);
    }
    send(from, ['OK', event.id, true, '']);
    watching?.heard(event);
    // Written out once, not once a listener: the same text either way.
    const wire = JSON.stringify(event);
    let delivered = 0;
    for (const [socket, subscriptions] of sockets) {
      if (gate && !admitted(socket)) continue;
      for (const [id, sub] of subscriptions) {
        if (sub.filters.some((f) => matches(f, event))) {
          sendText(socket, `["EVENT",${JSON.stringify(id)},${wire}]`);
          delivered++;
          break;
        }
      }
    }
    if (delivered) count?.('delivered', delivered);
  }

  async function request(socket, message) {
    const id = message[1];
    const filters = [];
    for (const raw of message.slice(2)) {
      const parsed = parseFilter(raw);
      if (!parsed) return send(socket, ['NOTICE', 'bad filter']);
      filters.push(parsed);
    }
    // What is withheld goes from what is held before any of it is
    // served. Everything after this is said in one go, the history
    // ahead of anything published meanwhile, which the history then
    // has.
    if (withhold && store) {
      for (const event of store.matching(filters, null)) {
        if (!(await withhold(event))) continue;
        // Another socket's subscription, screened meanwhile, may have
        // let it go already.
        if (!store.drop(event.id)) continue;
        seen.delete(event.id);
        count?.('withheld');
        forget?.(event);
      }
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
    // Not read at all past the limit: parsing it is the cost.
    if (limits && raw.length > limits.message) {
      count?.('tooBig');
      return send(socket, ['NOTICE', 'too big: over this tag\'s message limit']);
    }
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      count?.('malformed');
      return send(socket, ['NOTICE', 'not JSON']);
    }
    if (!Array.isArray(message) || !message.length || typeof message[0] !== 'string') {
      count?.('malformed');
      return send(socket, ['NOTICE', 'not a message']);
    }
    if (message[0] === 'AUTH') return authenticate(socket, message[1]);
    if (gate && ['EVENT', 'REQ', 'CLOSE', 'LOG', 'TICK'].includes(message[0]) && heldBack(socket, message, raw)) return;
    switch (message[0]) {
      case 'EVENT':
        if (message.length !== 2) {
          count?.('malformed');
          return send(socket, ['NOTICE', 'EVENT takes one event']);
        }
        return publish(socket, message[1]);
      case 'REQ':
        if (message.length < 3 || typeof message[1] !== 'string') {
          count?.('malformed');
          return send(socket, ['NOTICE', 'REQ takes an id and filters']);
        }
        if (limits && raw.length > limits.request) {
          count?.('tooBig');
          return send(socket, ['NOTICE', 'too big: a subscription is carried through hibernation']);
        }
        // A subscription is answered with what the tag holds, so asking
        // costs what publishing does, as LOG does.
        if (!spend(socket)) {
          count?.('rateLimited');
          return send(socket, ['CLOSED', message[1], 'rate-limited: slow down']);
        }
        count?.('subscriptions');
        return request(socket, message);
      case 'CLOSE':
        if (message.length === 2 && typeof message[1] === 'string') {
          sockets.get(socket)?.delete(message[1]);
          table?.unfollow(socket, message[1]);
        }
        return;
      case 'LOG':
        if (message.length !== 3 || typeof message[1] !== 'string' || message[1].length > 64 || !Number.isSafeInteger(message[2]) || message[2] < 0) {
          count?.('malformed');
          return send(socket, ['NOTICE', 'LOG takes an id and the first entry wanted']);
        }
        if (!table) return send(socket, ['CLOSED', message[1], 'blocked: only a table\'s tag keeps a log']);
        // The log from where it is asked for is the most a short message
        // makes the relay send, so asking costs what publishing does.
        if (!spend(socket)) {
          count?.('rateLimited');
          return send(socket, ['CLOSED', message[1], 'rate-limited: slow down']);
        }
        return table.follow(socket, message[1], message[2], auths.get(socket)?.who?.key ?? null);
      case 'TICK':
        if (!table) return send(socket, ['NOTICE', 'blocked: only a table\'s tag keeps a log']);
        table.tick(auths.get(socket)?.who?.key ?? null);
        return;
      default:
        return send(socket, ['NOTICE', `unknown message ${message[0]}`]);
    }
  }

  return {
    /// A socket the host has accepted, with the subscriptions it was
    /// already carrying if it is one that woke from hibernation — who
    /// it had answered as, [auth], which stands while it has not run
    /// out, and the subscription it followed the table's log under,
    /// [followed].
    open(socket, carried = null, auth = null, followed = null) {
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
      if (gate) {
        if (auth && auth.until > nowS() && !(auth.account && auth.epoch < epochOf(auth.account))) {
          auths.set(socket, { challenge: null, who: auth, held: [], refused: null });
        } else {
          challenge(socket);
        }
      }
      if (typeof followed === 'string') table?.resume(socket, followed, auth?.key ?? null);
      log?.(`connected (${sockets.size})`);
    },

    /// Every socket the object held through its sleep handed back
    /// ([open]): a writer the log last said was there and now has none
    /// was cut off while the object was gone (referee.mjs, settle).
    settle() {
      table?.settle();
    },

    /// One message from [socket], in its turn behind that socket's
    /// earlier ones. The promise is for a host that wants to know when
    /// the message has been answered.
    message(socket, raw) {
      // A message that throws is a bug here, and said wherever this
      // relay says anything, or on the console where it says nothing:
      // its socket hears nothing back, so nothing else would say it.
      const turn = (turns.get(socket) ?? Promise.resolve())
        .then(() => handle(socket, raw))
        .catch((e) => (log ?? console.error)(`relay: ${e?.stack ?? e}`));
      turns.set(socket, turn);
      return turn;
    },

    close(socket) {
      table?.unfollow(socket);
      sockets.delete(socket);
      turns.delete(socket);
      buckets.delete(socket);
      auths.delete(socket);
      log?.(`closed (${sockets.size})`);
    },

    /// [account]'s device in use is now the one of [epoch]: the sockets
    /// of any device of it from before are closed, saying [why] —
    /// another device is in use, unless the account's turn says
    /// otherwise — and none is opened for one
    /// (service/functions/household.mjs).
    revoke(account, epoch, why = supersededWhy) {
      supersede(account, epoch, finalWhy(why) ? why : supersededWhy);
    },

    /// Who [socket] answered as, for it to carry through hibernation.
    authOf(socket) {
      return auths.get(socket)?.who ?? null;
    },

    /// The subscription [socket] follows the table's log under, for it
    /// to carry through hibernation, or null.
    followedBy(socket) {
      return table?.followed(socket) ?? null;
    },

    /// The table's log, on a table's tag.
    get entries() {
      return table?.entries ?? null;
    },

    /// Whether this table wants its house, and the house is not there
    /// (referee.mjs); or this pool, with somebody waiting in it
    /// (pool.mjs).
    get wantsHouse() {
      return table?.wantsHouse ?? watching?.wantsHouse ?? false;
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

/// The relay the object runs (worker.mjs), built here so that what the
/// tests build is that relay and not one set up to look like it:
/// presence keeps nothing and takes only the ephemeral kinds, a table's
/// or a lobby's tag also keeps its lobby kind, and every socket is held
/// to [objectLimits] or [tableLimits]. [withhold] and [forget] are asked
/// only where pictures are put out: a lobby's tag, never presence or the
/// results.
///
/// A table's tag keeps the table's log besides (referee.mjs): [entries]
/// is the log as kept, [keepEntry] is told of each entry added to it, to
/// write it down, and [wanted] each time the table wants its house and
/// the house is not there. [house] is this relay's house: the key a
/// sealed table's spec has to name, and the one key the results are
/// taken from.
///
/// A pool's tag is the house's to seat (pool.mjs): a seating there from
/// anybody else is withheld, and [wanted] is told each time somebody
/// waits there and the house is not there.
export function objectRelay(
  verify,
  { tag = presenceTag, now = Date.now, count = null, limits = null, store = null, kept = null, also = null, gate = null, withhold = null, screen = null, forget = null, house = null, entries = null, keepEntry = null, wanted = null, log = null } = {},
) {
  const presence = tag === presenceTag;
  const own = refusalFor(tag, { house });
  const lobby = !presence && tag !== resultsTag;
  const pool = isPoolTag(tag);
  return createRelay({
    verify,
    gate,
    log,
    referee: tableTag.test(tag) ? ({ send, admitted }) => tableReferee({ table: tag, verify, house, now, entries: entries ?? [], keep: keepEntry, wanted, send, admitted }) : null,
    watcher: pool ? ({ holds }) => poolWatch({ house, here: () => holds(house), wanted, now }) : null,
    // Presence keeps nothing; a table's tag keeps its lobby.
    store: presence ? null : (store ?? memoryStore(storedKeep(tag))),
    kept: presence ? null : kept,
    withhold: lobby ? (pool ? (event) => seatingHeld(event, house) ?? withhold?.(event) ?? null : withhold) : null,
    screen: lobby ? screen : null,
    forget: lobby ? forget : null,
    // [also]: a test's own policy on top, asked only of what the object
    // itself takes (host.mjs, --object --control).
    refuse: also ? (event) => own(event) ?? also(event) : own,
    limits: limits ?? (presence ? objectLimits : tableLimits),
    now,
    count,
  });
}

/// The one tag presence rides on (packages/table, presence_relay.dart).
export const presenceTag = 'online';

/// What a log says of [tag]: presence, a pool's queue, a room, or a
/// table by the first eight of its id. A table's id is its address (the
/// table's spec.dart, newTableId), so not all of it; a room's code lets
/// anybody in, so none of it.
export function tagLabel(tag) {
  if (tag === presenceTag) return 'presence';
  if (typeof tag !== 'string') return 'unknown';
  if (isPoolTag(tag)) return 'queue';
  if (tableTag.test(tag)) return `table:${tag.slice(0, 8)}`;
  return 'room';
}

/// One line for the operator's logs as a socket on [tag] comes and goes
/// ([what]: open, close, error), for laying a device's account of its
/// line beside the relay's (docs/how-to/look-into-a-lost-game.md): the
/// kind of tag, whether the socket answered as a device or the house
/// ([who], the gate's answer), how it closed, how long it was
/// open, and how many sockets the tag has left. Nothing about who:
/// presence is not kept, and neither is anybody's coming and going.
export function socketLine(what, { tag, who = null, code, clean, why, openedAt, sockets, now = Date.now() }) {
  return {
    relay: what,
    tag: tagLabel(tag),
    as: who ? (who.account ? 'device' : 'house') : 'unanswered',
    ...(code === undefined ? {} : { code, clean: clean === true }),
    ...(why ? { why: String(why).slice(0, 80) } : {}),
    ...(typeof openedAt === 'number' ? { openS: Math.round((now - openedAt) / 1000) } : {}),
    sockets,
  };
}

/// The tag game results are written under (packages/table, results.dart,
/// GameResult.tag): kept, since the ratings are folded from all of them.
/// Everything else stored is kept a day (worker.mjs, the sweep).
/// tag_store.test.mjs holds it to the table package's.
export const resultsTag = 'standings';

/// How many stored events a tag's object holds in memory. A room or a
/// pool's lobby is a handful; the results are every game's, folded by
/// every device that loads its rating — 20,000 is some 20 MB, well
/// inside an object's memory, and the point at which ratings should be
/// folded by the service rather than by every device.
export const storedKeep = (tag) => (tag === resultsTag ? 20000 : 2000);

/// The most an event a tag stores may weigh, in bytes as the object
/// holds it ([storedWeight]). The longest a device stores is a picture,
/// PROFILE_PICTURE_MOST bytes in base64 (some 16,000 characters); a
/// seating of four is a few thousand, and a result less. So a room's or
/// a pool's object holds its [storedKeep] in some 50 MB at the most,
/// inside the 128 MB an object has. Held only to [tableLimits]'
/// message, one subscriber's 2,000 events would be twice that or more,
/// and the object would fail each time it woke and read them back.
export const storedMost = 24 * 1024;

/// What [event] weighs against [storedMost]: its JSON's length, and
/// twice that once any character in it is past U+00FF, since V8 then
/// holds the string at two bytes a character.
export function storedWeight(event) {
  const json = JSON.stringify(event);
  return /[^\u0000-\u00ff]/.test(json) ? json.length * 2 : json.length;
}

/// A player's quick reaction at a live table (packages/table,
/// reactions.dart): 👍, 😬 and the rest, as a short code and the moment
/// it was said at, `{"react":"nice","hand":2,"turn":17}`. Ephemeral, so
/// forwarded and forgotten like the table's own events; never free
/// text, so there is nothing in one to read but its shape.
export const reactionKind = 24248;

/// The longest a reaction's content is, in characters: some thirty
/// is what one says.
export const reactionMost = 128;

/// Why this [tag]'s object does not carry [event], a reaction, or null
/// when it does: on a table's own tag, tagged with that table and
/// nothing else, small, and the shape a reaction is. The codes are
/// not listed here — a screen shows only those it knows — so a new one
/// needs no relay to learn it; the shape is what keeps words out.
export function reactionRefusal(tag, event) {
  if (!tableTag.test(tag)) return 'blocked: a reaction rides a table\'s own tag';
  const [t, ...rest] = event.tags ?? [];
  if (rest.length || !t || t.length !== 2 || t[0] !== 't' || t[1] !== tag) return `blocked: a reaction is tagged with its table, ${tag}, and nothing else`;
  if (event.content.length > reactionMost) return 'invalid: too big for a reaction';
  let said = null;
  try {
    said = JSON.parse(event.content);
  } catch {
    // Not JSON: not a reaction.
  }
  const shaped =
    !!said &&
    typeof said === 'object' &&
    !Array.isArray(said) &&
    Object.keys(said).length === 3 &&
    typeof said.react === 'string' &&
    /^[a-z]{1,16}$/.test(said.react) &&
    Number.isInteger(said.hand) &&
    said.hand >= 0 &&
    said.hand <= 9999 &&
    Number.isInteger(said.turn) &&
    said.turn >= 0 &&
    said.turn <= 52;
  return shaped ? null : 'invalid: a reaction is a code and the moment it was said at';
}

/// The kinds whose content names players (packages/table, nostr.dart,
/// TableKinds): the lobby, waiting in a pool or a room, and a watched
/// table.
const namingKinds = new Set([lobbyKind, waitingKind, watchKind]);

/// [event]'s content as an object, for a kind that names players, or
/// null.
function namingContent(event) {
  if (!namingKinds.has(event.kind)) return null;
  try {
    const said = JSON.parse(event.content);
    return said && typeof said === 'object' ? said : null;
  } catch {
    return null;
  }
}

/// The names [event] shows the others: its content's `name` (waiting),
/// each of its seats' (a table started or seated), its `names`, and a
/// watched table's, which a seated player says as `{"view": {"names":
/// [...]}}` (packages/table, watch.dart).
export function namesIn(event) {
  const said = namingContent(event);
  if (!said) return [];
  const names = [];
  if (typeof said.name === 'string') names.push(said.name);
  for (const seat of Array.isArray(said.seats) ? said.seats : []) if (typeof seat?.name === 'string') names.push(seat.name);
  for (const list of [said.names, said.view?.names]) {
    for (const name of Array.isArray(list) ? list : []) if (typeof name === 'string') names.push(name);
  }
  return names;
}

/// Whether [event] carries a picture inside an avatar — its own, or a
/// seat's — rather than as a picture of its own (`{"kind":"picture"}`),
/// the one way the app sends one, where the operator's take-downs
/// (withheld.mjs) and copies (review.mjs) see it.
export function pictureInAvatar(event) {
  const said = namingContent(event);
  if (!said) return false;
  const carries = (avatar) => !!avatar && typeof avatar === 'object' && 'picture' in avatar;
  return carries(said.avatar) || (Array.isArray(said.seats) && said.seats.some((seat) => carries(seat?.avatar)));
}

/// Why an event with a picture inside an avatar is not carried.
export const PICTURE_IN_AVATAR_WHY = 'blocked: a picture travels as its own event';

/// Why a result said by anybody but the house is not taken.
export const RESULT_NOT_HOUSE_WHY = 'blocked: a result is the house\'s word';

/// Why an event naming somebody as the filter refuses is not carried
/// (service/functions/names.mjs): the app never sends one.
export const NAME_REFUSED_WHY = 'blocked: a name that is not allowed';

/// An event to be stored that weighs more than [storedMost].
export const STORED_TOO_BIG_WHY = 'too big: a stored event is longer than this relay keeps';

/// Why a view of a table said by a key that holds no seat at it is not
/// carried.
export const VIEW_NOT_SEATED_WHY = 'blocked: a view of the table is one of its people\'s to say';

/// What a tag's object refuses. Presence: anything but the ephemeral
/// kinds. A table's or a lobby's tag: anything but the ephemeral kinds
/// and the lobby kind tagged for this very tag — an object stores what
/// belongs to it, and nobody writes into one tag's store through
/// another's. A reaction anywhere but a table's own tag, or in any
/// shape but a reaction's ([reactionRefusal]). An event to be stored
/// that weighs more than [storedMost]. And anything that shows
/// the others a name the filter refuses ([namesIn]), or a picture
/// anywhere but in a picture of its own ([pictureInAvatar]).
///
/// The results are the house's to say ([house], its key): a game's
/// result is the house's word on a game it refereed (packages/table,
/// results.dart), and nothing new is taken from anybody else — with no
/// house, from nobody.
export function refusalFor(tag, { house = null } = {}) {
  return (event) => {
    if (event.kind === reactionKind) return reactionRefusal(tag, event);
    if (tag === resultsTag && event.pubkey !== house) return RESULT_NOT_HOUSE_WHY;
    const carried = ephemeral(event.kind) || (tag !== presenceTag && event.kind === lobbyKind && event.tags?.some((t) => t[0] === 't' && t[1] === tag));
    if (!carried) {
      return tag === presenceTag
        ? 'blocked: presence carries ephemeral kinds only'
        : `blocked: this tag stores only kind ${lobbyKind}, tagged ${tag}`;
    }
    if (!ephemeral(event.kind) && storedWeight(event) > storedMost) return STORED_TOO_BIG_WHY;
    if (pictureInAvatar(event)) return PICTURE_IN_AVATAR_WHY;
    return namesIn(event).some(nameRefused) ? NAME_REFUSED_WHY : null;
  };
}

/// A table's tag carries what presence does not: a deal's steps of up
/// to some tens of kilobytes, in bursts at the deal, and every side
/// asking for the log again from where it is whenever its socket comes
/// back. Measured against real tables through this relay
/// (docs/explanation/relay.md); presence keeps [objectLimits].
export const tableLimits = Object.freeze({
  message: 128 * 1024,
  request: 1024,
  burst: 200,
  perSecond: 20,
});

/// The numbers in each line an object writes, in the order the
/// operator's query reads them (docs/explanation/service.md): what it
/// has seen since its last line, and the seconds that covers. Counts,
/// never who. A count added later goes at the end, so that no column
/// moves: `withheld` comes after the seconds.
export const tallied = ['opened', 'closed', 'events', 'delivered', 'subscriptions', 'rateLimited', 'invalid', 'refused', 'duplicate', 'tooBig', 'malformed', 'superseded', 'seconds', 'withheld'];
const counted = tallied.filter((k) => k !== 'seconds');

/// [fn] in [ms], as a cancel: a timer node does not wait for, so a
/// test's tally does not hold its process open.
function later(fn, ms) {
  const timer = setTimeout(fn, ms);
  timer?.unref?.();
  return () => clearTimeout(timer);
}

/// A tally kept in memory and written as one line of numbers to [sink],
/// an Analytics Engine dataset or nothing: a minute after the line
/// before it, and at once when the object's last socket goes. A line a
/// message would be a line every two seconds for every device online,
/// for presence alone; a line a minute is one per tag that is in use,
/// and one more for each time a tag's last socket closes.
/// While counts wait, a timer waits with them to write them at their
/// minute: an object whose sockets are open hibernates once nothing is
/// pending, and what it holds in memory goes with it.
export function tally(sink, { every = 60000, now = Date.now, after = later } = {}) {
  let counts = Object.fromEntries(counted.map((k) => [k, 0]));
  let since = now();
  let pending = null;
  const flush = () => {
    pending?.();
    pending = null;
    const t = now();
    if (sink && counted.some((k) => counts[k] > 0)) {
      try {
        sink.writeDataPoint({ indexes: ['relay'], blobs: ['relay'], doubles: tallied.map((k) => (k === 'seconds' ? (t - since) / 1000 : counts[k])) });
      } catch {
        // What is watched never stops what is watched.
      }
    }
    counts = Object.fromEntries(counted.map((k) => [k, 0]));
    since = t;
  };
  const count = (what, n = 1) => {
    if (!(what in counts)) return;
    counts[what] += n;
    if (now() - since >= every) flush();
    else if (sink && !pending) pending = after(flush, since + every - now());
  };
  return {
    count,
    /// A socket gone, with [left] still open: when it was the last, the
    /// counts so far are written at once, since an object with nobody
    /// on it may be evicted before its minute is up and take them with it.
    closed(left) {
      count('closed');
      if (left === 0) flush();
    },
    flush,
    get counts() {
      return { ...counts };
    },
  };
}
