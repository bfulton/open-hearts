// An account found as `oh account` finds one (ops/account.mjs): by the name it plays under, by the address its web
// subscription was paid with, or by one of its devices' keys.

import { accountsNamed, accountsPaidBy } from '../functions/deletion.mjs';
import { isAccount } from '../functions/rows.mjs';

/// The accounts [asked] names: as a name always, since one can have an
/// @ in it, and as an email address too when it could be one, which
/// needs [stripeKey]. {found, notes}: the accounts, and what could not
/// be looked for and why.
export async function findAccounts(store, asked, { stripeKey = null, fetchImpl = fetch } = {}) {
  const found = new Set(await accountsNamed(store, store.list, asked));
  const notes = [];
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
  return { found, notes };
}

/// The account [target] is: itself, when it is one (32 hex), or the
/// account of the device it is the key of (64 hex). Null for neither.
export async function accountOf(store, target) {
  if (isAccount(target)) return target;
  if (typeof target !== 'string' || !/^[0-9a-f]{64}$/.test(target)) return null;
  const account = (await store.get(`KEY#${target}`, 'ENTITLEMENT'))?.account;
  return isAccount(account) ? account : null;
}
