// The pictures subscribers put out at live tables, for the operator to
// look at (docs/explanation/relay.md, "Pictures to look at"). Only a
// subscriber's device is carried by the relay, so only subscribers'
// pictures are kept. Nothing waits on the operator: a picture is shown
// at once, and taken down after if it has to be (`oh account remove`).
//
// The first time a tag's object carries a picture, it writes a copy to
// a bucket served at pictures.openhearts.game, through Cloudflare's
// cache, where Cloudflare's CSAM Scanning Tool checks it against the
// lists of known child sexual abuse images; and the first time it
// carries a picture from an account, it notes that the account put it
// out. Once a day the worker's schedule emails the operator, account by
// account, every picture each put out since the last email — the ones
// it has since replaced too, so that swapping a picture back before the
// email hides nothing — and how to take it down; and deletes what
// nobody has put out for 30 days. Apart from worker.mjs so it can be
// tested without the runtime.

import { pictureDigest, pictureIn } from '../functions/pictures.mjs';
import { lobbyKind } from './relay.mjs';

/// Where the copies are served: the bucket's custom domain
/// (infra/cloudflare.mjs, a test holding the two equal).
export const PICTURES_ORIGIN = 'https://pictures.openhearts.game';

/// Where in the bucket the copies are, by digest.
export const REVIEW_PREFIX = 'review/';

/// Where in the bucket each account's use of a picture is noted:
/// `seen/<account>/<digest>`, empty, saying when the account first put
/// it out and whether the operator has been told.
export const SEEN_PREFIX = 'seen/';

/// How long a copy, or a note, is kept after the picture was last put
/// out.
export const REVIEW_KEPT_DAYS = 30;

/// How often what is still put out is written again, so that it is
/// kept [REVIEW_KEPT_DAYS] from its last use rather than its first.
const REFRESH_DAYS = 7;

/// The most pictures one email shows, in whole accounts; the rest go in
/// the next.
export const REVIEW_MOST = 100;

/// The most uses an object remembers having noted.
const remembered = 2000;

const DAY_MS = 24 * 60 * 60 * 1000;
const copyKey = (digest) => `${REVIEW_PREFIX}${digest}.jpg`;
const seenKey = (account, digest) => `${SEEN_PREFIX}${account}/${digest}`;

/// [key] in [bucket] written as [body] with [meta], unless it is there
/// and was written lately; written again, with what it first said,
/// when it was written a while ago, so that it stays. Resolves true
/// when it was not there.
async function noted(bucket, key, now, body, meta, httpMetadata) {
  const had = await bucket.head(key);
  if (had && now - new Date(had.uploaded).getTime() < REFRESH_DAYS * DAY_MS) return false;
  await bucket.put(key, body(), { ...(httpMetadata ? { httpMetadata } : {}), customMetadata: had?.customMetadata ?? meta });
  return !had;
}

/// What an object calls with each event it took, and who said it
/// (relay.mjs, `heard`): a picture from an account is copied to
/// [bucket], and the account's use of it noted, once. Resolves true
/// when the account's use was new.
export function pictureKeeper({ bucket, now = Date.now }) {
  const known = new Set();
  return async (event, who) => {
    if (!bucket || event?.kind !== lobbyKind || typeof who?.account !== 'string') return false;
    const jpeg = pictureIn(event.content);
    if (!jpeg) return false;
    const digest = await pictureDigest(jpeg);
    if (!digest) return false;
    const use = `${who.account}/${digest}`;
    if (known.has(use)) return false;
    if (known.size >= remembered) known.clear();
    known.add(use);
    const at = new Date(now()).toISOString();
    await noted(bucket, copyKey(digest), now(), () => Uint8Array.from(atob(jpeg), (c) => c.charCodeAt(0)), { at }, {
      contentType: 'image/jpeg',
      cacheControl: 'public, max-age=86400',
    });
    return noted(bucket, seenKey(who.account, digest), now(), () => '', { at });
  };
}

/// Everything in [bucket] under [prefix]: {key, at, told, uploaded}.
async function listed(bucket, prefix) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix, cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      found.push({ key: o.key, at: o.customMetadata?.at ?? '', told: o.customMetadata?.told ?? null, uploaded: new Date(o.uploaded).getTime() });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/// The email for [accounts], each {account, pictures: [{digest, at,
/// current}]}: account by account, every picture it put out, in order,
/// which is its profile's now, and the commands that take them down —
/// its profile's picture off, or the account suspended, for a picture
/// it has since replaced or that was never its profile's (a changed
/// app's). [more] is how many pictures wait for the next email.
export function reviewEmail(accounts, more = 0) {
  const count = accounts.reduce((n, a) => n + a.pictures.length, 0);
  const subject = `Open Hearts: ${count} new picture${count === 1 ? '' : 's'} to look at, from ${accounts.length} account${accounts.length === 1 ? '' : 's'}`;
  const intro =
    'Every picture each account put out at a live table since the last email, in the order it put them out, ' +
    'including any it has since replaced. Every one was shown. To take one down, run a command under its account. ' +
    'If one may show the sexual abuse of a child, follow docs/how-to/handle-abuse-material.md instead, which takes it ' +
    'down, keeps what the law has you keep, and reports it.';
  const tail = more ? `${more} more will come in the next email.` : '';
  const url = (p) => `${PICTURES_ORIGIN}/${copyKey(p.digest)}`;
  const note = (p) => (p.current ? 'its profile picture now' : 'no longer its profile picture');
  const commands = (a) => [
    ...(a.pictures.some((p) => p.current) ? [`./oh account remove ${a.account} picture --apply   (its profile picture now)`] : []),
    `./oh account suspend ${a.account} --apply   (any of them)`,
  ];
  const text = [
    intro,
    '',
    ...accounts.flatMap((a) => [
      `Account ${a.account}: ${a.pictures.length} picture${a.pictures.length === 1 ? '' : 's'}`,
      ...a.pictures.map((p) => `  ${p.at}  ${url(p)}  ${note(p)}`),
      ...commands(a).map((c) => `  ${c}`),
      '',
    ]),
    tail,
  ].join('\n');
  const html = [
    `<p>${escape(intro)}</p>`,
    ...accounts.map(
      (a) =>
        `<div style="margin:20px 0"><div><b>Account <code>${escape(a.account)}</code></b>: ${a.pictures.length} picture${a.pictures.length === 1 ? '' : 's'}</div>` +
        `<div>${a.pictures
          .map(
            (p) =>
              `<span style="display:inline-block;margin:4px;text-align:center"><a href="${url(p)}"><img src="${url(p)}" width="128" height="128" alt="picture ${escape(p.digest.slice(0, 8))}" style="object-fit:cover"></a>` +
              `<br><small>${escape(p.at)}<br>${escape(note(p))}</small></span>`,
          )
          .join('')}</div>` +
        commands(a)
          .map((c) => `<div><code>${escape(c)}</code></div>`)
          .join('') +
        `</div>`,
    ),
    tail ? `<p>${escape(tail)}</p>` : '',
  ].join('\n');
  return { subject, text, html };
}

/// The day's run: the copies and notes nobody has put out for
/// [REVIEW_KEPT_DAYS] deleted, and the operator emailed every use not
/// yet told of, account by account, oldest account first, whole
/// accounts up to [REVIEW_MOST] pictures. [send] takes {subject, text,
/// html}; [store] holds the accounts' profiles. The uses are marked told
/// only once the email has gone. Returns {deleted, sent, more}.
export async function reviewRun({ bucket, store, send, now = Date.now }) {
  const [copies, seen] = await Promise.all([listed(bucket, REVIEW_PREFIX), listed(bucket, SEEN_PREFIX)]);
  const stale = [...copies, ...seen].filter((o) => now() - o.uploaded > REVIEW_KEPT_DAYS * DAY_MS);
  for (let i = 0; i < stale.length; i += 1000) await bucket.delete(stale.slice(i, i + 1000).map((o) => o.key));
  const byAccount = new Map();
  for (const o of seen) {
    if (o.told || stale.includes(o)) continue;
    const [account, digest] = o.key.slice(SEEN_PREFIX.length).split('/');
    if (!byAccount.has(account)) byAccount.set(account, []);
    byAccount.get(account).push({ key: o.key, digest, at: o.at });
  }
  const waiting = [...byAccount.entries()]
    .map(([account, uses]) => ({ account, uses: uses.sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0)) }))
    .sort((a, b) => (a.uses[0].at < b.uses[0].at ? -1 : a.uses[0].at > b.uses[0].at ? 1 : 0));
  const total = waiting.reduce((n, a) => n + a.uses.length, 0);
  if (!total) return { deleted: stale.length, sent: 0, more: 0 };
  // Whole accounts: one is never split across two emails.
  const shown = [];
  let count = 0;
  for (const a of waiting) {
    if (shown.length && count + a.uses.length > REVIEW_MOST) break;
    shown.push(a);
    count += a.uses.length;
  }
  const accounts = [];
  for (const a of shown) {
    const profile = /^[0-9a-f]{32}$/.test(a.account) ? await store.get(`ACCOUNT#${a.account}`, 'PROFILE') : null;
    const current = profile?.picture ? await pictureDigest(profile.picture) : null;
    accounts.push({ account: a.account, pictures: a.uses.map((u) => ({ digest: u.digest, at: u.at, current: u.digest === current })) });
  }
  await send(reviewEmail(accounts, total - count));
  const told = new Date(now()).toISOString();
  for (const a of shown) for (const u of a.uses) await bucket.put(u.key, '', { customMetadata: { at: u.at, told } });
  return { deleted: stale.length, sent: count, more: total - count };
}
