// `oh picture …`: a picture put back after the automatic check hid it
// (service/do/review.mjs, docs/how-to/look-at-new-pictures.md); withheld
// at the relay wherever it was put out; or reported as child sexual
// abuse material, which the relay then handles as it does a match with a
// known image (service/do/known.mjs, docs/how-to/handle-abuse-material.md).
// Says what it would do and stops; with --apply it is done. A picture
// is named by its SHA-256, as the daily email gives it, or by the
// address of its copy.

import { Failed, Usage } from './env.mjs';
import { HOW_MOST, REPORT_KEPT_S, reportRow } from '../service/do/known.mjs';
import { PICTURES_ROW, allowedOf, allowing, pictureNamed, withheldOf, withholding } from '../service/functions/pictures.mjs';
import { hex, isAccount } from '../service/functions/rows.mjs';
import { accountsWith } from '../service/tool/find.mjs';
import { askUntilSeen } from '../service/tool/suspend.mjs';

/// The picture [args] names, the row of what is withheld and allowed,
/// and how the picture stands in it, said.
async function thePicture(ctx, args) {
  const digest = pictureNamed(args.picture);
  if (!digest) throw new Usage('name the picture by its SHA-256 (64 hex) or the address of its copy, as the emails give it');
  const store = await ctx.store();
  const row = await store.get(...PICTURES_ROW);
  const now = ctx.now();
  const withheld = withheldOf(row, now).has(digest);
  const allowed = allowedOf(row, now).has(digest);
  ctx.log(`${digest}: ${withheld ? 'withheld at the relay' : 'not withheld'}${allowed ? ', allowed already' : ''}`);
  return { digest, store, row, now, withheld, allowed };
}

export async function allow(ctx, { args, flags }) {
  const { digest, store, row, now, withheld } = await thePicture(ctx, args);
  ctx.log(`would ${withheld ? 'stop withholding it, and ' : ''}keep the check from hiding it for 30 days`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  await store.put(...PICTURES_ROW, allowing(row, digest, now));
  ctx.log('done: the relay shows it again within a couple of minutes');
}

export async function hide(ctx, { args, flags }) {
  const { digest, store, row, now, allowed } = await thePicture(ctx, args);
  ctx.log(`would withhold it at the relay for 30 days from now, wherever it was put out, as a picture taken off an account is${allowed ? ', and no longer allow it' : ''}`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  await store.put(...PICTURES_ROW, withholding(row, digest, now));
  ctx.log('done: the relay withholds it within a couple of minutes');
}

/// A picture the operator found and looked at, reported: the relay
/// withholds it, holds and terminates each account that set it (and
/// [--account], one the picture was taken off), reports it to NCMEC and
/// emails what it did, as for a match with a known image. The picture's
/// bytes never come here: only whether a copy of it is kept.
export async function report(ctx, { args, flags }) {
  const digest = pictureNamed(args.picture);
  if (!digest) throw new Usage('name the picture by its SHA-256 (64 hex) or the address of its copy, as the emails give it');
  const named = flags.account ?? null;
  if (named !== null && !isAccount(named)) throw new Usage('--account is an account, 32 hex');
  const how = flags.how ?? null;
  if (how !== null && (typeof how !== 'string' || !how.trim() || how.length > HOW_MOST)) throw new Usage(`--how is a few words, ${HOW_MOST} characters at the most`);
  const store = await ctx.store();
  const pictures = await ctx.pictures();
  const kept = await accountsWith(pictures, digest);
  const accounts = [...new Set([...kept, ...(named ? [named] : [])])];
  const copy = kept.length > 0;
  ctx.log(`${digest}: ${copy ? 'a copy of it is kept' : 'no copy of it is kept'}; set by ${accounts.length} account(s)`);
  for (const a of accounts) ctx.log(`  ${a}`);
  ctx.log(
    `would have the relay withhold it wherever it was put out, hold and terminate ${accounts.length ? 'each account' : 'nobody (no account is known)'}, their web subscriptions ended with nothing refunded, report it to NCMEC as a picture you looked at${how ? ` (${how.trim()})` : ''}, and email you what it did`,
  );
  if (!copy && !named) ctx.warn('without its copy, name an account it was taken off (--account), or report it by hand');
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  const id = hex(crypto.getRandomValues(new Uint8Array(16)));
  await store.put(...reportRow(id), { digest, accounts, how: how?.trim() ?? null }, { ttl: REPORT_KEPT_S });
  const origin = await ctx.relay();
  // The relay's other 404, that no copy of the picture is kept, is its
  // answer, and is not asked again.
  const unseen = (r) => r.status === 404 && r.body?.error === 'no such report';
  const last = await askUntilSeen(`${origin}/known`, { report: id }, { fetchImpl: ctx.fetch, ...ctx.carryOptions, unseen });
  if (last?.status !== 200) throw new Failed(`the relay said ${last?.status ?? 'nothing'}: ${last?.body?.error ?? ''}`);
  ctx.log(`done: the relay is acting on it for ${last.body.accounts.length} account(s), and emails you what it did`);
}
