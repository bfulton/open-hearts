// Stripe's prices as a checkout asks for them (stripe.mjs, shopPrice):
// a fake that answers for a price, and hands every other call to the
// fake it wraps.

/// The price the terms state in these tests, as the service reads it
/// (OH_PRICE, deployment.mjs).
export const STATED = '599 usd';

/// A price as Stripe has it: a year at the stated price, unless [more]
/// says otherwise.
export const stripePrice = (more = {}) => ({
  id: 'price_1',
  object: 'price',
  active: true,
  unit_amount: 599,
  currency: 'usd',
  recurring: { interval: 'year', interval_count: 1 },
  ...more,
});

/// [fake], but asked for a price — by its id, or for the one holding a
/// lookup key — [price] answers; null is no such price.
export function withPrice(fake, price = stripePrice()) {
  return async (url, init) => {
    const at = String(url);
    if (at.startsWith('https://api.stripe.com/v1/prices/')) {
      return price ? Response.json(price) : Response.json({ error: { code: 'resource_missing' } }, { status: 404 });
    }
    if (at.startsWith('https://api.stripe.com/v1/prices?')) return Response.json({ data: price ? [price] : [] });
    return fake(url, init);
  };
}
