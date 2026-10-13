// Local mode, its open house, and the numbers the service runs by
// (docs/explanation/service.md).

import { storeOf } from './rows.mjs';

/// Whether [url] is this machine: local mode, `wrangler pages dev` and
/// the browser suites' rig. What only a dev machine may do is decided
/// by where the request went, not by a setting alone — a setting left
/// on in production is then a setting that does nothing.
export function isLocal(url) {
  try {
    const host = new URL(url).hostname;
    return host === 'localhost' || host === '127.0.0.1' || host.endsWith('.localhost');
  } catch {
    return false;
  }
}

/// Local mode's open house (docs/explanation/service.md): every device that asks
/// licensed, and `local:` sign-ins taken. Only where it is set and only
/// on this machine: set in a production project by mistake, it would
/// license everyone and let anybody sign in as anybody.
export const openHouse = (env, request) => !!env.OH_OPEN_HOUSE && isLocal(request.url);

// ---- The service's own settings ---------------------------------------
//
// The numbers the service runs by — how long a licence lasts, how many
// devices a subscription carries, how long a code is good for, which
// Stripe price a checkout sells — read from one row the operator
// writes, `config|service` in OH_STORE (docs/explanation/service.md). Not the
// app's row: nothing here is served to anybody.
// Each is checked against bounds before it is taken, and one that does
// not check out is left at its default, so a typo in the row is never
// worse than no row.

/// The defaults: what the service runs by when the row is absent.
export const SERVICE_DEFAULTS = Object.freeze({
  licenceDays: 31,
  mostDevices: 5,
  // How long a code is worth anything: long enough to walk a phone
  // over, short enough that a photograph of the screen is not a key.
  ticketMinutes: 10,
  // How long an outstanding code must still have to be handed out
  // again rather than replaced.
  ticketReuseMinutes: 2,
  turnTtlS: 4 * 60 * 60,
  // How far a request's second may be from ours: clocks drift, and a
  // phone out by more than this is told so — in words that say five
  // minutes, which the app knows the refusal by (app/lib/net/
  // household.dart): a change here is a change there.
  requestToleranceS: 300,
  // How old a webhook's own timestamp may be: a replay is not a payment.
  webhookToleranceS: 300,
  // What one account may do in an hour: changes (a code, a claim, a
  // drop) and readings of its list. Adding a phone takes a handful.
  householdChangesPerHour: 20,
  householdReadsPerHour: 60,
  // What one account's devices may ask of the account's turn in an hour
  // to be the one in use, or the relay on their behalf: an opening, a
  // renewal every twenty minutes, a word at each table sat at, and the
  // relay asking at every socket a device opens.
  activationsPerHour: 600,
  // How often one account's profile may be written in an hour: the app
  // writes it once each time the profile page is left changed, so this
  // is a person changing their mind a good many times — and it has an
  // allowance of its own, so that it never spends the one a code or a
  // claim needs.
  profileWritesPerHour: 30,
  // How many finished games one account may send to be kept in an
  // hour: a game is ten minutes at the quickest, and a device that
  // misses the answer sends again.
  recordsPerHour: 12,
  stripePrice: null,
});

/// Least and most for each number, whole numbers only. The edges are
/// where a setting stops being a tuning and becomes a hole: a licence
/// past a year outlives the subscription, a clock skew past fifteen
/// minutes makes a captured request good for longer than any device
/// needs.
export const SERVICE_BOUNDS = Object.freeze({
  licenceDays: [1, 62],
  mostDevices: [1, 10],
  ticketMinutes: [1, 60],
  ticketReuseMinutes: [0, 30],
  turnTtlS: [600, 24 * 60 * 60],
  requestToleranceS: [30, 900],
  webhookToleranceS: [60, 900],
  householdChangesPerHour: [5, 500],
  householdReadsPerHour: [10, 2000],
  activationsPerHour: [60, 6000],
  profileWritesPerHour: [5, 300],
  recordsPerHour: [2, 120],
});

/// The row, checked: every field that checks out, the default for the
/// rest.
export function serviceSettingsOf(raw) {
  const c = { ...SERVICE_DEFAULTS };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return c;
  for (const [name, [least, most]] of Object.entries(SERVICE_BOUNDS)) {
    const v = raw[name];
    if (Number.isInteger(v) && v >= least && v <= most) c[name] = v;
  }
  // A code handed back again has to have the time left to be used.
  if (c.ticketReuseMinutes >= c.ticketMinutes) c.ticketReuseMinutes = Math.min(SERVICE_DEFAULTS.ticketReuseMinutes, c.ticketMinutes - 1);
  if (typeof raw.stripePrice === 'string' && STRIPE_PRICE.test(raw.stripePrice)) c.stripePrice = raw.stripePrice;
  return c;
}

/// Where the row lives: `config|service` in OH_STORE.
const SERVICE_ROW = ['config', 'service'];

/// How long an isolate goes by the row before it reads it again.
const SETTINGS_KEPT_MS = 60 * 1000;

let settings = SERVICE_DEFAULTS;
let settledAt = -Infinity;

/// What the service runs by now.
export const S = () => settings;

/// Reads the row if this isolate has not lately; a store that is down,
/// or no store, is the defaults. Called at the top of every request.
export async function settle(env, { now = Date.now() } = {}) {
  if (now - settledAt < SETTINGS_KEPT_MS) return settings;
  settledAt = now;
  let raw = null;
  try {
    raw = (await storeOf(env)?.get(...SERVICE_ROW)) ?? null;
  } catch {
    // Unreadable is the same as absent: the defaults.
  }
  settings = Object.freeze(serviceSettingsOf(raw));
  return settings;
}

/// For a test: these settings, until the next [settle] that reads.
export function useSettings(next = {}) {
  settings = Object.freeze({ ...SERVICE_DEFAULTS, ...next });
  settledAt = Infinity;
}

/// For a test: back to the defaults, and the next request reads the row.
export function forgetSettings() {
  settings = SERVICE_DEFAULTS;
  settledAt = -Infinity;
}

/// What the service says when it is missing [what] it needs — a
/// binding or a secret, by name, so the one deploying it knows which.
export const notConfigured = (what) => ({ error: `service not configured: ${what}` });

/// What names the price a checkout sells: its id (`price_…`), or its
/// lookup key, which is the same in test mode and live and moves to a
/// new price in the dashboard with nothing changed here.
export const STRIPE_PRICE = /^(price_[A-Za-z0-9]{1,64}|(?!price_)[A-Za-z0-9_.:-]{1,200})$/;

/// The site, where the terms, the privacy policy and the support page
/// are: what an email or Stripe's checkout sends a person to. Not the
/// app's host, which answers every path with the game.
export const SITE = 'https://openhearts.game';
