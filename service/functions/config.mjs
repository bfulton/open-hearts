// Remote config: what the app reads at /api/config, from the operator's
// row (docs/reference/configuration.md).

/// What the app may be told without a new build (docs/explanation/service.md):
/// one row in the store, which the operator writes and every device
/// reads at its start. What is here when there is no row — or a
/// row this worker cannot read — is what the app does with no config at
/// all, so a bad row is never worse than none.
export const CONFIG_DEFAULTS = Object.freeze({ v: 1, live: true, offer: true, relays: null, banner: null, update: null, feedback: null });

/// Where the row lives: `config|app` in OH_STORE.
export const CONFIG_ROW = ['config', 'app'];

const MOST_RELAYS = 8;
const LONGEST_SAY = 280;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/// A sentence in each language it is given in, English required: the
/// app shows the device's language where it is there and English where
/// it is not. Anything else is no sentence at all.
function sayingOf(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = {};
  for (const [lang, text] of Object.entries(raw)) {
    if (!/^[a-z]{2}$/.test(lang) || typeof text !== 'string') continue;
    const t = text.trim();
    if (t && t.length <= LONGEST_SAY) out[lang] = t;
  }
  return out.en ? out : null;
}

/// The row as the app may be given it: every field checked, and any
/// that does not check out left at its default rather than passed on.
export function configOf(raw) {
  const c = { ...CONFIG_DEFAULTS };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return c;
  // The doors to live play: a kill switch, and whether the paid tier is
  // offered at all to a device that has not bought it.
  if (typeof raw.live === 'boolean') c.live = raw.live;
  if (typeof raw.offer === 'boolean') c.offer = raw.offer;
  // Which relays the tables meet on, in place of the build's. wss only:
  // these carry every live game, and a relay over plain ws would carry
  // them in the open. And ours only (docs/explanation/relay.md): this is the
  // way to move the tables to another relay of ours without a release,
  // never the way back to a public one.
  if (Array.isArray(raw.relays) && raw.relays.length > 0 && raw.relays.length <= MOST_RELAYS) {
    const relays = [];
    for (const r of raw.relays) {
      const u = urlOf(r);
      const ours = u && (u.hostname === 'openhearts.game' || u.hostname.endsWith('.openhearts.game'));
      if (ours && u.protocol === 'wss:' && !u.username && !u.password) relays.push(u.toString().replaceAll('%7Btag%7D', '{tag}'));
    }
    if (relays.length === raw.relays.length) c.relays = relays;
  }
  // A line across the front door: a maintenance window, an outage.
  if (raw.banner && typeof raw.banner === 'object') {
    const text = sayingOf(raw.banner.text);
    const id = typeof raw.banner.id === 'string' && /^[\w.-]{1,64}$/.test(raw.banner.id) ? raw.banner.id : null;
    if (text && id) c.banner = { id, level: raw.banner.level === 'warn' ? 'warn' : 'info', text };
  }
  // Please update: a build made before this day is asked to.
  if (raw.update && typeof raw.update === 'object' && typeof raw.update.before === 'string' && DAY.test(raw.update.before)) {
    c.update = { before: raw.update.before, text: sayingOf(raw.update.text) };
  }
  // Where a player's "tell us what's broken" goes: a page, or mail.
  const feedback = urlOf(raw.feedback);
  if (feedback) {
    const page = feedback.protocol === 'https:' && !feedback.username && !feedback.password;
    const mail = feedback.protocol === 'mailto:' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(feedback.pathname);
    if (page || mail) c.feedback = feedback.toString();
  }
  // The clocks of the tables a device starts, and of those the house
  // seats in the pools (service/do/bench.mjs): served only where the
  // whole of it checks out, and left out otherwise, which the app and
  // the house read as the standard table.
  const table = tableTimingOf(raw.table);
  if (table) c.table = table;
  const waits = waitsOf(raw.waits);
  if (waits) c.waits = waits;
  // How long Play live waits before it seats a device again, after it
  // left a game with other people still playing: whole minutes, zero
  // for none. Served only when set; the app has its own (five).
  const [least, most] = LEFT_EARLY_BOUNDS;
  if (Number.isInteger(raw.leftEarlyMin) && raw.leftEarlyMin >= least && raw.leftEarlyMin <= most) c.leftEarlyMin = raw.leftEarlyMin;
  return c;
}

/// [text] as a URL, or null where it is not text or not a URL: what an
/// operator's row says is checked, and a URL that does not parse is one
/// that is left out.
function urlOf(text) {
  if (typeof text !== 'string') return null;
  try {
    return new URL(text);
  } catch (e) {
    if (e instanceof TypeError) return null;
    throw e;
  }
}

/// Least and most for `leftEarlyMin`, in minutes: the bounds the app
/// parses it by (app/lib/net/remote_config.dart, RemoteConfig.leftEarlyBounds).
export const LEFT_EARLY_BOUNDS = Object.freeze([0, 60]);

/// How long a device waits on the network, each field least and most:
/// the bounds the app parses them by (app/lib/net/remote_config.dart,
/// AppWaits.bounds). Milliseconds, minutes for configEveryMin.
export const WAITS_BOUNDS = Object.freeze({
  licenceMs: [2000, 30000],
  householdMs: [3000, 30000],
  buyMs: [3000, 60000],
  turnMs: [2000, 30000],
  configMs: [2000, 30000],
  configEveryMin: [5, 240],
  relaySlowMs: [3000, 30000],
  relayGiveUpMs: [15000, 180000],
  standingMs: [3000, 30000],
  standingAllMs: [1000, 20000],
  roomStartMs: [3000, 60000],
  recordMs: [5000, 120000],
  recordAgainMs: [1000, 30000],
  recordForMs: [10000, 600000],
  recordSoonMs: [2000, 60000],
});

/// The waits a device goes by where the row sets none: the app's own
/// (app/lib/net/remote_config.dart, the AppWaits constructor). A field
/// the row leaves out is compared at these. Milliseconds, minutes for
/// configEveryMin.
export const WAITS_DEFAULTS = Object.freeze({
  licenceMs: 6000,
  householdMs: 10000,
  buyMs: 12000,
  turnMs: 5000,
  configMs: 8000,
  configEveryMin: 15,
  relaySlowMs: 8000,
  relayGiveUpMs: 40000,
  standingMs: 8000,
  standingAllMs: 4000,
  roomStartMs: 10000,
  recordMs: 30000,
  recordAgainMs: 3000,
  recordForMs: 60000,
  recordSoonMs: 9000,
});

/// The waits the row sets, each field taken on its own when it is a
/// whole number within its bounds; null when none is. The relay's pair
/// goes together or not at all: saying it is slow comes before giving up.
/// So do the record's three: asking again comes within both spans it is
/// asked over.
export function waitsOf(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = {};
  for (const [name, [least, most]] of Object.entries(WAITS_BOUNDS)) {
    const v = raw[name];
    if (Number.isInteger(v) && v >= least && v <= most) out[name] = v;
  }
  if ('relaySlowMs' in out || 'relayGiveUpMs' in out) {
    const slow = out.relaySlowMs ?? WAITS_DEFAULTS.relaySlowMs;
    const giveUp = out.relayGiveUpMs ?? WAITS_DEFAULTS.relayGiveUpMs;
    if (slow >= giveUp) {
      delete out.relaySlowMs;
      delete out.relayGiveUpMs;
    }
  }
  if ('recordAgainMs' in out || 'recordForMs' in out || 'recordSoonMs' in out) {
    const again = out.recordAgainMs ?? WAITS_DEFAULTS.recordAgainMs;
    if (again > (out.recordForMs ?? WAITS_DEFAULTS.recordForMs) || again > (out.recordSoonMs ?? WAITS_DEFAULTS.recordSoonMs)) {
      delete out.recordAgainMs;
      delete out.recordForMs;
      delete out.recordSoonMs;
    }
  }
  return Object.keys(out).length ? out : null;
}

/// What each of a table's clocks may be, in milliseconds, least and
/// most: the same bounds the table package parses a start event by
/// (packages/table/lib/src/timing.dart, TableTiming.bounds).
export const TABLE_TIMING_BOUNDS = Object.freeze({
  graceMs: [2000, 60000],
  passGraceMs: [2000, 120000],
  bankMs: [10000, 300000],
  fixedMs: [15000, 120000],
  botActsMs: [5000, 60000],
  botDealsMs: [15000, 120000],
  houseGraceMs: [10000, 120000],
  silenceMs: [10000, 600000],
});

/// A table's timing as the operator wrote it, or null: all or nothing,
/// as a seat reads it — one field of the wrong type or out of bounds,
/// and none of it is served. Names it does not know are dropped.
function tableTimingOf(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = {};
  for (const [name, [least, most]] of Object.entries(TABLE_TIMING_BOUNDS)) {
    if (!(name in raw)) continue;
    const v = raw[name];
    if (!Number.isInteger(v) || v < least || v > most) return null;
    out[name] = v;
  }
  return Object.keys(out).length ? out : null;
}
