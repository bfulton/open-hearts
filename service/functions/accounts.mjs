// Accounts (docs/explanation/service.md): how far a device is paid up
// (entitlementOf), the account a subscription buys, and the codes and
// backup codes that bring a device into it.

import { REFUSED } from './refusals.mjs';
import { dayAfter, dayOf, digestOf, hex, isAccount, newAccount } from './rows.mjs';
import { S } from './settings.mjs';

/// How far this key is paid up to, and the account it is a device of.
/// One read of the device's own row; the account's and its
/// subscription's only when that row says the device has run out,
/// which is once a renewal. A device of a suspended account
/// (suspension.mjs) holds nothing: its row says so, and the account's
/// mark is read on the way to the subscription too, should a row have
/// been written before the flag reached it.
///
/// In local mode a key nobody has heard of is entitled on the spot for
/// a month (docs/explanation/service.md), on an account of its own — one branch,
/// and it is never on in production.
///
/// [written] is the device's row as its account's object has just
/// written it ([joinAccount]), which is taken instead of the row here:
/// this store may not show it yet. KV is eventually consistent, and the
/// object runs where its account was first asked for, not where the
/// device is asking.
export async function entitlementOf(store, key, { now = Date.now(), openHouse = false, written = null } = {}) {
  const today = dayOf(now);
  const row = written ?? (await store.get(`KEY#${key}`, 'ENTITLEMENT'));
  if (!row) {
    if (!openHouse) return null;
    const subscription = `local-${key.slice(0, 16)}`;
    const renews_at = dayAfter(now, S().licenceDays);
    await store.put(`SUB#${subscription}`, 'META', { source: 'local', txn_ref: null, renews_at, cancelled_at: null });
    await paidFor(store, subscription, key, { now });
    return store.get(`KEY#${key}`, 'ENTITLEMENT');
  }
  if (!isAccount(row.account) || row.suspended) return null;
  if (row.licensed_until && row.licensed_until >= today) return row;
  // Run out as this row has it, or never written: a checkout binds the
  // device before Stripe has told us when the subscription runs to.
  // The account's subscription is the authority, and a renewal moves
  // it on without touching the devices under it.
  if (await isSuspended(store, row.account)) return null;
  const subscription = (await store.get(`ACCOUNT#${row.account}`, 'META'))?.subscription;
  const sub = subscription ? await store.get(`SUB#${subscription}`, 'META') : null;
  if (!sub || !sub.renews_at || sub.renews_at < today) return null;
  const caught = { ...row, licensed_until: sub.renews_at, at: today };
  await store.put(`KEY#${key}`, 'ENTITLEMENT', caught);
  return caught;
}

/// Whether [account] is suspended from live play (suspension.mjs).
export const isSuspended = async (store, account) => !!(await store.get(`ACCOUNT#${account}`, 'SUSPENDED'));

// ---- accounts ----------------------------------------------------------
// What a subscription buys is an account (docs/explanation/service.md): made
// when the subscription is first paid for, with an id of its own, and
// every device brought in — the one that paid, one shown a code, one
// given a backup code, one signed in — is one of its devices. A device
// keeps its own key; the licence says whose device it is.

/// [subscription]'s account: the one it has; otherwise, when [make],
/// the account of [buyer] — the device paying — when it has one with
/// nothing else paid up under it, or a new one. Null for a subscription
/// with none and nothing to make one for. Run in the subscription's own
/// turn (household.mjs, inSubscription).
export async function accountFor(store, subscription, { buyer = null, make = false, now = Date.now() } = {}) {
  const today = dayOf(now);
  const known = (await store.get(`SUB#${subscription}`, 'ACCOUNT'))?.account;
  if (isAccount(known)) return known;
  if (!make) return null;
  let account = null;
  if (buyer) {
    const theirs = (await store.get(`KEY#${buyer}`, 'ENTITLEMENT'))?.account;
    const was = isAccount(theirs) ? await store.get(`ACCOUNT#${theirs}`, 'META') : null;
    // The buyer's own account takes the new subscription where it has
    // nothing else paid up: a lapsed subscriber buying again is the same
    // person, with the same name, rating and devices. A suspended one
    // takes it whatever it has, so that paying again is not a way out
    // of a suspension (the web's checkout refuses before anybody pays).
    if (was && (!(await paidUp(store, was.subscription, today)) || (await isSuspended(store, theirs)))) account = theirs;
  }
  account ??= newAccount();
  const meta = await store.get(`ACCOUNT#${account}`, 'META');
  // The subscriptions it had before, whose rows still name it: what its
  // deletion deletes too (deletion.mjs), found without a listing.
  const before = [...(meta?.before ?? []), ...(typeof meta?.subscription === 'string' && meta.subscription !== subscription ? [meta.subscription] : [])];
  await store.put(`ACCOUNT#${account}`, 'META', { subscription, created_at: meta?.created_at ?? today, ...(before.length ? { before } : {}) });
  await store.put(`SUB#${subscription}`, 'ACCOUNT', { account });
  return account;
}

/// A subscription just paid for by [key]: its account — the buyer's,
/// or a new one ([accountFor]) — with the buyer on it, moved from
/// whatever it was on: the device that paid may. {status, body}.
export async function paidFor(store, subscription, key, { now = Date.now() } = {}) {
  const account = await accountFor(store, subscription, { buyer: key, make: true, now });
  return joinAccount(key, account, store, { now, moving: true });
}

/// Whether [account] has a subscription that is somebody's purchase and
/// still paid up on [today].
async function accountPaidUp(store, account, today) {
  if (!isAccount(account)) return false;
  return paidUp(store, (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription, today);
}

// ---- an account is a person's, not a device's ----------------------------
// Five devices to an account, and any of them can drop another. They
// are one person's: one of them is in use at a time (household.mjs,
// "one device at a time"), and unbounded sharing would be an account
// shared with the internet (docs/explanation/service.md).
//
// A second device is brought in by a code: the subscribed device shows
// one, the new device arrives carrying it, and it is spent. The code is
// a random sixteen bytes and nothing else; the account and expiry are
// kept here. A code that has to be spent needs a row whatever it
// carries, so a signature would save no lookup — and a short code is a
// sparse QR, read across a table by a phone that is not quite still.
// It also keeps the account off the wire, which a photograph of a
// screen would otherwise carry away.

/// How long a code's row is kept, spent or not, before the store lets
/// it go by itself: an hour, so that a late scan is told the code ran
/// out rather than that it never was. Without it every code ever made
/// would be a row for ever.
const TICKET_KEPT_S = 60 * 60;

const TICKET_BYTES = 16;

const nonce = () => hex(crypto.getRandomValues(new Uint8Array(TICKET_BYTES)));

/// The devices of an account, oldest binding first.
export async function devicesOn(store, account) {
  const found = [];
  for (const sk of await store.under(`ACCOUNT#${account}`, 'DEVICE#')) {
    const key = sk.slice('DEVICE#'.length);
    const row = await store.get(`ACCOUNT#${account}`, sk);
    found.push({ key, bound_at: row?.bound_at ?? null });
  }
  return found.sort((a, b) => String(a.bound_at).localeCompare(String(b.bound_at)) || a.key.localeCompare(b.key));
}

/// The devices of [account] whose entitlement row is still the
/// account's, each with that row, {key, row}: what an ending, a
/// suspension and a deletion write down or delete, and never a row of
/// another account's.
export async function devicesWithRows(store, account) {
  const found = [];
  for (const sk of await store.under(`ACCOUNT#${account}`, 'DEVICE#')) {
    const key = sk.slice('DEVICE#'.length);
    const row = await store.get(`KEY#${key}`, 'ENTITLEMENT');
    if (row?.account === account) found.push({ key, row });
  }
  return found;
}

/// The account [key] is a device of, by its own row; null for none.
export const accountOfKey = async (store, key) => {
  const account = (await store.get(`KEY#${key}`, 'ENTITLEMENT'))?.account;
  return isAccount(account) ? account : null;
};

/// Whether [key] is a device of [account] by both rows that say so: its
/// own entitlement naming the account, and the account's row for it.
export const deviceOf = async (store, account, key) =>
  isAccount(account) && (await accountOfKey(store, key)) === account && !!(await store.get(`ACCOUNT#${account}`, `DEVICE#${key}`));

/// A code for a new device to arrive with: {status, body}. The one
/// already outstanding, while it is unspent and has time left: asking
/// again is a read, not a new row and a listing of the account — a
/// subscriber asking in a loop would otherwise spend the store's writes
/// for everyone, Stripe's included (docs/explanation/security-model.md).
export async function ticketFor(key, store, { now = Date.now() } = {}) {
  const account = await accountOfKey(store, key);
  if (!account) return { status: 402, body: { error: REFUSED.noSubscription } };
  const out = await store.get(`ACCOUNT#${account}`, 'TICKET');
  if (out && Date.parse(out.expires_at) - now >= S().ticketReuseMinutes * 60000) {
    const ticket = await store.get(`TICKET#${out.code}`, 'META');
    if (ticket && !ticket.used_at) {
      return { status: 200, body: { ticket: out.code, expires_at: out.expires_at, devices: out.devices, most: S().mostDevices } };
    }
  }
  const devices = await devicesOn(store, account);
  if (devices.length >= S().mostDevices) {
    return { status: 409, body: { error: REFUSED.accountFull, devices: devices.length, most: S().mostDevices } };
  }
  const code = nonce();
  const expires_at = new Date(now + S().ticketMinutes * 60000).toISOString();
  await store.put(`TICKET#${code}`, 'META', { account, expires_at, used_at: null, made_by: key }, { ttl: TICKET_KEPT_S });
  await store.put(`ACCOUNT#${account}`, 'TICKET', { code, expires_at, devices: devices.length }, { ttl: TICKET_KEPT_S });
  return { status: 200, body: { ticket: code, expires_at, devices: devices.length, most: S().mostDevices } };
}

/// A device arriving with a code. The code is spent whether or not the
/// licence that follows can be signed: a code that could be tried twice
/// is not a code that was spent once.
export async function claimWith(key, code, store, { now = Date.now() } = {}) {
  if (typeof code !== 'string' || !/^[0-9a-f]{2,64}$/.test(code)) return { status: 400, body: { error: REFUSED.notACode } };
  const ticket = await store.get(`TICKET#${code}`, 'META');
  if (!ticket || !isAccount(ticket.account)) return { status: 404, body: { error: REFUSED.noSuchCode } };
  if (ticket.used_at) return { status: 409, body: { error: REFUSED.codeUsed } };
  if (Date.parse(ticket.expires_at) <= now) return { status: 410, body: { error: REFUSED.codeRunOut } };
  const today = dayOf(now);
  return joinAccount(key, ticket.account, store, {
    now,
    spend: () => store.put(`TICKET#${code}`, 'META', { ...ticket, used_at: today, used_by: key }, { ttl: TICKET_KEPT_S }),
  });
}

// ---- backup codes ----------------------------------------------------------
// A code on the screen of a device already on the account is good for
// minutes (ticketMinutes); a backup code is good until it is used or
// replaced. It
// is the account's recovery secret, for the day there is no such
// screen: a phone lost, a new one in hand. Entered on any device, it
// brings that device into the account — the same account, with its
// name, its rating and its games. Five to an account, each good once,
// kept with the account and shown on any device of it; replaced all
// five at once from any of them, which spends the old ones. The person
// who paid on the web is sent them by email when the subscription is
// made and again whenever a device of the account asks — to the
// address Stripe holds, read from Stripe when it is needed and not
// kept here.
//
// Sixteen characters of Crockford's base32, eighty bits, read and typed
// by a person: no I, L, O or U, case, spaces and dashes ignored, and
// an O, I or L typed is taken as the 0 or 1 it looks like. A code's row is keyed
// by its digest, so a listing of the store does not list the codes.

export const BACKUP_CODES = 5;
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

function backupCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  let bits = 0;
  let value = 0;
  let out = '';
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += CROCKFORD[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  return out.match(/.{4}/g).join('-');
}

/// [text] as a backup code, XXXX-XXXX-XXXX-XXXX, or null when it is not
/// one: what a person typed or pasted, read generously.
export function backupCodeOf(text) {
  if (typeof text !== 'string' || text.length > 64) return null;
  const plain = text
    .toUpperCase()
    .replace(/[\s-]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1');
  if (!/^[0-9A-HJKMNP-TV-Z]{16}$/.test(plain)) return null;
  return plain.match(/.{4}/g).join('-');
}

export const backupRow = async (code) => `BACKUP#${await digestOf(`oh-backup/1\n${code}`)}`;

/// Five new codes for [account], replacing any it had: their rows go,
/// so an old one is no such code. Returns the account's row. Emails
/// nothing: an account somebody paid for is told its codes by
/// [backupsMade], and a preview's invitation is one of them
/// (ops/preview.mjs).
export async function makeBackups(store, account, { now = Date.now() } = {}) {
  const old = await store.get(`ACCOUNT#${account}`, 'BACKUP');
  for (const c of old?.codes ?? []) await store.del(await backupRow(c.code), 'META');
  const codes = [];
  while (codes.length < BACKUP_CODES) {
    const code = backupCode();
    if (!codes.some((c) => c.code === code)) codes.push({ code, used_at: null });
  }
  for (const c of codes) await store.put(await backupRow(c.code), 'META', { account });
  const row = { codes, made_at: new Date(now).toISOString(), emailed_at: null };
  await store.put(`ACCOUNT#${account}`, 'BACKUP', row);
  return row;
}

/// The codes as a device on the subscription is shown them.
const backupsShown = (row) => ({ codes: row.codes.map((c) => ({ code: c.code, used: c.used_at !== null })), made_at: row.made_at });

/// Sends [row]'s codes to [email] with [mail], and notes that it did:
/// {row, unsent}, [unsent] null when it went and otherwise why not —
/// `no address`, `no mail` (Email Sending not bound here), `no codes`
/// (all used) or `failed`. Every one that did not go is logged; the
/// codes are on every device of the account regardless. A [purchase]
/// of [subscription] is told of even with every code used, and noted
/// as `acknowledged`.
async function mailBackups(store, account, row, email, mail, { now, why = null, purchase = null, subscription = null }) {
  const codes = row.codes.filter((c) => c.used_at === null).map((c) => c.code);
  const unsent = !mail ? 'no mail' : typeof email !== 'string' || !email.includes('@') ? 'no address' : codes.length === 0 && !purchase ? 'no codes' : null;
  if (unsent) {
    console.log(`backup codes for ${account}: not sent: ${unsent}${why ? ` (${String(why).slice(0, 200)})` : ''}`);
    return { row, unsent };
  }
  try {
    await mail(email, codes, purchase);
  } catch (e) {
    console.log(`backup codes for ${account}: not sent: ${e?.code ?? ''} ${e?.message ?? e}`);
    return { row, unsent: 'failed' };
  }
  console.log(`backup codes for ${account}: sent`);
  const sent = { ...row, emailed_at: new Date(now).toISOString(), ...(subscription ? { acknowledged: subscription } : {}) };
  await store.put(`ACCOUNT#${account}`, 'BACKUP', sent);
  return { row: sent, unsent: null };
}

/// An account just paid for, by [subscription]: its codes, made once,
/// and the purchase told to the payer once — what they subscribed to,
/// how it renews and how to cancel it ([charge], the checkout's:
/// {amount, currency}) — with the codes. A webhook delivered twice
/// finds the subscription told of, and sends only if the first send
/// did not go; an account bought again once its subscription has ended
/// is a new subscription, and is told of that one too.
export async function backupsMade(account, email, store, mail, { now = Date.now(), charge = null, subscription = null } = {}) {
  let row = await store.get(`ACCOUNT#${account}`, 'BACKUP');
  if (!row) row = await makeBackups(store, account, { now });
  const told = subscription ? row.acknowledged === subscription : row.emailed_at !== null;
  if (!told) ({ row } = await mailBackups(store, account, row, email, mail, { now, purchase: { charge }, subscription }));
  return { status: 200, body: { made_at: row.made_at, emailed: row.emailed_at !== null } };
}

/// The codes, for a device of the account: made if there are none yet,
/// and replaced when [rotate]; with [send], the ones still good sent to
/// [email], the payer's, when a device asks (the Email button) — and
/// `emailed`, or `unsent` and why not, in the answer.
export async function backupsFor(key, store, mail, { rotate = false, send = false, email = null, why = null, now = Date.now() } = {}) {
  const account = await accountOfKey(store, key);
  if (!account || !(await store.get(`ACCOUNT#${account}`, `DEVICE#${key}`))) return { status: 402, body: { error: REFUSED.noSubscription } };
  let row = await store.get(`ACCOUNT#${account}`, 'BACKUP');
  if (!row || rotate) row = await makeBackups(store, account, { now });
  if (!send) return { status: 200, body: { ...backupsShown(row), emailed: false } };
  const mailed = await mailBackups(store, account, row, email, mail, { now, why });
  return { status: 200, body: { ...backupsShown(mailed.row), emailed: mailed.unsent === null, ...(mailed.unsent ? { unsent: mailed.unsent } : {}) } };
}

/// A device arriving with a backup code: into the account the code is
/// for. Spent only by a join that goes through: a code turned down for
/// a full account is still good once a device is dropped.
export async function redeemBackup(key, code, store, { now = Date.now() } = {}) {
  const at = await store.get(await backupRow(code), 'META');
  if (!at || !isAccount(at.account)) return { status: 404, body: { error: REFUSED.noSuchCode } };
  const row = await store.get(`ACCOUNT#${at.account}`, 'BACKUP');
  const mine = row?.codes.find((c) => c.code === code);
  if (!mine) return { status: 404, body: { error: REFUSED.noSuchCode } };
  if (mine.used_at) return { status: 409, body: { error: REFUSED.codeUsed } };
  const today = dayOf(now);
  return joinAccount(key, at.account, store, {
    now,
    spend: () =>
      store.put(`ACCOUNT#${at.account}`, 'BACKUP', {
        ...row,
        codes: row.codes.map((c) => (c.code === code ? { ...c, used_at: today } : c)),
      }),
  });
}

/// [key] into [account], by the account's rules: no more devices than
/// it carries, and not off another account with a subscription still
/// paid up unless [moving] — which only the device that paid is. [spend]
/// runs once those are met and before anything is written: a code is
/// used up then, and not by a join that was refused.
export async function joinAccount(key, account, store, { now = Date.now(), moving = false, spend = null } = {}) {
  if (!isAccount(account)) return { status: 404, body: { error: 'no such account' } };
  const devices = await devicesOn(store, account);
  const already = devices.some((d) => d.key === key);
  if (!already && devices.length >= S().mostDevices) {
    return { status: 409, body: { error: REFUSED.accountFull, devices: devices.length, most: S().mostDevices } };
  }
  const today = dayOf(now);
  // A device of another account that is still paid up stays in it. A
  // code arrives in a link, so a link from a stranger with an account
  // of his own would otherwise take a device out of the one its owner
  // paid for, into one where he can drop it. Leaving is the device's
  // own to do, by dropping itself first — or by buying a subscription
  // of its own, which is as plain a word as it can say. An account
  // whose subscription has ended holds nothing, and neither do local
  // mode's open house, which licenses every device that asks, and a
  // preview's invitations: neither was ever anybody's purchase (paidUp).
  const was = await accountOfKey(store, key);
  if (was && was !== account && !moving && (await accountPaidUp(store, was, today))) {
    return { status: 409, body: { error: REFUSED.onAnotherSubscription } };
  }
  if (spend) await spend();
  // A device that was of another account leaves it rather than counting
  // against both.
  if (was && was !== account) await store.del(`ACCOUNT#${was}`, `DEVICE#${key}`);
  const subscription = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  const sub = subscription ? await store.get(`SUB#${subscription}`, 'META') : null;
  if (!already) await store.put(`ACCOUNT#${account}`, `DEVICE#${key}`, { bound_at: today });
  // A device brought into a suspended account is suspended with it.
  const entitlement = {
    account,
    licensed_until: sub?.renews_at ?? null,
    at: today,
    ...((await isSuspended(store, account)) ? { suspended: true } : {}),
  };
  await store.put(`KEY#${key}`, 'ENTITLEMENT', entitlement);
  // It goes back with the answer too: the handler that asked signs the
  // device's licence from it ([entitlementOf], written), where the store
  // may not show it yet.
  return { status: 200, body: { account, entitlement } };
}

/// Whether [subscription] is somebody's purchase and still paid up on
/// [today]: what a device on it is not moved off without saying so.
/// Local mode's open house licenses every device that asks, and the
/// operator invites people to play on previews (ops/preview.mjs); neither
/// was ever anybody's purchase, so they hold nobody.
async function paidUp(store, subscription, today) {
  if (typeof subscription !== 'string') return false;
  const sub = await store.get(`SUB#${subscription}`, 'META');
  return !!sub && !UNPAID.has(sub.source) && !!sub.renews_at && sub.renews_at >= today;
}

/// The subscriptions nobody paid for: local mode's open house, and a
/// preview's invitations.
const UNPAID = new Set(['local', 'invited']);
