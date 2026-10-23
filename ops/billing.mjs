// An account's subscription as the operator acts on it in Stripe: its
// renewal stopped while the account is suspended and started again
// when it is let back, and the subscription ended at once, with the
// unused part of its year refunded, when the account is terminated or a
// refund is asked for (the terms, "Refunds" and "Ending these terms").
//
// A web subscription only: Apple and Google bill, renew and refund what
// is bought in their stores, so for those the operator is told what to
// do by hand. Our marks ride on Stripe's own objects, in metadata, so
// that Stripe says what was done and by whom: `oh_stopped` on a
// subscription whose renewal a suspension stopped, `oh_act` on a refund.

/// The account's subscription and where it was bought: {id, source}, or
/// null when it has none.
export async function subscriptionOf(store, account) {
  const id = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  if (typeof id !== 'string' || !id) return null;
  const source = (await store.get(`SUB#${id}`, 'META'))?.source ?? (id.startsWith('sub_') ? 'stripe' : id.split(':')[0]);
  return { id, source };
}

/// How a web subscription stands in Stripe: {status, start, end (ms),
/// cancelAtPeriodEnd, stoppedBy (our mark, or null), payment (the
/// latest paid invoice's {intent, paid, currency}, or null), refunds
/// ([{amount, act}] made against that payment)}.
export async function inStripe(stripe, id) {
  const sub = await stripe.get(`/subscriptions/${encodeURIComponent(id)}`);
  const item = sub.items?.data?.[0];
  const invoice = typeof sub.latest_invoice === 'string' ? sub.latest_invoice : (sub.latest_invoice?.id ?? null);
  let payment = null;
  if (invoice) {
    const paid = await stripe.get(`/invoice_payments?invoice=${encodeURIComponent(invoice)}&status=paid&limit=10`);
    const found = (paid.data ?? []).find((p) => p.payment?.type === 'payment_intent' && typeof p.payment.payment_intent === 'string');
    if (found) payment = { intent: found.payment.payment_intent, paid: found.amount_paid, currency: found.currency };
  }
  const refunds = payment
    ? ((await stripe.get(`/refunds?payment_intent=${encodeURIComponent(payment.intent)}&limit=100`)).data ?? [])
        .filter((r) => r.status !== 'failed' && r.status !== 'canceled')
        .map((r) => ({ amount: r.amount, act: r.metadata?.oh_act ?? null }))
    : [];
  return {
    status: sub.status,
    start: item?.current_period_start ? item.current_period_start * 1000 : null,
    end: item?.current_period_end ? item.current_period_end * 1000 : null,
    cancelAtPeriodEnd: !!sub.cancel_at_period_end,
    stoppedBy: sub.metadata?.oh_stopped || null,
    payment,
    refunds,
  };
}

/// The unused part of [paid], in the currency's smallest unit, for what
/// is left of the period [start, end) at [now]: none before it starts to
/// matter, all of it before the period begins.
export function proRata(paid, start, end, now) {
  if (!(paid > 0) || !(end > start)) return 0;
  const left = Math.min(1, Math.max(0, (end - now) / (end - start)));
  return Math.floor(paid * left);
}

/// [cents] as money, for a line the operator reads.
export const money = (cents, currency) => `${(cents / 100).toFixed(2)} ${(currency ?? '').toUpperCase()}`.trim();

/// What is left to refund of the payment: what was paid less what has
/// been refunded already.
export const refundable = (stands) => Math.max(0, (stands.payment?.paid ?? 0) - stands.refunds.reduce((sum, r) => sum + r.amount, 0));

/// The refund [act] would make: [full] the rest of the payment, or else
/// the unused part of the year at [now], never more than is left, and
/// nothing if [act] has refunded this payment before.
export function refundFor(stands, act, { full = false, now }) {
  if (!stands.payment || stands.refunds.some((r) => r.act === act)) return 0;
  const want = full ? stands.payment.paid : proRata(stands.payment.paid, stands.start, stands.end, now);
  return Math.min(want, refundable(stands));
}

/// The subscription ended now, if it has not ended already: no renewal,
/// and the service told by Stripe's webhook, which cuts its devices'
/// licences to the day (service/functions/subscriptions.mjs).
export async function endNow(stripe, id, stands, comment) {
  if (stands.status === 'canceled' || stands.status === 'incomplete_expired') return false;
  await stripe.del(`/subscriptions/${encodeURIComponent(id)}`, { 'cancellation_details[comment]': comment });
  return true;
}

/// [amount] of the payment refunded, marked with the [act] that made it
/// and the [account] it was for.
export async function refund(stripe, stands, amount, act, account) {
  if (!(amount > 0)) return false;
  await stripe.post('/refunds', {
    payment_intent: stands.payment.intent,
    amount: String(amount),
    'metadata[oh_act]': act,
    'metadata[oh_account]': account,
  });
  return true;
}

/// The subscription's renewal stopped for a suspension, unless it is
/// already ending: it runs to the end of what was paid for, and our mark
/// says the suspension stopped it.
export async function stopRenewal(stripe, id, stands) {
  if (stands.status !== 'active' && stands.status !== 'trialing') return false;
  if (stands.cancelAtPeriodEnd) return false;
  await stripe.post(`/subscriptions/${encodeURIComponent(id)}`, { cancel_at_period_end: 'true', 'metadata[oh_stopped]': 'suspended' });
  return true;
}

/// The renewal a suspension stopped, started again; one the subscriber
/// cancelled stays cancelled.
export async function resumeRenewal(stripe, id, stands) {
  if (stands.stoppedBy !== 'suspended' || !stands.cancelAtPeriodEnd) return false;
  if (stands.status !== 'active' && stands.status !== 'trialing') return false;
  await stripe.post(`/subscriptions/${encodeURIComponent(id)}`, { cancel_at_period_end: 'false', 'metadata[oh_stopped]': '' });
  return true;
}

/// What the operator does by hand for a subscription bought in a store.
export function inTheStore(source) {
  return source === 'apple'
    ? 'bought in the App Store: we cannot cancel or refund it; the subscriber cancels in the App Store, and asks Apple for a refund (reportaproblem.apple.com)'
    : source === 'google'
      ? 'bought in Google Play: cancel and refund it in the Play Console (Order management), as the terms allow'
      : `bought in ${source}: nothing to do in Stripe`;
}
