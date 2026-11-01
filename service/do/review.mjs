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
// copy's own flags say is still to do: holds each account's copies to
// the order it set them in; deletes what is kept no longer than
// promised; asks the checker of known images in use (checkers.mjs)
// again about what no checker has cleared;
// hides again what the check found should be; and emails the operator,
// account by account, every picture each set since the last email — the
// ones it has since replaced too, so that swapping a picture back before
// the email hides nothing — what the check made of it, and how to take it
// down or put it back. Apart from worker.mjs so it can be tested without
// the runtime.

import { CHECKERS, SHIELD } from './checkers.mjs';
import { HOLD_DAYS } from '../functions/holds.mjs';
import { forgottenKey } from '../functions/records.mjs';
import { base64Of } from '../functions/rows.mjs';
import { ACCOUNT_PICTURES_PREFIX, PICTURES_ORIGIN, PICTURES_ROW, allowedOf, changePicture, copyOf, currentOf, knownFlags, newestFirst, pictureUrl, settleCopies, stillAllowing, withheldOf, withholding } from '../functions/pictures.mjs';

/// Where the copies are served (service/functions/pictures.mjs).
export { PICTURES_ORIGIN };

const DAY_MS = 24 * 60 * 60 * 1000;

/// How long a picture is kept after it stops being its account's —
/// replaced, taken off, or the account deleted — in days: as long as a
/// hold keeps one reported (holds.mjs), so that a picture is kept as
/// long whether or not it was reported.
export const PICTURE_KEPT_DAYS = HOLD_DAYS;

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

/// Every account's copy of every picture in [bucket], as copyOf says
/// it.
async function listed(bucket) {
  const found = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix: ACCOUNT_PICTURES_PREFIX, cursor, include: ['customMetadata'] });
    for (const o of page.objects) {
      const c = copyOf(o);
      if (c) found.push(c);
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

/// When each account [records] (OH_RECORDS) marks forgotten was marked,
/// in milliseconds, by account.
async function forgottenIn(records) {
  const prefix = forgottenKey('');
  const found = new Map();
  let cursor;
  do {
    const page = await records.list({ prefix, cursor });
    for (const o of page.objects) found.set(o.key.slice(prefix.length), new Date(o.uploaded).getTime());
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/// What a picture in the email says of what was said of it against known
/// images, from its copy's flags [known] ({known, knownBy, knownAt}): a
/// copy cleared before copies kept receipts was cleared by Arachnid
/// Shield.
const knownNote = ({ known, knownBy, knownAt } = {}) =>
  known === 'clear'
    ? `cleared of known images by ${CHECKERS[knownBy ?? SHIELD]?.name ?? knownBy}${knownAt ? ` at ${knownAt}` : ''}`
    : known === 'unreadable'
      ? 'hidden: it could not be decoded or hashed, so it could not be checked against known images'
      : 'not yet checked against known images: asked again by the next run';

/// What the check made of [p], a picture in the email: the questions
/// it was hidden for, and whether the operator has put it back since.
const hiddenOf = (p) => (p.check ? hiddenFor(p.check) : []);
const urgent = (p) => !p.allowed && hiddenOf(p).includes('sexual');

/// The email for [accounts], each {account, pictures: [{digest, at,
/// current, check, allowed, known}]}: account by account, every picture
/// it set, in order, which is its profile's now, what the check made of
/// it (`check`, its scores; {} when the check failed; null when there
/// was none), whether the operator allowed it after the check hid it,
/// what was said of it against known images ([known], the copy's
/// {known, knownBy, knownAt}: which checker cleared it and when, that it
/// was hidden for not decoding, or that it is not yet checked), and
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
      knownNote(p.known),
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
/// ([bucket]) and [store] (the pictures withheld), each copy's own flags
/// saying what is still to do for it:
///
/// 1. each account's copies are held to the order it set them in: each
///    but the one it set last says since when it is no longer the
///    account's picture, from when the one after it was set, in case the
///    save that set that one stopped part way; and the one it set last
///    too, for an account deleted outside its turn (`oh account
///    delete`, service/tool/forget.mjs), from when the mark its deletion
///    left in [records] (OH_RECORDS) was made;
/// 2. a copy that has not been its account's for [PICTURE_KEPT_DAYS]
///    is deleted, each account's oldest first;
/// 3. with [ask] (known.mjs, knownAsker), each copy no checker has
///    cleared is asked about again, for its account, whether or not the
///    account still has it — each was shown while it did — so that a
///    match, or a picture Shield knows as harmful, is acted on for each
///    account that set it, and is no longer theirs; and one that cannot
///    be decoded or hashed is said to be; and each answer is kept with
///    its receipt, which checker said it and when;
/// 4. every picture an account has now, or new for the email, that the
///    check found should be hidden, or that cannot be decoded, is hidden,
///    unless the operator allowed it, in case hiding it as it was set did
///    not take; and what the operator allowed stays allowed while a copy
///    of it is kept;
/// 5. with [send] ({subject, text, html}), the operator is emailed every
///    copy not yet told of but one a checker matched, account by account,
///    oldest account first, whole accounts up to [REVIEW_MOST] pictures,
///    each marked told once the email has gone.
///
/// Each change to a copy is written only if nothing else wrote it
/// meanwhile (changePicture); one that loses is left for the next day,
/// and [log] says so. The run never makes a picture an account's: only
/// the account's turn sets one, as it checks it. Returns {deleted,
/// asked, sent, more}.
export async function reviewRun({ bucket, store, records = null, send = null, ask = null, now = Date.now, log = () => {} }) {
  const t = now();
  const today = new Date(t).toISOString();
  const copies = await listed(bucket);
  // [c] made what [change] makes of its metadata, and [c] what it says
  // now: false when it is gone, or another writer won every time.
  const changed = async (c, change) => {
    try {
      const m = await changePicture(bucket, c.key, change);
      if (!m) return false;
      Object.assign(c, copyOf({ key: c.key, customMetadata: m, uploaded: c.uploaded }));
      return true;
    } catch (e) {
      log(`picture ${c.key} left for the next run: ${e?.message ?? e}`);
      return false;
    }
  };
  // Each account's copies, the one it set last first.
  const byAccount = new Map();
  for (const c of copies) byAccount.set(c.account, [...(byAccount.get(c.account) ?? []), c]);
  for (const [account, theirs] of byAccount) byAccount.set(account, newestFirst(theirs));
  // [account]'s copies held to their order, the one set last ended from
  // [end] when given.
  const settle = async (account, end = null) => {
    try {
      await settleCopies(bucket, byAccount.get(account), { end });
    } catch (e) {
      log(`pictures of ${account} left for the next run: ${e?.message ?? e}`);
    }
  };

  // 1. Held to the order each account set them in.
  const forgotten = records ? await forgottenIn(records) : new Map();
  for (const [account, theirs] of byAccount) {
    // Deleted outside its turn: its picture stopped being its own when
    // it was, so that it is kept a year from then and no longer; or,
    // set after the mark was made, from the run that finds it.
    const deleted = currentOf(theirs) ? forgotten.get(account) : undefined;
    const end = deleted === undefined ? null : deleted >= Date.parse(theirs[0].last) ? new Date(deleted).toISOString() : today;
    await settle(account, end);
  }

  // 2. Kept as long as promised, and no longer: each account's oldest
  // first, stopping at the first that is not, so that none is left to
  // become the account's picture now as the one after it goes; and each
  // read again just before, so that one its account has set again since
  // stays.
  const expired = (c) => !!c.ended && t - Date.parse(c.ended) >= PICTURE_KEPT_DAYS * DAY_MS;
  const stale = new Set();
  for (const theirs of byAccount.values()) {
    for (const c of [...theirs].reverse()) {
      if (!expired(c)) break;
      const still = await bucket.head(c.key);
      if (!still) continue;
      if (!expired(copyOf(still))) break;
      await bucket.delete(c.key);
      stale.add(c);
    }
  }
  const kept = copies.filter((c) => !stale.has(c));

  // 3. The checkers asked again.
  let asked = 0;
  const matched = new Set();
  for (const c of ask ? kept : []) {
    if (c.known === 'clear' || c.known === 'unreadable') continue;
    const copy = await bucket.get(c.key);
    if (!copy) continue;
    const jpeg = base64Of(new Uint8Array(await copy.arrayBuffer()));
    let answer;
    try {
      answer = await ask({ jpeg, account: c.account, key: null, shown: true, at: c.at || null });
    } catch {
      // The object out of reach: asked again tomorrow.
      break;
    }
    asked++;
    const { said } = answer;
    if (said === 'clear' || said === 'unreadable') {
      // Unreadable: no hash can be made of it, so nothing can be asked;
      // hidden below, as the app's own pictures never are.
      await changed(c, (m) => (m.known === said ? null : { ...m, ...knownFlags(said, answer) }));
    } else if (said === 'match' || said === 'harmful') {
      // The object acts on it for this account and deletes the copy
      // (known.mjs); the account's picture now is no longer its own
      // from today, and one before keeps since when, so that its year
      // is not begun again.
      matched.add(c.key);
      if (currentOf(byAccount.get(c.account)) === c) await settle(c.account, today);
    } else {
      // No checker on, or one not answering: tomorrow.
      break;
    }
  }

  // 4. Hidden, unless the operator allowed it.
  const current = new Set([...byAccount.values()].map(currentOf).filter(Boolean));
  const untold = kept.filter((c) => !c.told && !matched.has(c.key));
  const shownNow = kept.filter((c) => current.has(c) && !matched.has(c.key));
  const toHide = [...new Set([...shownNow, ...untold].filter((c) => hiddenFor(checkOf(c.check)).length || c.known === 'unreadable').map((c) => c.digest))];
  const allowed = await hidePictures(store, toHide, t, new Set(kept.map((c) => c.digest)));
  if (!send) return { deleted: stale.size, asked, sent: 0, more: 0 };

  // 5. The email.
  const toTell = new Map();
  for (const c of untold) {
    const use = { copy: c, digest: c.digest, at: c.at, current: current.has(c), check: checkOf(c.check), allowed: allowed.has(c.digest), known: { known: c.known, knownBy: c.knownBy, knownAt: c.knownAt } };
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
  if (!total) return { deleted: stale.size, asked, sent: 0, more: 0 };
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
      shown.map((a) => ({ account: a.account, pictures: a.uses.map(({ digest, at, current, check, allowed: put, known }) => ({ digest, at, current, check, allowed: put, known })) })),
      total - count,
    ),
  );
  for (const a of shown) for (const u of a.uses) await changed(u.copy, (m) => (m.told ? null : { ...m, told: today }));
  return { deleted: stale.size, asked, sent: count, more: total - count };
}
