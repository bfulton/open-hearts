# Infrastructure

What Open Hearts has in Cloudflare and Stripe, defined here and checked
(and, when asked, applied) by script rather than kept in someone's head.

- `cloudflare.mjs`: the Pages project, its domains, plain variables,
  secrets' names and bindings; the KV namespaces, R2 buckets and TURN
  key; the zones' DNS records, settings and rules; Email Routing and
  Email Sending; and the account's spend alerts.
- `stripe.mjs`: the yearly price and its product, the customer portal,
  and the webhook to `/api/stripe` with the events it is sent.
- `apply.mjs`: makes the accounts match the definitions. It only reads
  unless given `--apply`.
- `diff.mjs`: the comparisons, as pure functions, tested by
  `diff.test.mjs` with no network and no keys.

To check or apply them, see
[Make Cloudflare, Stripe and New Relic match their definitions](../docs/how-to/apply-infrastructure.md).
What each secret, binding and variable does is in the
[configuration reference](../docs/reference/configuration.md), and why
some things are left to be done by hand is in
[the service](../docs/explanation/service.md#what-is-defined-in-code).
