// An account's pictures. A picture enters where the account sets it, as
// its profile is saved (service/functions/profile.mjs, in the account's
// turn), and is checked there before anyone is shown it: by the
// checker in use, Arachnid Shield or PhotoDNA (checkers.mjs), against
// known images of child sexual abuse, through the one object kept in
// the United States (known.mjs); and by a model that hides one that
// shows nudity or
// sexual content, violence or gore, or a hate symbol (review.mjs). A
// match is never kept, nor is a picture Shield knows as a harmful or
// abusive image of a child: the profile is saved without it, and the
// object acts on it. Anything else
// is kept as the account's own copy of it, with all that is known of it
// (service/functions/pictures.mjs, pictureKey), and said to be set last,
// which makes it the account's picture now; the one before it says
// since when it no longer is, and the daily run keeps each for a year
// after that (review.mjs, PICTURE_KEPT_DAYS), as long as a hold keeps
// one reported. Two accounts that set the same picture each have their
// own copy, checked and acted on for each.
//
// Only the operator reaches what is kept. Players are shown an account's
// picture now and nothing else: the relay carries a picture only if it
// is the one the account set last, and has not ended (ownedScreen), so a
// picture nobody checked, or one the account no longer has, is never
// carried. Apart from worker.mjs so it can be tested without the
// runtime.

import { alertKnownProblem } from '../functions/alerts.mjs';
import { NOT_THEIRS_WHY, changePicture, copiesOf, currentOf, knownFlags, pictureDigest, pictureIn, pictureKey, settleCopies } from '../functions/pictures.mjs';
import { isAccount, storeOf } from '../functions/rows.mjs';
import { knownAsker } from './known.mjs';
import { checkOf, checkPicture, checkText, hiddenFor, hidePictures } from './review.mjs';
import { lobbyKind } from './relay.mjs';

const bytesOf = (base64) => Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));

/// How a copy is served: for the email, a day in any cache.
const COPY_HTTP = { contentType: 'image/jpeg', cacheControl: 'public, max-age=86400' };

/// How the account's turn keeps its pictures (household.mjs), where the
/// relay worker runs it with [env]: the pictures bucket (OH_PICTURES),
/// Workers AI (AI), [store] (the pictures withheld), and [ask], which
/// asks the object about a picture ({jpeg, account, key, shown, at} ->
/// {said, knownBy, knownAt}, [said] 'clear', 'match', 'harmful',
/// 'failed', 'unreadable' or 'off', and the receipt for it; knownAsker),
/// or null while no checker has credentials. Without the bucket, nothing
/// is kept or checked, and the relay carries no picture.
export function accountPictures(env, { now = Date.now, log = (line) => console.log(line), ask = knownAsker(env), store = storeOf(env) } = {}) {
  const bucket = env.OH_PICTURES ?? null;

  /// [copies] held to their order, the first ended from [end] when
  /// given: a write another kept from it is left for the daily run,
  /// since the one set last is the account's picture now either way.
  const settle = async (copies, end = null) => {
    try {
      await settleCopies(bucket, copies, { end });
    } catch (e) {
      log(`a picture before this one left for the daily run: ${e?.message ?? e}`);
    }
  };

  return {
    /// [picture] (base64, or null for none) set as [account]'s by its
    /// device [key] (null for the operator's order): resolves the
    /// picture the profile keeps, which is [picture], or null for one a
    /// checker matched or Shield knows as harmful, or one that could not
    /// be asked about, being unreadable.
    async set({ account, key = null, picture }) {
      if (!bucket || !isAccount(account)) return picture;
      const theirs = await copiesOf(bucket, account);
      // Later than any it set before, whatever this clock says, so that
      // the order the copies say is the order the account set them in.
      const at = new Date(Math.max(now(), (Date.parse(theirs[0]?.last) || 0) + 1)).toISOString();
      const digest = picture ? await pictureDigest(picture) : null;
      if (!digest) {
        await settle(theirs, at);
        return null;
      }
      const mine = pictureKey(account, digest);
      const had = theirs.find((c) => c.digest === digest) ?? null;
      // Asked each time, which the object answers from what it holds
      // once a checker has said; a picture set while no checker had
      // credentials, or the checker did not answer, is asked about again
      // by the daily run.
      // One the account had before was shown while it was.
      let answer = { said: 'off' };
      if (ask) {
        try {
          answer = await ask({ jpeg: picture, account, key, ...(had ? { shown: true, at: had.at || null } : {}) });
        } catch (e) {
          answer = { said: 'unreachable' };
          const error = `a picture was set unchecked, to be asked about again by the daily run: ${e?.message ?? e}`;
          log(error);
          await alertKnownProblem(env, store, { what: 'unreachable', error, now: now() });
        }
      }
      const { said } = answer;
      if (said === 'match' || said === 'harmful' || said === 'unreadable') {
        // Never the account's, and nothing before it is, since the
        // profile has none: a copy of one kept before, the object
        // deletes as it acts on it (known.mjs). One that cannot be
        // decoded cannot be asked about, which the app's own never are.
        await settle(theirs, at);
        return null;
      }
      // Set last, unless it is the account's picture now already, as
      // first set, and with what a checker said once one has, and its
      // receipt: never taken back.
      const already = !!had && currentOf(theirs) === had;
      const kept = had
        ? await changePicture(bucket, mine, (m) => {
            const known = said === 'clear' && m.known !== 'clear';
            if (already && !known) return null;
            const { ended: _, ...rest } = m;
            return { ...rest, ...(already ? {} : { last: at }), ...(known ? knownFlags('clear', answer) : {}) };
          })
        : null;
      let hidden;
      if (kept) {
        hidden = hiddenFor(checkOf(kept.check));
      } else {
        let check = null;
        hidden = [];
        if (env.AI) {
          try {
            const scores = await checkPicture(env.AI, picture);
            hidden = hiddenFor(scores);
            check = checkText(scores);
          } catch (e) {
            log(`picture not checked: ${e?.message ?? e}`);
            check = 'failed';
          }
        }
        await bucket.put(mine, bytesOf(picture), { httpMetadata: COPY_HTTP, customMetadata: { at, last: at, ...(check ? { check } : {}), ...knownFlags(said, answer) } });
      }
      // The one before says from now that it is no longer the account's;
      // its own copy as it was listed stays in the order, so that one
      // after it a save left unended ends when it was set then.
      await settle(kept && already ? theirs : [{ key: mine, digest, last: at, ended: null }, ...theirs]);
      if (hidden.length && store) {
        try {
          await hidePictures(store, [digest], now());
        } catch (e) {
          // The daily run hides it all the same.
          log(`picture not hidden: ${e?.message ?? e}`);
        }
      }
      return picture;
    },
  };
}

/// What a relay object says of each picture published to it, and who
/// said it (relay.mjs, `screen`): nothing for its account's picture now,
/// the one it set last, as its copies in [bucket] say; NOT_THEIRS_WHY
/// for any other — one the account has not set, or not yet, one it no
/// longer has, one from a device with no account — and for any where
/// the copies cannot be read.
export function ownedScreen({ bucket, log = null }) {
  return async (event, who) => {
    if (event?.kind !== lobbyKind) return null;
    const jpeg = pictureIn(event.content);
    if (!jpeg) return null;
    const digest = await pictureDigest(jpeg);
    if (!bucket || !digest || !isAccount(who?.account)) return NOT_THEIRS_WHY;
    try {
      return currentOf(await copiesOf(bucket, who.account))?.digest === digest ? null : NOT_THEIRS_WHY;
    } catch (e) {
      log?.(`an account's copies were not read: ${e?.message ?? e}`);
      return NOT_THEIRS_WHY;
    }
  };
}
