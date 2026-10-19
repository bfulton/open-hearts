// An account's pictures. A picture enters where the account sets it, as
// its profile is saved (service/functions/profile.mjs, in the account's
// turn), and is checked there, once, before anyone is shown it: by
// Microsoft's PhotoDNA, against known images of child sexual abuse,
// through the one object that asks it from the United States
// (known.mjs); and by a model that hides one that shows nudity or sexual
// content, violence or gore, or a hate symbol (review.mjs). A match is
// never kept: the profile is saved without it, and the object acts on
// it. Anything else is copied (service/functions/pictures.mjs, copyKey)
// and noted as the account's picture now (accountPictureKey); the note
// of the one it had before says since when it no longer is, and the
// daily run keeps each picture for a year after that (review.mjs,
// PICTURE_KEPT_DAYS), as long as a hold keeps one reported.
//
// Only the operator reaches what is kept. Players are shown an account's
// picture now and nothing else: the relay carries a picture only if it
// is noted as its account's picture now (ownedScreen), so a picture
// nobody checked, or one the account no longer has, is never carried.
// Apart from worker.mjs so it can be tested without the runtime.

import { alertKnownProblem } from '../functions/alerts.mjs';
import { NOT_THEIRS_WHY, accountPictureKey, copyKey, pictureDigest, pictureIn } from '../functions/pictures.mjs';
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
/// asks the object about a picture ({jpeg, account, key} -> 'clear',
/// 'match', 'failed' or 'off'; knownAsker), or null while PhotoDNA has
/// no key. Without the bucket, nothing is kept or checked, and the relay
/// carries no picture.
export function accountPictures(env, { now = Date.now, log = (line) => console.log(line), ask = knownAsker(env), store = storeOf(env) } = {}) {
  const bucket = env.OH_PICTURES ?? null;

  /// [account]'s note of [digest], if it says the picture is its now,
  /// made to say it no longer is, from [at].
  const replace = async (account, digest, at) => {
    const key = accountPictureKey(account, digest);
    const noted = await bucket.head(key);
    if (noted && !noted.customMetadata?.replaced) await bucket.put(key, '', { customMetadata: { ...noted.customMetadata, replaced: at } });
  };

  return {
    /// [picture] (base64, or null for none) set as [account]'s by its
    /// device [key] (null for the operator's order) over [prev], the one
    /// its profile had: resolves the picture the profile keeps, which is
    /// [picture], or null for one PhotoDNA matched.
    async set({ account, key = null, picture, prev = null }) {
      if (!bucket || !isAccount(account)) return picture;
      const at = new Date(now()).toISOString();
      const digest = picture ? await pictureDigest(picture) : null;
      const was = prev ? await pictureDigest(prev) : null;
      if (!digest) {
        if (was) await replace(account, was, at);
        return null;
      }
      // Asked each time, which the object answers from what it holds
      // once it has asked PhotoDNA: a picture set while PhotoDNA had no
      // key, or did not answer, is asked about again by the daily run.
      let said = 'off';
      if (ask) {
        try {
          said = await ask({ jpeg: picture, account, key });
        } catch (e) {
          said = 'unreachable';
          const error = `a picture was set unchecked, to be asked about again by the daily run: ${e?.message ?? e}`;
          log(error);
          await alertKnownProblem(env, store, { what: 'unreachable', error, now: now() });
        }
      }
      if (said === 'match') {
        // Never kept, and never the account's: not this one, nor the
        // one before, which the profile no longer has.
        await replace(account, digest, at);
        if (was && was !== digest) await replace(account, was, at);
        return null;
      }
      const copy = copyKey(digest);
      const had = await bucket.head(copy);
      let hidden = [];
      if (!had) {
        let check = null;
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
        await bucket.put(copy, bytesOf(picture), { httpMetadata: COPY_HTTP, customMetadata: { at, ...(check ? { check } : {}), known: said } });
      } else {
        hidden = hiddenFor(checkOf(had.customMetadata?.check));
        // What PhotoDNA said, once it has: never taken back.
        if (said === 'clear' && had.customMetadata?.known !== 'clear') {
          await bucket.put(copy, bytesOf(picture), { httpMetadata: COPY_HTTP, customMetadata: { ...had.customMetadata, known: said } });
        }
      }
      // The account's picture now, before the one before is not, so
      // that it always has one the relay carries.
      const mine = accountPictureKey(account, digest);
      const noted = await bucket.head(mine);
      if (!noted) await bucket.put(mine, '', { customMetadata: { at } });
      else if (noted.customMetadata?.replaced) {
        const { replaced: _, ...rest } = noted.customMetadata;
        await bucket.put(mine, '', { customMetadata: rest });
      }
      if (was && was !== digest) await replace(account, was, at);
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
/// as its note in [bucket] says; NOT_THEIRS_WHY for any other — one the
/// account has not set, or not yet, one it no longer has, one from a
/// device with no account — and for any where the note cannot be read.
export function ownedScreen({ bucket, log = null }) {
  return async (event, who) => {
    if (event?.kind !== lobbyKind) return null;
    const jpeg = pictureIn(event.content);
    if (!jpeg) return null;
    const digest = await pictureDigest(jpeg);
    if (!bucket || !digest || !isAccount(who?.account)) return NOT_THEIRS_WHY;
    try {
      const noted = await bucket.head(accountPictureKey(who.account, digest));
      return noted && !noted.customMetadata?.replaced ? null : NOT_THEIRS_WHY;
    } catch (e) {
      log?.(`a picture's note was not read: ${e?.message ?? e}`);
      return NOT_THEIRS_WHY;
    }
  };
}
