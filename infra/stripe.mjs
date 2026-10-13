// What Open Hearts has in Stripe: the one product and its yearly price,
// the customer portal, and the webhook to the service. apply.mjs makes
// the account match it and, by default, only says what it would change.
//
// The Stripe account is Open Hearts' own, so its default portal
// configuration is ours; even so,
// apply.mjs reads only the product holding the price's lookup key and
// the webhooks pointed at this app's hosts.
//
// Not here, because they are not readable or not settable through the
// API with the keys this uses: the restricted keys themselves (the
// service's OH_STRIPE_SECRET — Products, Subscriptions and Customers
// read; Checkout Sessions and Customer Portal write), the webhook's
// signing secret (shown once, at creation; it is the Pages project's
// OH_STRIPE_WEBHOOK_SECRET), Checkout's branding, receipt emails, the
// emails about upcoming renewals (on, 30 days before, with a link to
// the portal: the terms promise a reminder), the terms of service URL
// in Public details (Checkout's consent box will not open without
// it), and the account's name and statement descriptor.

export const stripe = {
  /// Which mode this describes. apply.mjs refuses a key of the other.
  mode: 'live',
  /// Hosts a webhook of ours points at; one elsewhere is not ours.
  hosts: ['openhearts.game', 'open-hearts.pages.dev'],

  /// $5.99 a year, paid up front (docs/explanation/service.md). Found by its
  /// lookup key, which is what the service is given
  /// (OH_STRIPE_PRICE): a new price takes the key over and nothing else
  /// changes. A price's amount cannot be edited, so a change to it here
  /// is a new price.
  price: {
    lookupKey: 'openhearts_annual',
    currency: 'usd',
    unitAmount: 599,
    interval: 'year',
    intervalCount: 1,
    taxBehavior: 'unspecified',
  },
  product: {
    name: 'Open Hearts Annual Subscription',
    description: 'All features including multi-player play, paid yearly.',
  },

  /// The default configuration, which is what the service's portal
  /// sessions open (it names none): cancel at the period's end with no
  /// refund of the rest, update the card and the customer's details,
  /// read invoices; no pausing, no switching plans.
  portal: {
    business_profile: {
      headline: null,
      privacy_policy_url: 'https://openhearts.game/privacy',
      terms_of_service_url: 'https://openhearts.game/terms',
    },
    default_return_url: null,
    features: {
      customer_update: { enabled: true, allowed_updates: ['address', 'email', 'name', 'phone'] },
      invoice_history: { enabled: true },
      payment_method_update: { enabled: true },
      subscription_cancel: {
        enabled: true,
        mode: 'at_period_end',
        proration_behavior: 'none',
        cancellation_reason: { enabled: true, options: ['other', 'switched_service', 'too_expensive', 'unused'] },
      },
      subscription_pause: { enabled: false },
      subscription_update: { enabled: false },
    },
    login_page: { enabled: false },
  },

  /// Entitlement (`/api/stripe`, service/functions/stripe.mjs). It reads
  /// checkout.session.completed and .async_payment_succeeded and the
  /// subscription's changes; the other checkout and subscription events
  /// are received, answered and ignored.
  webhooks: [
    {
      url: 'https://play.openhearts.game/api/stripe',
      // The shape the worker parses; Stripe sets it only when an
      // endpoint is made.
      apiVersion: '2025-11-17.clover',
      events: [
        'checkout.session.async_payment_failed',
        'checkout.session.async_payment_succeeded',
        'checkout.session.completed',
        'checkout.session.expired',
        'customer.subscription.created',
        'customer.subscription.deleted',
        'customer.subscription.paused',
        'customer.subscription.pending_update_applied',
        'customer.subscription.pending_update_expired',
        'customer.subscription.resumed',
        'customer.subscription.trial_will_end',
        'customer.subscription.updated',
      ],
    },
  ],
};
