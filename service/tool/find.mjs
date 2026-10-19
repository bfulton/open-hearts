// An account found as `oh account` finds one (ops/account.mjs): by the name it plays under, by the address its web
// subscription was paid with, by a picture it put out, or by one of its devices' keys.

import { accountsNamed, accountsPaidBy } from '../functions/deletion.mjs';
import { SEEN_PREFIX, pictureDigest, pictureNamed } from '../functions/pictures.mjs';
import { isAccount } from '../functions/rows.mjs';

/// The accounts [asked] names: as a name always, since one can have an
/// @ in it; as an email address too when it could be one, which needs
/// [stripeKey]; and as a picture when it names one (pictureNamed),
/// which needs the bucket of [pictures]. {found, notes, pictures}: the
/// accounts, what could not be looked for and why, and for each account
/// found by its picture whether the picture is its profile's now.
export async function findAccounts(store, asked, { stripeKey = null, fetchImpl = fetch, pictures = null } = {}) {
  const found = new Set(await accountsNamed(store, store.list, asked));
  const notes = [];
  const putOut = new Map();
  const digest = pictureNamed(asked);
  if (digest) {
    if (!pictures) {
      notes.push('not looked for as a picture, which needs the pictures bucket');
    } else {
      for (const account of await accountsThatPutOut(pictures, digest)) {
        found.add(account);
        const profile = await store.get(`ACCOUNT#${account}`, 'PROFILE');
        putOut.set(account, (await pictureDigest(profile?.picture)) === digest);
      }
    }
  }
  if (asked.includes('@')) {
    if (!stripeKey) {
      notes.push('not looked for as an email address, which needs STRIPE_API_KEY');
    } else {
      const stripe = async (path) => {
        const res = await fetchImpl(`https://api.stripe.com/v1${path}`, { headers: { authorization: `Bearer ${stripeKey}` } });
        if (!res.ok) throw new Error(`Stripe said ${res.status}`);
        return res.json();
      };
      for (const a of await accountsPaidBy(store, stripe, asked)) found.add(a);
    }
  }
  return { found, notes, pictures: putOut };
}

/// The accounts that put out the picture [digest], as the relay noted
/// each in [pictures] (service/do/review.mjs): for 30 days from the
/// account's last use of it.
export async function accountsThatPutOut(pictures, digest) {
  const ending = `/${digest}`;
  return [...new Set((await pictures.list(SEEN_PREFIX)).filter((k) => k.endsWith(ending)).map((k) => k.slice(SEEN_PREFIX.length).split('/')[0]))].filter(isAccount);
}

/// The account [target] is: itself, when it is one (32 hex), or the
/// account of the device it is the key of (64 hex). Null for neither.
export async function accountOf(store, target) {
  if (isAccount(target)) return target;
  if (typeof target !== 'string' || !/^[0-9a-f]{64}$/.test(target)) return null;
  const account = (await store.get(`KEY#${target}`, 'ENTITLEMENT'))?.account;
  return isAccount(account) ? account : null;
}
