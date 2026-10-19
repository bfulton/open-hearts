// `oh account …`: an account found, shown, and acted on as the terms
// and the privacy policy allow (docs/how-to/suspend-an-account.md,
// docs/how-to/end-an-account.md, docs/how-to/delete-an-accounts-data.md).
// Every act says what it would do and stops; with --apply it is done.
// Nothing here prints a name, a picture, a code or an email address:
// accounts, keys, rows and amounts only.

import { Failed, Usage } from './env.mjs';
import { endNow, inStripe, inTheStore, money, refund as refundIn, refundFor, resumeRenewal, stopRenewal, subscriptionOf } from './billing.mjs';
import { accountOf, findAccounts } from '../service/tool/find.mjs';
import { forget } from '../service/tool/forget.mjs';
import { carry, standing, wouldDo } from '../service/tool/suspend.mjs';
import { HOLD_DAYS, Held, heldPictureKey, heldPicturesPrefix, hold, holdRow, isReportRef, keepHeldPictures } from '../service/functions/holds.mjs';
import { accountPictureKey, pictureNamed } from '../service/functions/pictures.mjs';
import { anonymizeGames } from '../service/functions/records.mjs';
import { dayAfter, dayOf } from '../service/functions/rows.mjs';

/// The account [target] names (an account, or one of its devices' keys),
/// with how it stands; Failed when there is none.
async function theAccount(ctx, store, target) {
  const account = await accountOf(store, target);
  if (!account) throw new Usage('name the account (32 hex) or one of its devices (64 hex); oh account find finds one by name, email or picture');
  const stands = await standing(store, account);
  if (!stands.exists) throw new Failed(`no account ${account}`);
  return { account, stands };
}

/// How [stands] reads, a line at a time.
function describe(ctx, account, target, stands) {
  ctx.log(`${account}${target !== account ? ` (the account of ${target})` : ''}`);
  const state = stands.terminated ? `terminated on ${stands.terminated}` : stands.suspended ? `suspended since ${stands.suspended}` : 'not suspended';
  ctx.log(`  ${state}; ${stands.devices} device(s)`);
  const held = Object.entries(stands.held).filter(([, h]) => h).map(([k]) => k);
  ctx.log(`  profile: ${stands.name ? 'a name' : 'no name'}, ${stands.picture ? 'a picture' : 'no picture'}; held to put back: ${held.join(' and ') || 'nothing'}`);
  if (stands.hold) ctx.log(`  under a legal hold: ${new Held(stands.hold).message}${stands.hold.deleteAsked ? `; its deletion was asked for on ${stands.hold.deleteAsked}` : ''}`);
}

/// The account's web subscription as Stripe has it, said; or what to do
/// by hand for one bought in a store; or null when there is nothing in
/// Stripe to act on. {id, stands} for a web subscription.
async function webSubscription(ctx, store, account) {
  const sub = await subscriptionOf(store, account);
  if (!sub) {
    ctx.log('  no subscription');
    return null;
  }
  if (sub.source !== 'stripe') {
    ctx.log(`  its subscription was ${inTheStore(sub.source)}`);
    return null;
  }
  const stands = await inStripe(ctx.stripe(), sub.id);
  const till = stands.end ? new Date(stands.end).toISOString().slice(0, 10) : 'an unknown day';
  ctx.log(`  ${sub.id}: ${stands.status}, paid to ${till}${stands.cancelAtPeriodEnd ? `, not renewing${stands.stoppedBy ? ` (stopped by a ${stands.stoppedBy} account)` : ''}` : ''}`);
  if (stands.payment) {
    const back = stands.refunds.reduce((sum, r) => sum + r.amount, 0);
    ctx.log(`  last paid ${money(stands.payment.paid, stands.payment.currency)}${back ? `, of which ${money(back, stands.payment.currency)} refunded` : ''}`);
  }
  return { id: sub.id, stands };
}

export async function find(ctx, { args }) {
  const store = await ctx.store();
  const pictures = pictureNamed(args.query) ? await ctx.pictures() : null;
  const said = await findAccounts(store, args.query, { stripeKey: ctx.env.STRIPE_API_KEY ?? null, fetchImpl: ctx.fetch, pictures });
  for (const note of said.notes) ctx.warn(note);
  for (const a of said.found) {
    const now = said.pictures.get(a);
    ctx.log(now === undefined ? a : `${a}: put the picture out; ${now ? 'its profile picture now' : 'not its profile picture now'}`);
  }
  ctx.log(`${said.found.size} account(s)`);
}

export async function show(ctx, { args }) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
}

/// [name] carried out in the account's turn by the service, which has
/// already been said; Failed unless it was.
async function carried(ctx, store, account, name, parts = {}) {
  const config = await ctx.config();
  const done = await carry(store, account, name, parts, { origin: config.appOrigin, fetchImpl: ctx.fetch, ...(ctx.carryOptions ?? {}) });
  if (done?.status !== 200) throw new Failed(`the service said ${done?.status ?? 'nothing'}: ${done?.body?.error ?? ''}`);
  ctx.log(`done: ${JSON.stringify(done.body)}`);
}

export async function suspend(ctx, { args, flags }) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
  ctx.log(`  ${wouldDo('suspend', stands)}`);
  const web = await webSubscription(ctx, store, account);
  const stops = web && (web.stands.status === 'active' || web.stands.status === 'trialing') && !web.stands.cancelAtPeriodEnd;
  if (stops) ctx.log(`  and would stop ${web.id} renewing while the account is suspended`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  await carried(ctx, store, account, 'suspend');
  if (web && (await stopRenewal(ctx.stripe(), web.id, web.stands))) ctx.log(`stopped ${web.id} renewing`);
}

export async function lift(ctx, { args, flags }) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
  ctx.log(`  ${wouldDo('lift', stands)}`);
  if (stands.terminated) throw new Failed(`${account} was terminated on ${stands.terminated}`);
  const web = await webSubscription(ctx, store, account);
  const resumes = web && web.stands.stoppedBy === 'suspended' && web.stands.cancelAtPeriodEnd;
  if (resumes) ctx.log(`  and would let ${web.id} renew again, as it did before the suspension`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  await carried(ctx, store, account, 'lift');
  if (web && (await resumeRenewal(ctx.stripe(), web.id, web.stands))) ctx.log(`${web.id} renews again`);
}

/// The account's web subscription ended now and, unless [serious], the
/// unused part of its year refunded ([act] names the refund in Stripe).
/// [suspendAs], when given, is the order carried out first.
async function ending(ctx, { args, flags }, { act, suspendAs = null, full = false, serious = false }) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
  if (suspendAs) ctx.log(`  ${wouldDo(suspendAs, stands)}`);
  const web = await webSubscription(ctx, store, account);
  let amount = 0;
  if (web) {
    if (web.stands.status !== 'canceled') ctx.log(`  and would end ${web.id} now: no renewal, and live play on its devices stops at the end of the day (UTC)`);
    amount = serious ? 0 : refundFor(web.stands, act, { full, now: ctx.now() });
    if (serious) ctx.log('  and would refund nothing: a serious breach (--serious)');
    else if (web.stands.refunds.some((r) => r.act === act)) ctx.log(`  already refunded for this (${act}): nothing more`);
    else ctx.log(`  and would refund ${money(amount, web.stands.payment?.currency)}${full ? ', all of what is left of the payment' : ', the unused part of the year'}`);
  }
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  if (suspendAs) await carried(ctx, store, account, suspendAs);
  if (!web) return;
  const stripe = ctx.stripe();
  if (await endNow(stripe, web.id, web.stands, suspendAs === 'terminate' ? 'terminated under the terms' : 'refunded')) ctx.log(`ended ${web.id}`);
  if (await refundIn(stripe, web.stands, amount, act, account)) ctx.log(`refunded ${money(amount, web.stands.payment.currency)}`);
}

export const terminate = (ctx, said) => ending(ctx, said, { act: 'terminate', suspendAs: 'terminate', serious: !!said.flags.serious });

export const refund = (ctx, said) => ending(ctx, said, { act: 'refund', full: !!said.flags.full });

/// remove (with [parts]) or restore, carried out in the account's turn.
async function profileAct(ctx, name, { args, flags }, parts = {}) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
  if (name === 'restore' && stands.hold) throw new Failed('under a legal hold: nothing taken off it is put back');
  ctx.log(`  ${wouldDo(name, stands, parts)}`);
  const bucket = name === 'remove' && parts.name ? ctx.bucket() : null;
  if (bucket) ctx.log(`  and would take its name off ${(await anonymizeGames(bucket, account, { dry: true })).length} kept game(s)`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  await carried(ctx, store, account, name, parts);
  if (bucket) {
    for (const { key, named } of await anonymizeGames(bucket, account)) ctx.log(`took the name off ${key}, seat ${named.join(', ')}`);
  }
}

export const restore = (ctx, said) => profileAct(ctx, 'restore', said);

export function remove(ctx, said) {
  const parts = String(said.args.what ?? '').split(',');
  if (!parts.length || parts.some((p) => p !== 'name' && p !== 'picture')) throw new Usage('remove takes name, picture, or name,picture');
  return profileAct(ctx, 'remove', said, { name: parts.includes('name'), picture: parts.includes('picture') });
}

/// The account's data deleted on its owner's request (forget.mjs).
export async function del(ctx, { args, flags }) {
  const store = await ctx.store();
  const account = await accountOf(store, args.account);
  if (!account) throw new Usage('name the account (32 hex) or one of its devices (64 hex); oh account find finds one by name, email or picture');
  try {
    await forget(store, ctx.bucket(), account, { apply: !!flags.apply, log: ctx.log, now: ctx.now() });
  } catch (e) {
    throw new Failed(e.message);
  }
}

/// The account's data held as it is, after a report the law requires
/// (service/functions/holds.mjs, docs/how-to/handle-abuse-material.md):
/// a year at the least, with the report's number. The pictures it set
/// that are still kept are copied where only the operator reaches them,
/// since each is deleted a year after it stops being the account's,
/// which a hold may outlast; run again, it copies any since.
export async function holdAccount(ctx, { args, flags }) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
  const ref = flags.ref ?? null;
  if (ref !== null && !isReportRef(ref)) throw new Usage('--ref is the report\'s number: letters, digits and dashes');
  if (stands.hold) ctx.log(`  already held${ref && !stands.hold.ref ? `; would add report ${ref}` : ''}`);
  else ctx.log(`  would hold its data until at least ${dayAfter(ctx.now(), HOLD_DAYS)}: nothing deletes it, or puts back what was taken off it, until it is released`);
  const pictures = await ctx.pictures();
  const theirs = (await pictures.list(accountPictureKey(account, ''))).length;
  ctx.log(`  and would keep a copy of each picture it set in the last year, ${theirs} now, at ${heldPicturesPrefix(account)} in the bucket of kept games, until the hold is released`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  const row = await hold(store, account, { ref, now: ctx.now() });
  ctx.log(`held: ${new Held(row).message}`);
  const { kept, gone } = await keepHeldPictures(pictures, ctx.bucket(), account);
  for (const digest of gone) ctx.warn(`no copy left of picture ${digest}`);
  for (const digest of kept) ctx.log(`kept ${heldPictureKey(account, digest)}`);
  ctx.log(`kept ${kept.length} picture(s) at ${heldPicturesPrefix(account)}`);
}

/// A hold released, once its year is out; what it kept is then the
/// privacy policy's to keep or delete again.
export async function release(ctx, { args, flags }) {
  const store = await ctx.store();
  const { account, stands } = await theAccount(ctx, store, args.account);
  describe(ctx, account, args.account, stands);
  const was = stands.hold;
  if (!was) return ctx.log('  not held: nothing to release');
  if (dayOf(ctx.now()) < was.until) throw new Failed(`held until at least ${was.until}: a report's contents are kept a year (18 U.S.C. §2258A(h))`);
  const records = ctx.bucket();
  const kept = await records.list(heldPicturesPrefix(account));
  ctx.log(`  would release the hold of ${was.since}, and delete the ${kept.length} picture(s) it kept`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  // The copies first: a release that stops part way is run again, and
  // finds the hold still there.
  for (const key of kept) await records.remove(key);
  await store.del(...holdRow(account));
  ctx.log('released');
  if (was.deleteAsked) ctx.log(`its owner asked on ${was.deleteAsked} for its data to be deleted: ./oh account delete ${account} --apply`);
}
