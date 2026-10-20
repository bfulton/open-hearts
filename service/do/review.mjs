// The pictures accounts set, for the operator to look at
// (docs/explanation/relay.md, "Pictures to look at"), kept as each is set
// (profile_pictures.mjs). Only a subscriber has an account, so only
// subscribers' pictures are kept. Nothing waits on the operator: a
// picture is shown once it is checked, and taken down after if it has to
// be (`oh account remove`).
//
// As an account's copy of a picture is made, a model looks at it, and
// one that shows nudity or sexual content, violence or gore, or a hate
// symbol is hidden at once: withheld at the relay as a picture the
// operator took down is (service/functions/pictures.mjs). Once a day the
// worker's schedule goes over every copy kept, and does only what each
// copy's own flags say is still to do: deletes what is kept no longer
// than promised; asks PhotoDNA again about what it has not cleared;
// hides again what the check found should be; and emails the operator,
// account by account, every picture each set since the last email — the
// ones it has since replaced too, so that swapping a picture back before
// the email hides nothing — what the check made of it, and how to take it
// down or put it back. Apart from worker.mjs so it can be tested without
// the runtime.

import { HOLD_DAYS } from '../functions/holds.mjs';
import { forgottenKey } from '../functions/records.mjs';
import { ACCOUNT_PICTURES_PREFIX, PICTURES_ORIGIN, PICTURES_ROW, allowedOf, changePicture, pictureDigest, pictureParts, pictureUrl, stillAllowing, withheldOf, withholding } from '../functions/pictures.mjs';

/// Where the copies are served (service/functions/pictures.mjs).
export { PICTURES_ORIGIN };

const DAY_MS = 24 * 60 * 60 * 1000;

/// How long a picture is kept after it stops being its account's —
/// replaced, taken off, or the account deleted — in days: as long as a
/// hold keeps one reported (holds.mjs), so that a picture is kept as
/// long whether or not it was reported.
export const PICTURE_KEPT_DAYS = HOLD_DAYS;

/// How long a copy is left alone after it was written before the run
/// holds it to its account's profile: the store shows a changed profile
/// everywhere within a minute or so, and a save writes the copy a moment
/// before the profile, so the run never takes one being made for one a
/// save left behind.
const SETTLED_MS = DAY_MS;

/// How often the run holds each account's copies to its profile, in
/// days, on a day its number gives it; and every day for a week after
/// they were last written. A save, or the run, writes them, so an account
/// written to lately is the one most likely out of step; the weekly turn
/// catches what changed a profile outside the account's turn (`oh
/// account delete`, service/tool/forget.mjs), and the week of days covers
/// runs that failed meanwhile.
const SQUARE_EVERY_DAYS = 7;

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

/// What a copy's metadata [m] says, as profile_pictures.mjs writes it.
const flagsOf = (m = {}) => ({ at: m.at ?? '', told: m.told ?? null, replaced: m.replaced ?? null, check: m.check ?? null, known: m.known ?? null });

/// Every account's copy of every picture in [bucket]: {key, account,
/// digest, at, told, replaced, check, known, uploaded}.
async function listed(bucket) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix: ACCOUNT_PICTURES_PREFIX, cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      const parts = pictureParts(o.key);
      if (parts) found.push({ key: o.key, ...parts, ...flagsOf(o.customMetadata), uploaded: new Date(o.uploaded).getTime() });
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
  const url = (a, p) => pictureUrl(a.account, p.digest);
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
      ...a.pictures.map((p) => `  ${p.at}  ${url(a, p)}  ${notes(p).join('; ')}`),
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
              `<span style="display:inline-block;margin:4px;text-align:center;vertical-align:top;max-width:180px"><a href="${url(a, p)}"><img src="${url(a, p)}" width="128" height="128" alt="picture ${escape(p.digest.slice(0, 8))}" style="object-fit:cover"></a>` +
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

/// The day's run, over every account's copy of every picture
/// ([bucket]) and [store] (the accounts' profiles, and the pictures
/// withheld), each copy's own flags saying what is still to do for it:
///
/// 1. an account whose copies were written in the last week, one that
///    has more than one that says it is its picture now, and every other
///    on its day of the week (SQUARE_EVERY_DAYS) is held to its profile:
///    each such copy but its profile's picture says from today that it
///    no longer is — a save that stopped part way, or the account
///    deleted, and then from when it was, as the mark its deletion left
///    in [records] (OH_RECORDS) says. Only the account's turn makes a
///    picture its own, as it checks it (profile_pictures.mjs), so the run
///    only ever says one is not;
/// 2. a copy that has not been its account's for [PICTURE_KEPT_DAYS]
///    is deleted;
/// 3. with [ask] (known.mjs, knownAsker), each copy PhotoDNA has not
///    cleared is asked about again, for its account, whether or not the
///    account still has it — each was shown while it did — so that a
///    match is acted on for each account that set it, and is no longer
///    theirs;
/// 4. every picture an account has now, or new for the email, that the
///    check found should be hidden is hidden, unless the operator
///    allowed it, in case hiding it as it was set did not take; and what
///    the operator allowed stays allowed while a copy of it is kept;
/// 5. with [send] ({subject, text, html}), the operator is emailed every
///    copy not yet told of but one PhotoDNA matched, account by account,
///    oldest account first, whole accounts up to [REVIEW_MOST] pictures,
///    each marked told once the email has gone.
///
/// A copy written less than a day ago is left as it is (SETTLED_MS).
/// Each change to a copy is written only if nothing else wrote it
/// meanwhile (changePicture); one that loses is left for the next day,
/// and [log] says so. Returns {deleted, asked, sent, more}.
export async function reviewRun({ bucket, store, records = null, send = null, ask = null, now = Date.now, log = () => {} }) {
  const t = now();
  const today = new Date(t).toISOString();
  const copies = await listed(bucket);
  const settled = (c) => t - c.uploaded >= SETTLED_MS;
  // [c] made what [change] makes of its metadata, and [c] what it says
  // now: false when it is gone, or another writer won every time.
  const changed = async (c, change) => {
    try {
      const m = await changePicture(bucket, c.key, change);
      if (!m) return false;
      Object.assign(c, flagsOf(m));
      return true;
    } catch (e) {
      log(`picture ${c.key} left for the next run: ${e?.message ?? e}`);
      return false;
    }
  };
  const replaced = (c) => changed(c, (m) => (m.replaced ? null : { ...m, replaced: today }));

  // 1. Held to the profiles, where something changed.
  const byAccount = new Map();
  for (const c of copies) byAccount.set(c.account, [...(byAccount.get(c.account) ?? []), c]);
  const day = Math.floor(t / DAY_MS) % SQUARE_EVERY_DAYS;
  for (const [account, theirs] of byAccount) {
    const current = theirs.filter((c) => !c.replaced && settled(c));
    const lately = theirs.some((c) => t - c.uploaded < SQUARE_EVERY_DAYS * DAY_MS);
    const itsDay = parseInt(account.slice(0, 8), 16) % SQUARE_EVERY_DAYS === day;
    if (!current.length || (!lately && !itsDay && current.length < 2)) continue;
    const profile = await store.get(`ACCOUNT#${account}`, 'PROFILE');
    const itsNow = profile?.picture ? await pictureDigest(profile.picture) : null;
    const theirsNoMore = current.filter((c) => c.digest !== itsNow);
    if (!theirsNoMore.length) continue;
    // An account deleted outside its turn (`oh account delete`) found on
    // its day of the week: its pictures stopped being its own when it
    // was deleted, so that each is kept a year from then and no longer.
    const deleted = !profile && records ? (await records.head(forgottenKey(account)))?.uploaded : null;
    for (const c of theirsNoMore) {
      const since = deleted && new Date(deleted).getTime() >= Date.parse(c.at) ? new Date(deleted).toISOString() : today;
      await changed(c, (m) => (m.replaced ? null : { ...m, replaced: since }));
    }
  }

  // 2. Kept as long as promised, and no longer: each read again just
  // before, so that one its account has set again since stays.
  const expired = (c) => !!c.replaced && t - Date.parse(c.replaced) >= PICTURE_KEPT_DAYS * DAY_MS;
  const stale = [];
  for (const c of copies.filter(expired)) {
    const still = await bucket.head(c.key);
    if (!still || !expired(flagsOf(still.customMetadata))) continue;
    await bucket.delete(c.key);
    stale.push(c);
  }
  const kept = copies.filter((c) => !stale.includes(c));

  // 3. PhotoDNA asked again.
  let asked = 0;
  const matched = new Set();
  for (const c of ask ? kept : []) {
    if (c.known === 'clear') continue;
    const copy = await bucket.get(c.key);
    if (!copy) continue;
    const jpeg = btoa(String.fromCharCode(...new Uint8Array(await copy.arrayBuffer())));
    let said;
    try {
      said = await ask({ jpeg, account: c.account, key: null, shown: true, at: c.at || null });
    } catch {
      // The object out of reach: asked again tomorrow.
      break;
    }
    asked++;
    if (said === 'clear') {
      await changed(c, (m) => (m.known === 'clear' ? null : { ...m, known: 'clear' }));
    } else if (said === 'match') {
      // The object acts on it for this account and deletes the copy
      // (known.mjs); one no longer theirs keeps since when, so that its
      // year is not begun again.
      matched.add(c.key);
      if (!c.replaced) await replaced(c);
    } else {
      // PhotoDNA without its key, or not answering: tomorrow.
      break;
    }
  }

  // 4. Hidden, unless the operator allowed it.
  const untold = kept.filter((c) => !c.told && !matched.has(c.key));
  const shownNow = kept.filter((c) => !c.replaced && !matched.has(c.key));
  const toHide = [...new Set([...shownNow, ...untold].filter((c) => hiddenFor(checkOf(c.check)).length).map((c) => c.digest))];
  const allowed = await hidePictures(store, toHide, t, new Set(kept.map((c) => c.digest)));
  if (!send) return { deleted: stale.length, asked, sent: 0, more: 0 };

  // 5. The email.
  const toTell = new Map();
  for (const c of untold) {
    const use = { copy: c, digest: c.digest, at: c.at, current: !c.replaced, check: checkOf(c.check), allowed: allowed.has(c.digest) };
    toTell.set(c.account, [...(toTell.get(c.account) ?? []), use]);
  }
  const first = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const waiting = [...toTell.entries()]
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
  for (const a of shown) for (const u of a.uses) await changed(u.copy, (m) => (m.told ? null : { ...m, told: today }));
  return { deleted: stale.length, asked, sent: count, more: total - count };
}
