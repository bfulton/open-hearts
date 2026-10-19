// One account at a time: the Household object, the account's own turn,
// where everything that changes an account runs one after another, and
// which of its devices is in use. The relay worker runs the object
// (service/do/worker.mjs), so it imports this module and what it needs,
// and nothing of the handlers; they ask the object (inHousehold).

import {
  accountOfKey,
  backupsFor,
  backupsMade,
  claimWith,
  devicesOn,
  entitlementOf,
  joinAccount,
  redeemBackup,
  ticketFor,
} from './accounts.mjs';
import { sendAlert } from './alerts.mjs';
import { deleteAccount } from './deletion.mjs';
import { attest, unlinkSignIn } from './logins.mjs';
import { sendNotice } from './notices.mjs';
import { profileRead, profileWritten } from './profile.mjs';
import { storeOf } from './rows.mjs';
import { S, SITE, notConfigured, settle } from './settings.mjs';
import { bindPurchase } from './subscriptions.mjs';
import { SUSPENDED_WHY, carryOut } from './suspension.mjs';

// ---- one device at a time ------------------------------------------------
// An account is a person, and a person plays on one device at a time
// (docs/explanation/service.md). Which one is the service's to say, in the
// account's own turn ([inHousehold]): the newest device to take the
// account up is the one in use, at once, and the one before it is
// superseded. What the device in use is given is an activation: the
// account, the device, how many times the account has been taken up
// (the epoch) and when it runs out, signed by the service. The relay
// holds every socket to one (service/do/relay.mjs): it carries no
// device without a current activation, asks the account's turn whether
// one is still current when a socket shows it, and is told by the
// account's turn to close a device's sockets the moment it is
// superseded.

/// How long the device in use is taken to still be in use without
/// asking again: two renewals and some.
export const IN_USE_MS = 45 * 60 * 1000;

/// How long a device's word that it is at a table counts for.
export const SEATED_MS = 3 * 60 * 60 * 1000;

/// How many relay objects one activation is remembered at: what is told
/// to close when it is superseded. A device opens a socket for
/// presence, a pool or a room, a table and its results; past this the
/// oldest are forgotten, and their sockets last out their activation's
/// hour.
const MOST_TAGS = 32;

/// Where the account's device in use is written down: in the account's
/// own object's storage where it runs in one (Household, below), and in
/// the store otherwise.
export const activeInStore = (store) => ({
  get: (account) => store.get(`ACCOUNT#${account}`, 'ACTIVE'),
  put: (account, row) => store.put(`ACCOUNT#${account}`, 'ACTIVE', row),
});

/// A device asking to be the account's in use, in the account's turn:
/// {status, body}. [op.want] is `open` — the app coming up: take the
/// account, unless the device in use is at a table, which is asked
/// about first — `take` — the person said so: whatever the other is
/// doing — or `renew` — still in use: never takes anything. [op.seated]
/// is the table the device is at, or null for none, when it says.
/// [revoke] tells the relay objects the superseded device was seen at.
export async function activate(op, store, active, { now = Date.now(), revoke = null } = {}) {
  const { key, account } = op;
  const held = await entitlementOf(store, key, { now });
  if (!held || held.account !== account || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${key}`))) {
    // A suspended account's device is told so, as the licence handler
    // tells it, so that one the relay's word missed shuts live play at
    // its next renewal.
    if ((await store.get(`KEY#${key}`, 'ENTITLEMENT'))?.suspended) return { status: 403, body: { error: SUSPENDED_WHY, suspended: true } };
    return { status: 402, body: { error: 'no subscription' } };
  }
  const seated = op.seated === undefined ? undefined : typeof op.seated === 'string' && /^[0-9a-f]{32}$/.test(op.seated) ? op.seated : null;
  const was = (await active.get(account)) ?? { key: null, epoch: 0, tags: [] };
  if (was.key === key) {
    await active.put(account, { ...was, at: now, ...(seated !== undefined ? { seated, seated_at: now } : {}) });
    return { status: 200, body: { epoch: was.epoch, licensed_until: held.licensed_until, profile: await profileVersion(store, account) } };
  }
  if (op.want === 'renew') return { status: 409, body: { error: 'superseded: another device of this account is in use', superseded: true } };
  const inUse = was.key !== null && now - (was.at ?? 0) < IN_USE_MS;
  const playing = inUse && !!was.seated && now - (was.seated_at ?? 0) < SEATED_MS;
  if (op.want !== 'take' && playing) return { status: 409, body: { error: 'in a game on another device', seated: true } };
  const epoch = (was.epoch ?? 0) + 1;
  await active.put(account, { key, epoch, at: now, seated: seated ?? null, seated_at: now, tags: [] });
  if (was.tags?.length) await revoke?.(was.tags, account, epoch);
  return { status: 200, body: { epoch, licensed_until: held.licensed_until, took: was.key !== null, profile: await profileVersion(store, account) } };
}

/// The version of [account]'s profile, 0 for none: said with each
/// activation, so that the device in use takes a change it did not make
/// — the operator's (suspension.mjs, remove and restore) — at its next
/// renewal rather than its next start (app/lib/net/account_profile.dart).
const profileVersion = async (store, account) => (await store.get(`ACCOUNT#${account}`, 'PROFILE'))?.version ?? 0;

/// The relay asking whether [op.key] is still the account's device in
/// use at [op.epoch], as it opens a socket for it on [op.tag]: yes, and
/// the tag is remembered, to be told when that ends; or no, and why —
/// a suspended account's device is told so, not that another of its
/// devices is in use.
export async function seenAt(op, active) {
  const was = await active.get(op.account);
  if (was?.suspended) return { status: 409, body: { error: SUSPENDED_WHY } };
  if (!was || was.key !== op.key || was.epoch !== op.epoch) {
    return { status: 409, body: { error: 'superseded: another device of this account is in use' } };
  }
  if (typeof op.tag === 'string' && op.tag && !(was.tags ?? []).includes(op.tag)) {
    await active.put(op.account, { ...was, tags: [...(was.tags ?? []), op.tag].slice(-MOST_TAGS) });
  }
  return { status: 200, body: { ok: true } };
}

/// Whether [op.key] is the account's device in use, and not seated at
/// [op.table]: who a finished game's record is shown to (records.mjs).
export async function inUse(op, active, { now = Date.now() } = {}) {
  const was = await active.get(op.account);
  if (!was || was.key !== op.key) return { status: 409, body: { error: 'superseded: another device of this account is in use' } };
  if (op.table && was.seated === op.table && now - (was.seated_at ?? 0) < SEATED_MS) {
    return { status: 403, body: { error: 'not a game your own account is playing' } };
  }
  return { status: 200, body: { ok: true } };
}

/// A device dropped from its account while it was the one in use: no
/// device is, from here, and the relay closes its sockets now rather
/// than at the end of its activation's hour.
async function dropActive(account, device, active, revoke) {
  const was = await active.get(account);
  if (!was || was.key !== device) return;
  const epoch = (was.epoch ?? 0) + 1;
  await active.put(account, { key: null, epoch, at: null, seated: null, tags: [] });
  if (was.tags?.length) await revoke?.(was.tags, account, epoch);
}

/// Dropping a device: any device of the account can drop any other, its
/// own self included — which is how a device is handed on. A device
/// dropped while it was the one in use is cut off at the relay at once.
export async function dropDevice(key, device, store, { now = Date.now(), active = null, revoke = null } = {}) {
  const account = await accountOfKey(store, key);
  if (!account) return { status: 402, body: { error: 'no subscription' } };
  const devices = await devicesOn(store, account);
  if (!devices.some((d) => d.key === device)) return { status: 404, body: { error: 'not a device on this subscription' } };
  await store.del(`ACCOUNT#${account}`, `DEVICE#${device}`);
  // And the entitlement that device holds, which is gone rather than
  // run out: a licence is one read, and a row saying it is paid up to
  // next year would be that read. Its own copy of the date is not the
  // only thing that would say so — a row dated today falls through to
  // the account on the next ask, and the account is still paid up. It
  // is the binding that ended, so the binding is what goes.
  const theirs = await store.get(`KEY#${device}`, 'ENTITLEMENT');
  if (theirs?.account === account) await store.del(`KEY#${device}`, 'ENTITLEMENT');
  if (active) await dropActive(account, device, active, revoke);
  return { status: 200, body: { devices: (await devicesOn(store, account)).length, most: S().mostDevices } };
}

// ---- one account at a time ----------------------------------------------
// A code made, a code spent, a device dropped, the list read, a device
// taking the account up: each reads the account and writes it in
// separate calls, and KV has no compare-and-set, so two at once could
// both find room for a fifth device and make six
// (docs/explanation/security-model.md), or both be the device in use. They run one
// after another per account instead: in a Durable Object per account
// where the project binds one as HOUSEHOLD (one object, one thread,
// wherever in the world the requests come from), and in this isolate's
// own queue where it does not — which covers requests that land
// together on one isolate and no more. The same place keeps an account
// to so many of them an hour, which is what keeps one subscriber from
// spending the store's daily writes and lists. A subscription's own
// turn — its account found or made — is an object of its own, named
// `sub:` and the subscription.

/// One household's queue and its hour: everything asked of it runs in
/// order, and what is over the hour's allowance is refused before it
/// touches the store.
export function sequencer({ now = Date.now } = {}) {
  let queue = Promise.resolve();
  const done = { change: [], read: [] };
  return (kind, work) => {
    const run = queue.then(async () => {
      const t = now();
      const recent = (done[kind] = (done[kind] ?? []).filter((at) => t - at < 3600000));
      // An operator's order (suspension.mjs) is never held back by what
      // the account's own devices have asked for this hour.
      const most =
        kind === 'order'
          ? Infinity
          : kind === 'read'
          ? S().householdReadsPerHour
          : kind === 'active'
            ? S().activationsPerHour
            : kind === 'profile'
              ? S().profileWritesPerHour
              : kind === 'record'
                ? S().recordsPerHour
                : S().householdChangesPerHour;
      if (recent.length >= most) return { status: 429, body: { error: 'too many at once: try again in a while' } };
      recent.push(t);
      return work();
    });
    // The next in line waits for this one whatever it came to; how it
    // came out is the caller's, through run.
    queue = run.catch(() => {});
    return run;
  };
}

/// What an account's turn is asked: {op: 'ticket' | 'claim' | 'drop' |
/// 'list' | 'activate' | …, ...}. [active] is where the account's device
/// in use is written ([activeInStore]); [revoke] tells relay objects a
/// device there is superseded.
export async function householdOp(op, store, { now = Date.now(), mail = null, active = activeInStore(store), revoke = null } = {}) {
  switch (op.op) {
    case 'ticket':
      return ticketFor(op.key, store, { now });
    case 'claim':
      return claimWith(op.key, op.code, store, { now });
    case 'redeem':
      return redeemBackup(op.key, op.code, store, { now });
    case 'join':
      return joinAccount(op.key, op.account, store, { now });
    case 'backups':
      return backupsFor(op.key, store, mail, { rotate: op.rotate === true, send: op.send === true, email: op.email ?? null, why: op.why ?? null, now });
    case 'made':
      return backupsMade(op.account, op.email ?? null, store, mail, {
        now,
        charge: op.charge ?? null,
        subscription: typeof op.subscription === 'string' ? op.subscription : null,
      });
    case 'bind':
      return bindPurchase(op, store, { now });
    case 'drop':
      return dropDevice(op.key, op.device, store, { now, active, revoke });
    case 'list': {
      const account = await accountOfKey(store, op.key);
      if (!account) return { status: 402, body: { error: 'no subscription' } };
      const inUseNow = (await active.get(account))?.key ?? null;
      const devices = (await devicesOn(store, account)).map((d) => ({ ...d, ...(d.key === inUseNow ? { active: true } : {}) }));
      // Which sign-in the account is linked to, if any: the account's
      // word, so a device shows a link made on another device, or one
      // Apple has since taken away (appleIdNotice), as it is now.
      const signIn = (await store.get(`ACCOUNT#${account}`, 'LOGIN'))?.provider ?? null;
      return { status: 200, body: { devices, most: S().mostDevices, signIn } };
    }
    case 'attest':
      return attest(op.who, op.key, store, op.login, { now });
    case 'unlink':
      return unlinkSignIn(op.account, op.login, store);
    case 'activate':
      return activate(op, store, active, { now, revoke });
    case 'seen':
      return seenAt(op, active);
    case 'inUse':
    case 'record':
      return inUse(op, active, { now });
    case 'profile':
      return op.profile ? profileWritten(op, store, active, { now }) : profileRead(op, store, { now });
    case 'order':
      return carryOut(op, store, active, { now, revoke });
    case 'delete':
      return deleteAccount(op, store, active, { now, revoke });
    default:
      return { status: 400, body: { error: 'not a household operation' } };
  }
}

/// Which of the hour's allowances [op] is counted against. An unlink is
/// Apple's word, not the person's, and has an allowance of its own (the
/// size of the changes'), so the person's own changes never stand in
/// its way; an operator's order has no allowance at all.
const kindOf = (op) =>
  op.op === 'order'
    ? 'order'
    : op.op === 'activate' || op.op === 'seen' || op.op === 'inUse'
    ? 'active'
    : op.op === 'record'
      ? 'record'
      : op.op === 'profile' && op.profile
      ? 'profile'
      : op.op === 'unlink'
        ? 'unlink'
        : op.op === 'list' || op.op === 'profile' || (op.op === 'backups' && op.rotate !== true)
          ? 'read'
          : 'change';

/// Tells the relay's object for each of [tags] that [account]'s device
/// in use is now the one of [epoch], so it closes the sockets of any
/// device of the account before it (service/do/relay.mjs), saying
/// [why] — that another device is in use, unless it is given. Through
/// [env]'s TABLE, which the account's object has where it runs beside
/// the relay; nothing where it does not.
export function revokerOf(env) {
  if (!env.TABLE) return null;
  return async (tags, account, epoch, why = null) => {
    await Promise.all(
      tags.map(async (tag) => {
        try {
          await env.TABLE.get(env.TABLE.idFromName(tag)).fetch('https://relay/revoke', {
            method: 'POST',
            body: JSON.stringify({ account, epoch, ...(why ? { why } : {}) }),
          });
        } catch {
          // An object that cannot be reached closes nothing: its
          // sockets run to the end of their activation's hour.
        }
      }),
    );
  };
}

/// How backup codes are emailed where [env] can: Cloudflare's Email
/// Sending, bound as EMAIL to the worker the household runs in, from
/// OH_MAIL_FROM. Null where either is missing, and the codes are only
/// shown on the devices. No reply address: a reply would quote the codes
/// to whoever reads it, so the mail sends questions to the support page.
/// With a [purchase] ({charge}), the email that answers a payment: the
/// codes, after what was bought and how to cancel it.
export function mailerOf(env) {
  const from = env.OH_MAIL_FROM;
  if (!env.EMAIL || typeof from !== 'string' || !from.includes('@')) return null;
  return (to, codes, purchase = null) =>
    env.EMAIL.send({
      to,
      from: { email: from, name: 'Open Hearts' },
      subject: purchase ? 'Your Open Hearts subscription' : 'Your Open Hearts backup codes',
      text: backupMailText(codes, purchase),
      html: backupMailHtml(codes, purchase),
    });
}

/// [charge] — Stripe's amount, in the currency's smallest unit, and the
/// currency — as money: `$5.99 USD`. Null for anything else.
export function moneyOf(charge) {
  if (!Number.isSafeInteger(charge?.amount) || charge.amount < 0 || typeof charge.currency !== 'string' || !/^[a-z]{3}$/i.test(charge.currency)) {
    return null;
  }
  const currency = charge.currency.toUpperCase();
  try {
    const format = new Intl.NumberFormat('en-US', { style: 'currency', currency });
    return `${format.format(charge.amount / 10 ** format.resolvedOptions().maximumFractionDigits)} ${currency}`;
  } catch {
    return null;
  }
}

/// What a payment's email says before the codes: what was bought, that
/// it renews by itself and at what, and how to cancel it, in a form the
/// buyer keeps (California's automatic renewal law asks for this
/// acknowledgment; the terms say the rest). As paragraphs, each a list
/// of [text, link?] pieces, for the text and the page alike.
function subscribedParagraphs(purchase) {
  const paid = moneyOf(purchase?.charge);
  return [
    [['Thank you for subscribing to Open Hearts live play.']],
    [
      [
        `${paid ? `You paid ${paid} for a year of it. ` : ''}The subscription renews automatically every year, on the ` +
          'date you subscribed, at the price then in force, until you cancel. We will tell you before a price change ' +
          'applies. Link, which sold it to you for us, sends your receipts and a reminder before each renewal.',
      ],
    ],
    [
      ['To cancel: in the game, open the menu, then Subscription, then Manage subscription; or see '],
      [`${SITE}/support#cancel`, `${SITE}/support#cancel`],
      ['. Cancelling stops the next renewal, and live play keeps working until the end of the year you paid for.'],
    ],
    [['The terms you agreed to: '], [`${SITE}/terms`, `${SITE}/terms`]],
  ];
}

/// [text] in lines of at most [width], broken between words.
function wrapped(text, width = 70) {
  const lines = [];
  let line = '';
  for (const word of text.split(' ')) {
    if (line && line.length + 1 + word.length > width) {
      lines.push(line);
      line = word;
    } else {
      line = line ? `${line} ${word}` : word;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/// What a purchase's email says in place of the codes when every one
/// has been used: a purchase is told of all the same.
const ALL_USED = 'Every backup code of your account has been used. Any device of the account can make new ones, under Subscription.';

/// The email itself: the codes, and how to use one — after, for a
/// [purchase], what was bought ([subscribedParagraphs]).
export function backupMailText(codes, purchase = null) {
  const before = purchase
    ? subscribedParagraphs(purchase).flatMap((p) => [...wrapped(p.map(([words]) => words).join('')), ''])
    : [];
  const kept = codes.length
    ? [
        purchase ? 'Your backup codes:' : 'Your Open Hearts backup codes:',
        '',
        ...codes.map((c) => `  ${c}`),
        '',
        'Each one brings one device into your account, once. On the device:',
        'menu, Activate subscription, and type or paste a code.',
        '',
        'Any device of the account shows these codes under Subscription, can',
        'email them here again, and can replace them with new ones, after',
        'which the codes above stop working.',
        '',
        'Keep them private: anyone with a code can bring a device into your',
        'account. Replies to this email are not read; for help, see',
      ]
    : [...wrapped(ALL_USED), '', 'Replies to this email are not read; for help, see'];
  return [...before, ...kept, `${SITE}/support`, '', `Open Hearts — ${SITE}`].join('\n');
}

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/// The same email as a page, for the mail readers that prefer one: the
/// same words, the codes set in a fixed-width face.
export function backupMailHtml(codes, purchase = null) {
  const code = (c) => `<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:18px;letter-spacing:1px;margin:4px 0">${escapeHtml(c)}</div>`;
  const piece = ([words, link]) => (link ? `<a href="${escapeHtml(link)}">${escapeHtml(words)}</a>` : escapeHtml(words));
  const before = purchase ? subscribedParagraphs(purchase).map((p) => `<p>${p.map(piece).join('')}</p>`) : [];
  const help = `Replies to this email are not read; for help, see <a href="${SITE}/support">openhearts.game/support</a>.`;
  const kept = codes.length
    ? [
        `<p>${purchase ? 'Your backup codes:' : 'Your Open Hearts backup codes:'}</p>`,
        `<div style="margin:12px 0 16px 0">${codes.map(code).join('')}</div>`,
        '<p>Each one brings one device into your account, once. On the device: menu, <b>Activate subscription</b>, and type or paste a code.</p>',
        '<p>Any device of the account shows these codes under Subscription, can email them here again, and can replace them with new ones, after which the codes above stop working.</p>',
        `<p>Keep them private: anyone with a code can bring a device into your account. ${help}</p>`,
      ]
    : [`<p>${escapeHtml(ALL_USED)}</p>`, `<p>${help}</p>`];
  return [
    '<!doctype html><html><body style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1b1b1b">',
    ...before,
    ...kept,
    `<p style="color:#666">Open Hearts — <a href="${SITE}">openhearts.game</a></p>`,
    '</body></html>',
  ].join('\n');
}

/// The Durable Object an account's turn runs in, one per account, named
/// by it — or by `sub:` and a subscription, for a subscription's own
/// turn. Exported from the relay's worker beside TagRelay
/// (service/do/worker.mjs), bound to the Pages project and to the relay
/// as HOUSEHOLD; it reads and writes the same OH_STORE. The account's
/// device in use is kept in the object's own storage, which is read
/// back as it was written, and closes sockets at the relay through the
/// relay worker's TABLE.
export class Household {
  constructor(state, env) {
    this.env = env;
    this.next = sequencer();
    this.active = {
      get: () => state.storage.get('active'),
      put: (_, row) => state.storage.put('active', row),
    };
  }

  async fetch(request) {
    const op = await request.json();
    // The operator's alerts (alerts.mjs) and notices of a change to the
    // terms (notices.mjs) only borrow the binding.
    if (op?.op === 'alert') return Response.json(await sendAlert(op, this.env));
    if (op?.op === 'notice') return Response.json(await sendNotice(op, this.env));
    await settle(this.env);
    const store = storeOf(this.env);
    if (!store) return Response.json({ status: 503, body: notConfigured('OH_STORE') });
    return Response.json(
      await this.next(kindOf(op), () => householdOp(op, store, { mail: mailerOf(this.env), active: this.active, revoke: revokerOf(this.env) })),
    );
  }
}

/// This isolate's queues, by account, for a project with no HOUSEHOLD
/// bound.
const households = new Map();

/// [op] run in [name]'s turn — an account's, or `sub:` and a
/// subscription — : {status, body}.
export async function inHousehold(env, name, op) {
  if (env.HOUSEHOLD) {
    const stub = env.HOUSEHOLD.get(env.HOUSEHOLD.idFromName(name));
    const answer = await stub.fetch('https://household/', { method: 'POST', body: JSON.stringify(op) });
    return answer.json();
  }
  const store = storeOf(env);
  if (!store) return { status: 503, body: notConfigured('OH_STORE') };
  if (!households.has(name)) households.set(name, sequencer());
  return households.get(name)(kindOf(op), () => householdOp(op, store, { mail: mailerOf(env) }));
}

/// [op] in [subscription]'s own turn: where its account is found, or
/// made once and once only.
export const inSubscription = (env, subscription, op) => inHousehold(env, `sub:${subscription}`, op);

/// Forgets this isolate's queues, for a test that starts afresh.
export const forgetHouseholds = () => households.clear();
