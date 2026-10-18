// The pictures subscribers put out at live tables, for the operator to
// look at (docs/explanation/relay.md, "Pictures to look at"). Only a
// subscriber's device is carried by the relay, so only subscribers'
// pictures are kept. Nothing waits on the operator: a picture is shown
// at once, and taken down after if it has to be (`oh account remove`).
//
// The first time a tag's object carries a picture, it writes a copy to
// a bucket served at pictures.openhearts.game, through Cloudflare's
// cache, where Cloudflare's CSAM Scanning Tool checks it against the
// lists of known child sexual abuse images. Once a day the worker's
// schedule emails the operator every picture kept since the last email,
// whose it is, and how to take it down; and deletes the copies nobody
// has put out for 30 days. Apart from worker.mjs so it can be tested
// without the runtime.

import { pictureDigest, pictureIn } from '../functions/pictures.mjs';
import { lobbyKind } from './relay.mjs';

/// Where the copies are served: the bucket's custom domain
/// (infra/cloudflare.mjs, a test holding the two equal).
export const PICTURES_ORIGIN = 'https://pictures.openhearts.game';

/// Where in the bucket the copies are.
export const REVIEW_PREFIX = 'review/';

/// How long a copy is kept after the picture was last put out.
export const REVIEW_KEPT_DAYS = 30;

/// How often a copy still put out is written again, so that it is
/// kept [REVIEW_KEPT_DAYS] from its last use rather than its first.
const REFRESH_DAYS = 7;

/// The row that says up to when the operator has been emailed.
export const REVIEW_ROW = ['config', 'pictures-reviewed'];

/// The most pictures one email shows; the rest go in the next.
export const REVIEW_MOST = 100;

/// The most digests an object remembers having kept.
const rememberedDigests = 2000;

const DAY_MS = 24 * 60 * 60 * 1000;
const keyOf = (digest) => `${REVIEW_PREFIX}${digest}.jpg`;

/// What an object calls with each event it took, and who said it
/// (relay.mjs, `heard`): a picture from an account is copied to
/// [bucket], once. Resolves true when it wrote a copy.
export function pictureKeeper({ bucket, now = Date.now }) {
  const known = new Set();
  return async (event, who) => {
    if (!bucket || event?.kind !== lobbyKind || typeof who?.account !== 'string') return false;
    const jpeg = pictureIn(event.content);
    if (!jpeg) return false;
    const digest = await pictureDigest(jpeg);
    if (!digest || known.has(digest)) return false;
    if (known.size >= rememberedDigests) known.clear();
    known.add(digest);
    const key = keyOf(digest);
    const had = await bucket.head(key);
    // Kept already, and lately written: nothing to do. Kept a while
    // ago: written again with what it first said, so it stays.
    if (had && now() - new Date(had.uploaded).getTime() < REFRESH_DAYS * DAY_MS) return false;
    const first = had?.customMetadata ?? { account: who.account, at: new Date(now()).toISOString() };
    await bucket.put(key, Uint8Array.from(atob(jpeg), (c) => c.charCodeAt(0)), {
      httpMetadata: { contentType: 'image/jpeg', cacheControl: 'public, max-age=86400' },
      customMetadata: { account: first.account, at: first.at },
    });
    return !had;
  };
}

/// Every copy in [bucket]: {key, digest, account, at, uploaded}.
async function copiesIn(bucket) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix: REVIEW_PREFIX, cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      const digest = o.key.slice(REVIEW_PREFIX.length).replace(/\.jpg$/, '');
      found.push({ key: o.key, digest, account: o.customMetadata?.account ?? '', at: o.customMetadata?.at ?? '', uploaded: new Date(o.uploaded).getTime() });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/// The email for [pictures], each {digest, account, at, current}: the
/// picture, whose it is, when it was first put out, and the command
/// that takes it down — the account's picture off its profile, or, for
/// one that is not its profile's picture (a changed app's), the account
/// suspended. [more] is how many wait for the next email.
export function reviewEmail(pictures, more = 0) {
  const command = (p) => (p.current ? `./oh account remove ${p.account} picture --apply` : `./oh account suspend ${p.account} --apply`);
  const note = (p) => (p.current ? 'its profile picture' : 'not its profile picture now');
  const subject = `Open Hearts: ${pictures.length} new picture${pictures.length === 1 ? '' : 's'} to look at`;
  const intro =
    'Each picture a subscriber put out at a live table since the last email. Every one is already shown. ' +
    'To take one down, run the command under it. If one may show the sexual abuse of a child, follow ' +
    'docs/how-to/handle-abuse-material.md instead, which takes it down, keeps what the law has you keep, and reports it.';
  const tail = more ? `${more} more will come in the next email.` : '';
  const text = [
    intro,
    '',
    ...pictures.flatMap((p) => [`${PICTURES_ORIGIN}/${keyOf(p.digest)}`, `  account ${p.account}, ${note(p)}, first put out ${p.at}`, `  ${command(p)}`, '']),
    tail,
  ].join('\n');
  const html = [
    `<p>${escape(intro)}</p>`,
    ...pictures.map(
      (p) =>
        `<div style="margin:16px 0"><a href="${PICTURES_ORIGIN}/${keyOf(p.digest)}"><img src="${PICTURES_ORIGIN}/${keyOf(p.digest)}" width="128" height="128" alt="picture ${escape(p.digest.slice(0, 8))}" style="object-fit:cover"></a>` +
        `<div>account <code>${escape(p.account)}</code>, ${escape(note(p))}, first put out ${escape(p.at)}</div>` +
        `<div><code>${escape(command(p))}</code></div></div>`,
    ),
    tail ? `<p>${escape(tail)}</p>` : '',
  ].join('\n');
  return { subject, text, html };
}

/// The day's run: the copies nobody has put out for [REVIEW_KEPT_DAYS]
/// deleted, and the operator emailed the pictures kept since the last
/// email, [REVIEW_MOST] at a time, oldest first. [send] takes
/// {subject, text, html}; [store] holds [REVIEW_ROW] and the accounts'
/// profiles. The row moves on only once the email has gone, and only
/// as far as what it showed. Returns {deleted, sent, more}.
export async function reviewRun({ bucket, store, send, now = Date.now }) {
  const copies = await copiesIn(bucket);
  const stale = copies.filter((c) => now() - c.uploaded > REVIEW_KEPT_DAYS * DAY_MS);
  for (let i = 0; i < stale.length; i += 1000) await bucket.delete(stale.slice(i, i + 1000).map((c) => c.key));
  const through = (await store.get(...REVIEW_ROW))?.through ?? '';
  const fresh = copies
    .filter((c) => !stale.includes(c) && c.at > through)
    .sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
  if (!fresh.length) return { deleted: stale.length, sent: 0, more: 0 };
  const shown = fresh.slice(0, REVIEW_MOST);
  const pictures = [];
  for (const c of shown) {
    const profile = /^[0-9a-f]{32}$/.test(c.account) ? await store.get(`ACCOUNT#${c.account}`, 'PROFILE') : null;
    const current = !!profile?.picture && (await pictureDigest(profile.picture)) === c.digest;
    pictures.push({ digest: c.digest, account: c.account, at: c.at, current });
  }
  await send(reviewEmail(pictures, fresh.length - shown.length));
  await store.put(...REVIEW_ROW, { through: shown.at(-1).at });
  return { deleted: stale.length, sent: shown.length, more: fresh.length - shown.length };
}
