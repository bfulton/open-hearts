// An account found as `oh account` finds one (ops/account.mjs): by the name it plays under, by the address its web
// subscription was paid with, by a picture it set, or by one of its devices' keys.

import { accountsNamed, accountsPaidBy } from '../functions/deletion.mjs';
import { ACCOUNT_PICTURES_PREFIX, pictureDigest, pictureNamed, pictureParts } from '../functions/pictures.mjs';
import { isAccount } from '../functions/rows.mjs';
import { stripeAuth } from '../functions/stripe.mjs';

/// The accounts [asked] names: as a name always, since one can have an
/// @ in it; as an email address too when it could be one, which needs
/// [stripeKey]; and as a picture when it names one (pictureNamed),
/// which needs the bucket of [pictures]. {found, notes, pictures}: the
/// accounts, what could not be looked for and why, and for each account
/// found by its picture whether the picture is its profile's now.
export async function findAccounts(store, asked, { stripeKey = null, fetchImpl = fetch, pictures = null } = {}) {
  const found = new Set(await accountsNamed(store, store.list, asked));
  const notes = [];
  const theirs = new Map();
  const digest = pictureNamed(asked);
  if (digest) {
    if (!pictures) {
      notes.push('not looked for as a picture, which needs the pictures bucket');
    } else {
      for (const account of await accountsWith(pictures, digest)) {
        found.add(account);
        const profile = await store.get(`ACCOUNT#${account}`, 'PROFILE');
        theirs.set(account, (await pictureDigest(profile?.picture)) === digest);
      }
    }
  }
  if (asked.includes('@')) {
    if (!stripeKey) {
      notes.push('not looked for as an email address, which needs STRIPE_API_KEY');
    } else {
      const stripe = async (path) => {
        const res = await fetchImpl(`https://api.stripe.com/v1${path}`, { headers: stripeAuth(stripeKey) });
        if (!res.ok) throw new Error(`Stripe said ${res.status}`);
        return res.json();
      };
      for (const a of await accountsPaidBy(store, stripe, asked)) found.add(a);
    }
  }
  return { found, notes, pictures: theirs };
}

/// The accounts that set the picture [digest], each with its own copy
/// of it in [pictures] (service/do/profile_pictures.mjs): its picture
/// now, or one it had in the year before (service/do/review.mjs,
/// PICTURE_KEPT_DAYS).
export async function accountsWith(pictures, digest) {
  const theirs = (await pictures.list(ACCOUNT_PICTURES_PREFIX)).map(pictureParts).filter((p) => p?.digest === digest);
  return [...new Set(theirs.map((p) => p.account))];
}

/// The account [target] is: itself, when it is one (32 hex), or the
/// account of the device it is the key of (64 hex). Null for neither.
export async function accountOf(store, target) {
  if (isAccount(target)) return target;
  if (typeof target !== 'string' || !/^[0-9a-f]{64}$/.test(target)) return null;
  const account = (await store.get(`KEY#${target}`, 'ENTITLEMENT'))?.account;
  return isAccount(account) ? account : null;
}
