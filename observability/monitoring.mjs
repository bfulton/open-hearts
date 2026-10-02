// What is watched, and who is told: Open Hearts' monitoring in New
// Relic, as a definition rather than as clicks (apply.mjs makes the
// account match it).
//
// The account may hold other apps, and on New Relic's free edition an
// organization has one account, so this app is kept apart within it:
// everything here is named with the app's prefix and tagged with its
// key, gathered in a workload of its own, and alerted on by a policy of
// its own. apply.mjs reads and writes only what carries the key, so
// another app's definition, applied to the same account, is left alone.

export const app = {
  key: 'open-hearts',
  name: 'Open Hearts',
};

/// From outside, once a minute, from two places: the cheapest kind of
/// check (a ping monitor, which New Relic does not count against its
/// synthetic checks), each with text the answer must carry, so a page
/// that answers 200 with the wrong thing still fails.
export const synthetics = {
  period: 'EVERY_MINUTE',
  locations: ['AWS_US_EAST_1', 'AWS_EU_WEST_1'],
  monitors: [
    // The marketing site.
    { name: 'Site', uri: 'https://openhearts.game/', expect: 'Open Hearts' },
    // The app's page; the app itself is a canvas a ping cannot see into.
    { name: 'App', uri: 'https://openhearts.game/play/', expect: 'Open Hearts' },
    // What a purchase needs: the store read, and Stripe answering the
    // service's key for the price (service/functions/worker.mjs, healthOf).
    { name: 'Service health', uri: 'https://openhearts.game/api/health', expect: '"ok":true' },
    // The presence relay's worker, which also wakes the jurors of last
    // resort (service/do/worker.mjs).
    { name: 'Relay', uri: 'https://relay.openhearts.game/', expect: 'open hearts relay' },
  ],
};

/// Down is a monitor failing from both places for two minutes running:
/// one place's network having a bad minute is not an outage.
export const alerts = {
  policy: 'availability',
  failingFrom: 2,
  forSeconds: 120,
  /// Who is told, by email. From the environment when applied
  /// (OH_ALERT_EMAIL), not from here: this repository is public.
  emailFrom: 'OH_ALERT_EMAIL',
};
