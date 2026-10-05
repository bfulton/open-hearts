# Infrastructure

What Open Hearts has in Cloudflare and Stripe, defined here and checked
(and, when asked, applied) by script rather than kept in someone's head.

- `cloudflare.mjs` — the Pages project `open-hearts` (production branch,
  the openhearts.game domain, each environment's plain variables, the
  names of its secrets, and its bindings: KV `OH_STORE`, R2
  `OH_RECORDS`, the relay's `HOUSEHOLD` object on production only; no
  Web Analytics); the KV namespaces and the R2 buckets, production's and
  preview's own (no r2.dev address, no custom domain, no CORS); the
  Realtime TURN key; the zones
  openhearts.game and openhearts.lol — their DNS records, the settings
  pinned (email obfuscation off, on purpose), Bot Fight Mode off, the
  redirect and rate-limit rules, Email Routing (help@ forwarded, no
  catch-all), Email Sending, no Logpush; Web Analytics off on both; the
  account's spend alerts.
- `stripe.mjs` — the yearly price (lookup key `openhearts_annual`,
  $5.99) and its product, the default customer portal configuration,
  and the webhook to `/api/stripe` with the events it is sent.
- `apply.mjs` — makes the accounts match. A dry run by default:

      node infra/apply.mjs                     # what would change
      node infra/apply.mjs --apply             # change it
      node infra/apply.mjs --only stripe       # one account (or cloudflare)

  Needs `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, and
  `STRIPE_API_KEY`; a dry run reads and nothing else. Two addresses
  are not in this public repository but in the environment, as
  observability's is: `OH_HELP_FORWARD`, where help@openhearts.game
  forwards, and `OH_ALERT_EMAIL`, who the spend alerts email. Unset,
  each is checked to exist and not compared; to create either, set it.
  If Node cannot verify TLS through a proxy, point
  `NODE_EXTRA_CA_CERTS` at the proxy's CA bundle — never turn checking
  off.
- `diff.mjs` — the comparisons, as pure functions, and `diff.test.mjs`,
  their tests: `node --test infra/*.test.mjs` (no network, no keys).

Each line it prints is one of four kinds: `would …`, a change `--apply`
makes; `by hand:`, a difference that has to be fixed by hand (below);
`unread:`, something the credentials could not read, in the API's own
words; `ok`, a part that matches. No secret is ever printed, nor an
address: the variables holding them are named instead. The Stripe part
says whether the key is live or test, and refuses to compare a key of
the other mode than `stripe.mjs` describes (live).

The Cloudflare account holds other apps, so this keeps to its own: the
two zones (wholly this app's, so a DNS record or rule in them that is
not defined is deleted), the project, the namespaces, bucket and key
named here, Web Analytics sites on our zones, spend alerts with our
description. Stripe's account is Open Hearts' own; even so only the
product holding the lookup key and the webhooks pointed at our hosts
are read.

## What it does not manage, and why

- **The relay worker's own definition.** `open-hearts-relay` — its
  code, bindings, Durable Object migrations, the bench's container, its
  vars and custom domain — is `service/do/wrangler.toml`, deployed with
  `npx wrangler@4 deploy`. `apply.mjs` reads that file and checks the
  live worker against it (compatibility date, observability, every
  binding and var, the custom domain `relay.openhearts.game` and no
  other, workers.dev off, a namespace per migrated class, the
  container's instances) and that its secret `OH_JUROR_SECRET` is set.
  A difference is `by hand:` — deploy — never changed from here.
- **Secret values.** Pages secrets (`OH_ID_HMAC`, `OH_SERVICE_SECRET`,
  `OH_STRIPE_SECRET`, `OH_STRIPE_WEBHOOK_SECRET`, `OH_TURN_API_TOKEN`)
  and the relay's are checked present by name. One missing is
  `by hand:` with the `wrangler … secret put` that sets it.
- **What Cloudflare makes for a feature.** Email Routing's MX, SPF and
  DKIM records, Email Sending's `cf-bounce` records and the relay's
  custom-domain record are read-only through the DNS API; they are
  checked for, and put back by turning the feature on again.
- **Email Sending's onboarding**, which the API reads but does not
  offer to set: checked, `by hand:` in the dashboard if it differs.
- **A Stripe webhook's creation and API version.** Its signing secret
  is shown once, at creation, and belongs in the Pages project as
  `OH_STRIPE_WEBHOOK_SECRET`; a script holding it is a script that can
  leak it. The events and enabled state of the existing endpoint are
  managed; a new endpoint (or a new API version, which Stripe sets only
  at creation) is `by hand:`.
- **The restricted keys.** Stripe does not list restricted keys through
  the API, nor Cloudflare a token's own permissions in a form worth
  pinning. The service's key (`OH_STRIPE_SECRET`: Products,
  Subscriptions and Customers read; Checkout Sessions and Customer
  Portal write) is checked only as a secret set on the project.
- **Stripe account settings**: Checkout's branding, receipt emails, the
  account's name and statement descriptor — dashboard settings the
  service's keys cannot write.
- **Page Rules.** An account-owned API token cannot read them
  (Cloudflare error 1011), so they are reported unread, as a note;
  none are used — the redirects are rules.
- **Deployments.** `deploy.sh` publishes the site and the app, and
  `deploy.sh --prune` sweeps old previews.
- **The account's plan and billing** (Workers Paid), the zones'
  registration, and New Relic, which is `observability/`.
