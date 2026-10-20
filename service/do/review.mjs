// The pictures accounts set, for the operator to look at
// (docs/explanation/relay.md, "Pictures to look at"), kept as each is set
// (profile_pictures.mjs). Only a subscriber has an account, so only
// subscribers' pictures are kept. Nothing waits on the operator: a
// picture is shown once it is checked, and taken down after if it has to
// be (`oh account remove`).
//
// As a picture is first copied, a model looks at it, and one that shows
// nudity or sexual content, violence or gore, or a hate symbol is hidden
// at once: withheld at the relay as a picture the operator took down is
// (service/functions/pictures.mjs). Once a day the worker's schedule
// keeps what is kept for as long as it is promised, and no longer;
// asks PhotoDNA again about what it has not cleared; and emails the
// operator, account by account, every picture each set since the last
// email — the ones it has since replaced too, so that swapping a picture
// back before the email hides nothing — what the check made of it, and
// how to take it down or put it back. Apart from worker.mjs so it can be
// tested without the runtime.

import { HOLD_DAYS } from '../functions/holds.mjs';
import { ACCOUNT_PICTURES_PREFIX, PICTURES_ORIGIN, PICTURES_ROW, REVIEW_PREFIX, allowedOf, copyUrl, pictureDigest, stillAllowing, withheldOf, withholding } from '../functions/pictures.mjs';
import { isAccount } from '../functions/rows.mjs';

/// Where the copies are served, and where in the bucket they and each
/// account's pictures are (service/functions/pictures.mjs).
export { ACCOUNT_PICTURES_PREFIX, PICTURES_ORIGIN, REVIEW_PREFIX };

const DAY_MS = 24 * 60 * 60 * 1000;

/// How long a picture is kept after it stops being its account's —
/// replaced, taken off, or the account deleted — in days: as long as a
/// hold keeps one reported (holds.mjs), so that a picture is kept as
/// long whether or not it was reported.
export const PICTURE_KEPT_DAYS = HOLD_DAYS;

/// How long what the run finds is left alone after it was written: the
/// store shows a changed profile everywhere within a minute or so, and a
/// copy is written a moment before its note, so the run never takes
/// either for left behind as it is being made.
const SETTLED_MS = DAY_MS;

/// The most pictures one email shows, in whole accounts; the rest go in
/// the next.
export const REVIEW_MOST = 100;

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
export const checkText = (scores) => Object.entries(scores).map(([id, p]) => `${id}=${p.toFixed(3)}`).join(' ');

/// A copy's `check` read back: the scores, {} for a failed check, or
/// null for a picture copied without one.
export function checkOf(text) {
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

/// Everything in [bucket] under [prefix]: {key, at, told, replaced,
/// check, known, uploaded}, as profile_pictures.mjs writes them.
async function listed(bucket, prefix) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix, cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      const m = o.customMetadata ?? {};
      found.push({
        key: o.key,
        at: m.at ?? '',
        told: m.told ?? null,
        replaced: m.replaced ?? null,
        check: m.check ?? null,
        known: m.known ?? null,
        uploaded: new Date(o.uploaded).getTime(),
      });
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

/// A note's metadata as it is written back: what [n] says now.
const noteMeta = (n) => ({ at: n.at, ...(n.told ? { told: n.told } : {}), ...(n.replaced ? { replaced: n.replaced } : {}) });

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/// What the check made of [p], a picture in the email: the questions
/// it was hidden for, and whether the operator has put it back since.
const hiddenOf = (p) => (p.check ? hiddenFor(p.check) : []);
const urgent = (p) => !p.allowed && hiddenOf(p).includes('sexual');

/// The email for [accounts], each {account, pictures: [{digest, at,
/// current, check, allowed}]}: account by account, every picture it
/// set, in order, which is its profile's now, what the check made of it
/// (`check`, its scores; {} when the check failed; null when there was
/// none), whether the operator allowed it after the check hid it, and
/// the commands that take them down — its profile's picture off, or the
/// account suspended, for a picture it has since replaced — or put a
/// hidden one back.
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
          `The automatic check hid ${urgentCount} picture${urgentCount === 1 ? '' : 's'} as nudity or sexual content; the accounts that set them are first. Look at them now.`,
        ]
      : []),
    'Every picture each account set since the last email, in the order it set them, including any it has since ' +
      'replaced. Each was shown once it was checked as it was set: a model looked at each, and hid those it took for ' +
      'nudity or sexual content, violence or gore, or a hate symbol, from then on; they are marked. ' +
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

/// The day's run, over the pictures accounts set ([bucket]) and [store]
/// (the accounts' profiles, and the pictures withheld):
///
/// 1. a note that says its picture is its account's, though the
///    account's profile has another or none — the account deleted, or
///    its picture taken off — says from today that it no longer is. Only
///    the account's turn makes a picture its own, as it checks it
///    (profile_pictures.mjs), so the run only ever says one is not;
/// 2. what has not been its account's for [PICTURE_KEPT_DAYS] is
///    deleted, and each copy no note names;
/// 3. with [ask] (known.mjs, knownAsker), each picture kept that
///    PhotoDNA has not cleared is asked about again, for each account
///    that set it, whether or not it still has it — each was shown while
///    it was — so that a match is acted on for each, and is no longer
///    theirs;
/// 4. every picture an account has now, or new for the email, that the
///    check found should be hidden is hidden, unless the operator
///    allowed it, in case hiding it as it was set did not take; and what
///    the operator allowed stays allowed while its copy is kept;
/// 5. with [send] ({subject, text, html}), the operator is emailed every
///    picture set and not yet told of but one PhotoDNA matched, account
///    by account, oldest account first, whole accounts up to
///    [REVIEW_MOST] pictures, each marked told once the email has gone.
///
/// What was written less than a day ago is left as it is (SETTLED_MS).
/// Returns {deleted, asked, sent, more}.
export async function reviewRun({ bucket, store, send = null, ask = null, now = Date.now }) {
  const t = now();
  const today = new Date(t).toISOString();
  const [copies, notes] = await Promise.all([listed(bucket, REVIEW_PREFIX), listed(bucket, ACCOUNT_PICTURES_PREFIX)]);
  const digestIn = (c) => c.key.slice(REVIEW_PREFIX.length).replace(/\.jpg$/, '');
  for (const n of notes) [n.account, n.digest] = n.key.slice(ACCOUNT_PICTURES_PREFIX.length).split('/');
  const settled = (o) => t - o.uploaded >= SETTLED_MS;
  const replaced = async (n) => {
    n.replaced = today;
    await bucket.put(n.key, '', { customMetadata: noteMeta(n) });
  };

  // 1. Squared with the profiles.
  const pictures = new Map();
  const pictureOf = async (account) => {
    if (!pictures.has(account)) {
      const profile = isAccount(account) ? await store.get(`ACCOUNT#${account}`, 'PROFILE') : null;
      pictures.set(account, profile?.picture ? await pictureDigest(profile.picture) : null);
    }
    return pictures.get(account);
  };
  for (const n of notes) {
    if (!n.replaced && settled(n) && (await pictureOf(n.account)) !== n.digest) await replaced(n);
  }

  // 2. Kept as long as promised, and no longer.
  const old = notes.filter((n) => n.replaced && t - Date.parse(n.replaced) >= PICTURE_KEPT_DAYS * DAY_MS);
  const live = notes.filter((n) => !old.includes(n));
  const named = new Set(live.map((n) => n.digest));
  const stale = [...old, ...copies.filter((c) => !named.has(digestIn(c)) && settled(c))];
  for (let i = 0; i < stale.length; i += 1000) await bucket.delete(stale.slice(i, i + 1000).map((o) => o.key));
  const kept = copies.filter((c) => !stale.includes(c));

  // 3. PhotoDNA asked again.
  let asked = 0;
  const matched = new Set();
  for (const c of ask ? kept : []) {
    const digest = digestIn(c);
    const theirs = live.filter((n) => n.digest === digest);
    if (c.known === 'clear' || !theirs.length) continue;
    const copy = await bucket.get(c.key);
    if (!copy) continue;
    const bytes = new Uint8Array(await copy.arrayBuffer());
    const jpeg = btoa(String.fromCharCode(...bytes));
    for (const n of theirs) {
      let said;
      try {
        said = await ask({ jpeg, account: n.account, key: null, shown: true, at: n.at || null });
      } catch {
        // The object out of reach: asked again tomorrow.
        break;
      }
      asked++;
      if (said === 'clear') {
        await bucket.put(c.key, bytes, { httpMetadata: copy.httpMetadata, customMetadata: { ...copy.customMetadata, known: 'clear' } });
        break;
      }
      // PhotoDNA without its key, or not answering: tomorrow.
      if (said !== 'match') break;
      // The object acts on it, for this account (known.mjs); one no
      // longer theirs keeps since when, so its year is not begun again.
      matched.add(digest);
      if (!n.replaced) await replaced(n);
    }
  }

  // 4. Hidden, unless the operator allowed it.
  const checks = new Map(kept.map((c) => [digestIn(c), checkOf(c.check)]));
  const untold = live.filter((n) => !n.told && !matched.has(n.digest));
  const toHide = [...new Set([...live.filter((n) => !n.replaced), ...untold].map((n) => n.digest))].filter((d) => hiddenFor(checks.get(d)).length);
  const allowed = await hidePictures(store, toHide, t, new Set(kept.map(digestIn)));
  if (!send) return { deleted: stale.length, asked, sent: 0, more: 0 };

  // 5. The email.
  const byAccount = new Map();
  for (const n of untold) {
    if (!byAccount.has(n.account)) byAccount.set(n.account, []);
    byAccount.get(n.account).push({ note: n, digest: n.digest, at: n.at, current: !n.replaced, check: checks.get(n.digest) ?? null, allowed: allowed.has(n.digest) });
  }
  const first = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const waiting = [...byAccount.entries()]
    .map(([account, uses]) => ({ account, uses: uses.sort((a, b) => first(a.at, b.at)) }))
    .map((a) => ({ ...a, urgent: a.uses.some(urgent) }))
    // The accounts with a picture hidden as nudity or sexual content
    // first, so that they are never left for a later email.
    .sort((a, b) => (a.urgent !== b.urgent ? (a.urgent ? -1 : 1) : first(a.uses[0].at, b.uses[0].at)));
  const total = waiting.reduce((count, a) => count + a.uses.length, 0);
  if (!total) return { deleted: stale.length, asked, sent: 0, more: 0 };
  // Whole accounts: one is never split across two emails.
  const shown = [];
  let count = 0;
  for (const a of waiting) {
    if (shown.length && count + a.uses.length > REVIEW_MOST) break;
    shown.push(a);
    count += a.uses.length;
  }
  await send(
    reviewEmail(
      shown.map((a) => ({ account: a.account, pictures: a.uses.map(({ digest, at, current, check, allowed: put }) => ({ digest, at, current, check, allowed: put })) })),
      total - count,
    ),
  );
  for (const a of shown) {
    for (const u of a.uses) {
      u.note.told = today;
      await bucket.put(u.note.key, '', { customMetadata: noteMeta(u.note) });
    }
  }
  return { deleted: stale.length, asked, sent: count, more: total - count };
}
