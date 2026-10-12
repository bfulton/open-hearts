# Observability

Open Hearts' monitoring in New Relic, defined here and applied by script
rather than set up by hand.

- `monitoring.mjs`: what is watched and who is told: the ping monitors,
  the alert, and the **Open Hearts: web** browser app.
- `apply.mjs`: makes the account match the definition, and writes the
  browser app's loader to `app/web/observability.js`. It only reads
  unless given `--apply`.

To apply it, see
[Make Cloudflare, Stripe and New Relic match their definitions](../docs/how-to/apply-infrastructure.md).
What is watched, and why, is in
[the service](../docs/explanation/service.md#watching-it-run).
