// `oh picture …`: a picture put back after the automatic check hid it
// (service/do/review.mjs, docs/how-to/look-at-new-pictures.md), or
// withheld at the relay wherever it was put out
// (docs/how-to/handle-abuse-material.md). Says what it would do and
// stops; with --apply it is done. A picture is named by its SHA-256, as
// the daily email gives it, or by the address of its copy.

import { Usage } from './env.mjs';
import { PICTURES_ROW, allowedOf, allowing, pictureNamed, withheldOf, withholding } from '../service/functions/pictures.mjs';

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
