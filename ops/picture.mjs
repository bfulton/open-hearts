// `oh picture …`: a picture the automatic check hid (service/do/
// review.mjs) put back (docs/how-to/look-at-new-pictures.md). Says what
// it would do and stops; with --apply it is done. A picture is named by
// its SHA-256, as the daily email gives it.

import { Usage } from './env.mjs';
import { PICTURES_ROW, allowedOf, allowing, withheldOf } from '../service/functions/pictures.mjs';

export async function allow(ctx, { args, flags }) {
  const digest = String(args.picture ?? '').toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(digest)) throw new Usage('name the picture by its SHA-256 (64 hex), as the email gives it');
  const store = await ctx.store();
  const row = await store.get(...PICTURES_ROW);
  const now = ctx.now();
  const withheld = withheldOf(row, now).has(digest);
  ctx.log(`${digest}: ${withheld ? 'withheld at the relay' : 'not withheld'}${allowedOf(row, now).has(digest) ? ', allowed already' : ''}`);
  ctx.log(`would ${withheld ? 'stop withholding it, and ' : ''}keep the check from hiding it for 30 days`);
  if (!flags.apply) return ctx.log('nothing changed; --apply does it');
  await store.put(...PICTURES_ROW, allowing(row, digest, now));
  ctx.log('done: the relay shows it again within a couple of minutes');
}
