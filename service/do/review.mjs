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
// out. As the copy is made, a model looks at the picture, and one that
// shows nudity or sexual content, violence or gore, or a hate symbol is
// hidden at once: withheld at the relay as a picture the operator took
// down is (service/functions/pictures.mjs). Once a day the worker's
// schedule emails the operator, account by account, every picture each
// put out since the last email — the ones it has since replaced too, so
// that swapping a picture back before the email hides nothing — what the
// check made of it, and how to take it down or put it back; and deletes
// what nobody has put out for 30 days. Apart from worker.mjs so it can
// be tested without the runtime.

import { PICTURES_ORIGIN, PICTURES_ROW, REVIEW_PREFIX, allowedOf, copyKey, copyUrl, pictureDigest, pictureIn, stillAllowing, withheldOf, withholding } from '../functions/pictures.mjs';
import { lobbyKind } from './relay.mjs';

/// Where the copies are served, and where in the bucket they are
/// (service/functions/pictures.mjs).
export { PICTURES_ORIGIN, REVIEW_PREFIX };

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

/// The model that looks at each new picture (Cloudflare Workers AI).
export const CHECK_MODEL = '@cf/cloudflare/clef-flash';

/// What the model is told the picture is.
const CHECK_STATE = 'A small profile picture a player chose to show other players in an online card game.';

/// What the model is asked of each picture, each answered as how likely
/// a yes is, from 0 to 1.
export const CHECK_QUESTIONS = Object.freeze({
  sexual: 'Does the picture show nudity or sexual content?',
  gore: 'Does the picture show graphic violence, injury or gore?',
  hate: 'Does the picture show a hate symbol, such as a swastika?',
});

/// How likely a yes hides a picture: where the line comes from is in
/// docs/explanation/relay.md, "Pictures to look at".
export const HIDE_AT = 0.5;

/// What the email calls each question's yes.
const CHECK_SAYS = { sexual: 'nudity or sexual content', gore: 'violence or gore', hate: 'a hate symbol' };

const DAY_MS = 24 * 60 * 60 * 1000;
const seenKey = (account, digest) => `${SEEN_PREFIX}${account}/${digest}`;

/// [key] in [bucket] written as [body] with what [meta] resolves, unless
/// it is there and was written lately; written again, with what it
/// first said, when it was written a while ago, so that it stays.
/// Resolves what was there ({customMetadata, uploaded}), or null.
async function noted(bucket, key, now, body, meta, httpMetadata) {
  const had = await bucket.head(key);
  if (had && now - new Date(had.uploaded).getTime() < REFRESH_DAYS * DAY_MS) return had;
  await bucket.put(key, body(), { ...(httpMetadata ? { httpMetadata } : {}), customMetadata: had?.customMetadata ?? (await meta()) });
  return had;
}

/// What the model makes of [jpeg] (base64): {sexual, gore, hate}, each
/// how likely a yes. Throws when it does not answer them all.
export async function checkPicture(ai, jpeg) {
  const said = await ai.run(CHECK_MODEL, {
    model: 'clef-flash',
    state: CHECK_STATE,
    images: [`data:image/jpeg;base64,${jpeg}`],
    questions: Object.fromEntries(Object.entries(CHECK_QUESTIONS).map(([id, q]) => [id, { type: 'noul', instructions: q }])),
  });
  const scores = {};
  for (const id of Object.keys(CHECK_QUESTIONS)) {
    const p = said?.answers?.[id]?.noul;
    if (typeof p !== 'number' || !(p >= 0 && p <= 1)) throw new Error(`no answer to ${id}`);
    scores[id] = p;
  }
  return scores;
}

/// What [scores] hide a picture for, in [CHECK_QUESTIONS]' order.
export const hiddenFor = (scores) => Object.keys(CHECK_QUESTIONS).filter((id) => (scores?.[id] ?? 0) >= HIDE_AT);

/// [scores] as a copy's metadata keeps them, its `check`:
/// `sexual=0.519 gore=0.009 hate=0.011`. A check that did not answer is
/// kept as `failed`.
const checkText = (scores) => Object.entries(scores).map(([id, p]) => `${id}=${p.toFixed(3)}`).join(' ');

/// A copy's `check` read back: the scores, {} for a failed check, or
/// null for a picture copied without one.
function checkOf(text) {
  if (typeof text !== 'string' || !text) return null;
  const scores = {};
  for (const part of text.split(' ')) {
    const [id, p] = part.split('=');
    if (id in CHECK_QUESTIONS && Number.isFinite(Number(p))) scores[id] = Number(p);
  }
  return scores;
}

/// [digests] withheld at the relay, as a picture the operator took down
/// is (service/functions/pictures.mjs), for [WITHHELD_FOR_MS]: each
/// unless it is already, or the operator allowed it after an earlier
/// check. What the operator allowed whose copy is among [kept] (the
/// daily run's) stays allowed for as long again. Resolves the ones of
/// [digests] the operator allowed.
export async function hidePictures(store, digests, now = Date.now(), kept = null) {
  const row = await store.get(...PICTURES_ROW);
  const allowed = allowedOf(row, now);
  const withheld = withheldOf(row, now);
  const still = kept ? [...allowed].filter((d) => kept.has(d)) : [];
  let next = still.length ? stillAllowing(row, still, now) : row;
  for (const d of digests) if (!allowed.has(d) && !withheld.has(d)) next = withholding(next, d, now);
  if (next !== row) await store.put(...PICTURES_ROW, next);
  return new Set(digests.filter((d) => allowed.has(d)));
}

/// What an object calls with each event it took, and who said it
/// (relay.mjs, `heard`): a picture from an account is copied to
/// [bucket], and the account's use of it noted, once. A picture copied
/// for the first time is looked at by [ai] (Workers AI), and the copy
/// keeps what it made of it. One the check found should be hidden is
/// hidden by [hide], given its digest and resolving the digests the
/// operator allowed: as it is copied, and again whenever it is put out
/// while it is not withheld — which a withheld picture never is, so
/// that one whose 30 days have run out is hidden again. A check or a
/// hiding that fails is told to [log]; the daily run hides it all the
/// same. Resolves true when the account's use was new.
export function pictureKeeper({ bucket, ai = null, hide = null, log = null, now = Date.now }) {
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
    let hidden = [];
    let fresh;
    try {
      const had = await noted(
        bucket,
        copyKey(digest),
        now(),
        () => Uint8Array.from(atob(jpeg), (c) => c.charCodeAt(0)),
        async () => {
          if (!ai) return { at };
          try {
            const scores = await checkPicture(ai, jpeg);
            hidden = hiddenFor(scores);
            return { at, check: checkText(scores) };
          } catch (e) {
            log?.(`picture not checked: ${e}`);
            return { at, check: 'failed' };
          }
        },
        { contentType: 'image/jpeg', cacheControl: 'public, max-age=86400' },
      );
      if (had) hidden = hiddenFor(checkOf(had.customMetadata?.check));
      fresh = !(await noted(bucket, seenKey(who.account, digest), now(), () => '', () => ({ at })));
    } catch (e) {
      // Not kept: the next time the account puts it out tries again.
      known.delete(use);
      throw e;
    }
    if (hidden.length && hide) {
      try {
        // Looked at again the next time it comes this way, unless the
        // operator allowed it: it will not, while it is withheld.
        if (!(await hide(digest)).has(digest)) known.delete(use);
      } catch (e) {
        known.delete(use);
        log?.(`picture not hidden: ${e}`);
      }
    }
    return fresh;
  };
}

/// Everything in [bucket] under [prefix]: {key, at, told, check,
/// uploaded}.
async function listed(bucket, prefix) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix, cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      const m = o.customMetadata ?? {};
      found.push({ key: o.key, at: m.at ?? '', told: m.told ?? null, check: m.check ?? null, uploaded: new Date(o.uploaded).getTime() });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/// What the check made of [p], a picture in the email: the questions
/// it was hidden for, and whether the operator has put it back since.
const hiddenOf = (p) => (p.check ? hiddenFor(p.check) : []);
const urgent = (p) => !p.allowed && hiddenOf(p).includes('sexual');

/// The email for [accounts], each {account, pictures: [{digest, at,
/// current, check, allowed}]}: account by account, every picture it put
/// out, in order, which is its profile's now, what the check made of it
/// (`check`, its scores; {} when the check failed; null when there was
/// none), whether the operator allowed it after the check hid it, and
/// the commands that take them down — its profile's picture off, or the
/// account suspended, for a picture it has since replaced or that was
/// never its profile's (a changed app's) — or put a hidden one back.
/// Accounts with a picture hidden as nudity or sexual content come
/// first, and the subject says so. [more] is how many pictures wait for
/// the next email.
export function reviewEmail(accounts, more = 0) {
  const pictures = accounts.flatMap((a) => a.pictures);
  const count = pictures.length;
  const hidden = pictures.filter((p) => hiddenOf(p).length && !p.allowed).length;
  const urgentCount = pictures.filter(urgent).length;
  const ordered = [...accounts.filter((a) => a.pictures.some(urgent)), ...accounts.filter((a) => !a.pictures.some(urgent))];
  const subject =
    `${urgentCount ? 'Urgent: ' : ''}Open Hearts: ${count} new picture${count === 1 ? '' : 's'} to look at, from ${accounts.length} account${accounts.length === 1 ? '' : 's'}` +
    (hidden ? `, ${hidden} hidden by the check` : '');
  const intro = [
    ...(urgentCount
      ? [
          `The automatic check hid ${urgentCount} picture${urgentCount === 1 ? '' : 's'} as nudity or sexual content; the accounts that put them out are first. Look at them now.`,
        ]
      : []),
    'Every picture each account put out at a live table since the last email, in the order it put them out, ' +
      'including any it has since replaced. Every one was shown at once. A model looked at each as it was copied, and hid ' +
      'those it took for nudity or sexual content, violence or gore, or a hate symbol, from then on; they are marked. ' +
      'To take one down, or to put back one hidden by mistake, run a command under its account. ' +
      'If one may show the sexual abuse of a child, follow docs/how-to/handle-abuse-material.md instead, which takes it ' +
      'down, keeps what the law has you keep, and reports it.',
  ];
  const tail = more ? `${more} more will come in the next email.` : '';
  const url = (p) => copyUrl(p.digest);
  const notes = (p) => {
    const why = hiddenOf(p);
    return [
      p.current ? 'its profile picture now' : 'no longer its profile picture',
      ...(why.length
        ? [`${p.allowed ? 'put back by you after the check hid it for' : 'hidden by the check for'} ${why.map((id) => `${CHECK_SAYS[id]} (${p.check[id].toFixed(2)})`).join(', ')}`]
        : p.check && !Object.keys(p.check).length
          ? ['not checked: the check failed']
          : []),
    ];
  };
  const commands = (a) => [
    ...(a.pictures.some((p) => p.current) ? [`./oh account remove ${a.account} picture --apply   (its profile picture now)`] : []),
    `./oh account suspend ${a.account} --apply   (any of them)`,
    ...a.pictures
      .filter((p) => hiddenOf(p).length && !p.allowed)
      .map((p) => `./oh picture allow ${p.digest} --apply   (puts ${p.digest.slice(0, 8)} back, if it was hidden by mistake)`),
  ];
  const text = [
    ...intro.flatMap((p) => [p, '']),
    ...ordered.flatMap((a) => [
      `Account ${a.account}: ${a.pictures.length} picture${a.pictures.length === 1 ? '' : 's'}`,
      ...a.pictures.map((p) => `  ${p.at}  ${url(p)}  ${notes(p).join('; ')}`),
      ...commands(a).map((c) => `  ${c}`),
      '',
    ]),
    tail,
  ].join('\n');
  const html = [
    ...intro.map((p, i) => (urgentCount && i === 0 ? `<p><b style="color:#b00020">${escape(p)}</b></p>` : `<p>${escape(p)}</p>`)),
    ...ordered.map(
      (a) =>
        `<div style="margin:20px 0"><div><b>Account <code>${escape(a.account)}</code></b>: ${a.pictures.length} picture${a.pictures.length === 1 ? '' : 's'}</div>` +
        `<div>${a.pictures
          .map(
            (p) =>
              `<span style="display:inline-block;margin:4px;text-align:center;vertical-align:top;max-width:180px"><a href="${url(p)}"><img src="${url(p)}" width="128" height="128" alt="picture ${escape(p.digest.slice(0, 8))}" style="object-fit:cover"></a>` +
              `<br><small>${escape(p.digest.slice(0, 8))}<br>${escape(p.at)}${notes(p)
                .map((n) => `<br>${escape(n)}`)
                .join('')}</small></span>`,
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
/// accounts up to [REVIEW_MOST] pictures. Every picture waiting that the
/// check found should be hidden is hidden, unless the operator allowed
/// it, in case hiding it as it was copied did not take; and what the
/// operator allowed stays allowed while its copy is kept. [send] takes
/// {subject, text, html}; [store] holds the accounts' profiles and the
/// pictures withheld. The uses are marked told only once the email has
/// gone. Returns {deleted, sent, more}.
export async function reviewRun({ bucket, store, send, now = Date.now }) {
  const [copies, seen] = await Promise.all([listed(bucket, REVIEW_PREFIX), listed(bucket, SEEN_PREFIX)]);
  const stale = [...copies, ...seen].filter((o) => now() - o.uploaded > REVIEW_KEPT_DAYS * DAY_MS);
  for (let i = 0; i < stale.length; i += 1000) await bucket.delete(stale.slice(i, i + 1000).map((o) => o.key));
  const digestIn = (o) => o.key.slice(REVIEW_PREFIX.length).replace(/\.jpg$/, '');
  const checks = new Map(copies.map((o) => [digestIn(o), checkOf(o.check)]));
  const byAccount = new Map();
  for (const o of seen) {
    if (o.told || stale.includes(o)) continue;
    const [account, digest] = o.key.slice(SEEN_PREFIX.length).split('/');
    if (!byAccount.has(account)) byAccount.set(account, []);
    byAccount.get(account).push({ key: o.key, digest, at: o.at, check: checks.get(digest) ?? null });
  }
  const toHide = [...new Set([...byAccount.values()].flat().filter((u) => hiddenFor(u.check).length).map((u) => u.digest))];
  const kept = new Set(copies.filter((o) => !stale.includes(o)).map(digestIn));
  const allowed = await hidePictures(store, toHide, now(), kept);
  const first = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const waiting = [...byAccount.entries()]
    .map(([account, uses]) => ({ account, uses: uses.map((u) => ({ ...u, allowed: allowed.has(u.digest) })).sort((a, b) => first(a.at, b.at)) }))
    .map((a) => ({ ...a, urgent: a.uses.some(urgent) }))
    // The accounts with a picture hidden as nudity or sexual content
    // first, so that they are never left for a later email.
    .sort((a, b) => (a.urgent !== b.urgent ? (a.urgent ? -1 : 1) : first(a.uses[0].at, b.uses[0].at)));
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
    accounts.push({
      account: a.account,
      pictures: a.uses.map((u) => ({ digest: u.digest, at: u.at, current: u.digest === current, check: u.check, allowed: u.allowed })),
    });
  }
  await send(reviewEmail(accounts, total - count));
  const told = new Date(now()).toISOString();
  for (const a of shown) for (const u of a.uses) await bucket.put(u.key, '', { customMetadata: { at: u.at, told } });
  return { deleted: stale.length, sent: count, more: total - count };
}
