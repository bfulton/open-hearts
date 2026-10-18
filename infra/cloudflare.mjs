// What Open Hearts has in Cloudflare, as a definition rather than as
// clicks (apply.mjs makes the account match it, and by default only
// says what it would change).
//
// The account may hold other apps, so this keeps to its own:
// the two zones below, the Pages project, the KV namespaces, the R2
// bucket, the relay worker and the account-level things named for this
// app. Nothing else in the account is read for changes, let alone
// touched.
//
// No secret is here, nor anywhere in this directory: a secret is named,
// and apply.mjs checks it is set, never what it is. Addresses mail is
// forwarded to come from the environment, as observability's do: this
// repository is public.

import { readFileSync } from 'node:fs';

const config = JSON.parse(readFileSync(new URL('../config/openhearts.json', import.meta.url), 'utf8'));

/// Google Play's purchases are checked with a service account's key
/// (playToken in service/functions/stores.mjs), which the worker wants
/// once the config names Play's package and product, as here.
export const playSecrets = config.google?.package && config.google?.product ? ['OH_PLAY_SERVICE_ACCOUNT'] : [];

export const app = {
  key: 'open-hearts',
  name: 'Open Hearts',
};

// ---- the site, the app and /api: one Pages project ---------------------

/// Published by deploy.sh (wrangler pages deploy); what is set here is
/// the project around the uploads. The worker the uploads carry
/// (_worker.js, service/functions) reads what the environments bind.
export const pages = {
  project: 'open-hearts',
  productionBranch: 'main',
  /// Besides open-hearts.pages.dev, which every project has. The site
  /// at the apex, the app at play (one deployment: the worker routes by
  /// host, docs/explanation/service.md). Each needs its CNAME to the project in
  /// its zone's dns, below; diff.test.mjs holds the two together.
  domains: ['openhearts.game', 'play.openhearts.game'],
  /// Cloudflare Web Analytics, which injects a beacon script into every
  /// page, is off: the site promises no third-party scripts.
  webAnalytics: false,
  environments: {
    production: {
      compatibilityDate: '2026-09-09',
      compatibilityFlags: [],
      /// None: what is not secret is in config/openhearts.json, which
      /// the deploy ships with the worker (docs/explanation/service.md).
      vars: {},
      /// Encrypted: names only. apply.mjs checks each is set, and cannot
      /// set one (it has no value to set), so a missing one is set by
      /// hand: `./oh secret set NAME --apply`.
      secrets: ['OH_ID_HMAC', 'OH_SERVICE_SECRET', 'OH_STRIPE_SECRET', 'OH_STRIPE_WEBHOOK_SECRET', 'OH_TURN_API_TOKEN', ...playSecrets],
      kv: { OH_STORE: 'open-hearts-store' },
      r2: { OH_RECORDS: 'open-hearts-records' },
      /// The household object lives in the relay worker (wrangler.toml).
      durableObjects: { HOUSEHOLD: { script: 'open-hearts-relay', class: 'Household' } },
      /// Counts and nothing about anybody (docs/explanation/service.md).
      analyticsEngine: { OH_METRICS: 'open_hearts_api' },
    },
    preview: {
      compatibilityDate: '2026-09-09',
      compatibilityFlags: [],
      vars: {},
      // No Stripe on preview: the shop says it is not open yet.
      secrets: ['OH_ID_HMAC', 'OH_SERVICE_SECRET', 'OH_TURN_API_TOKEN'],
      // Its own store, so a preview never writes production's rows; and
      // no HOUSEHOLD, whose object reads production's store. Its own
      // bucket too: a game played on a preview is no game of record.
      kv: { OH_STORE: 'open-hearts-store-preview' },
      r2: { OH_RECORDS: 'open-hearts-records-preview' },
      durableObjects: {},
      analyticsEngine: {},
    },
  },
};

/// KV namespaces, by title.
export const kv = ['open-hearts-store', 'open-hearts-store-preview'];

/// R2 buckets. The game records are private: no r2.dev address, no
/// custom domain, no CORS, so the worker is the only way in. The
/// pictures subscribers put out at live tables, kept for the operator
/// to look at (service/do/review.mjs), are served at their own domain
/// through Cloudflare's cache, where the CSAM Scanning Tool checks
/// them; each is named by its SHA-256, so nobody finds one without the
/// picture or the operator's email.
export const r2 = [
  {
    name: 'open-hearts-pictures',
    location: 'ENAM',
    storageClass: 'Standard',
    publicDevUrl: false,
    customDomains: ['pictures.openhearts.game'],
  },
  {
    name: 'open-hearts-records',
    location: 'ENAM',
    storageClass: 'Standard',
    publicDevUrl: false,
    customDomains: [],
  },
  {
    name: 'open-hearts-records-preview',
    location: 'ENAM',
    storageClass: 'Standard',
    publicDevUrl: false,
    customDomains: [],
  },
];

/// The Realtime TURN key the worker mints credentials with: the one the
/// config names (turnKeyId), which the worker is deployed with too. Made
/// once; its secret is the project's OH_TURN_API_TOKEN, shown only at
/// creation.
export const turnKeys = [{ name: 'open-hearts-turn', uid: config.turnKeyId }];

// ---- the relay worker ---------------------------------------------------

/// Deployed by wrangler from service/do/wrangler.toml, which is the
/// definition of its code, bindings, migrations, container and vars;
/// nothing of that is repeated here. apply.mjs reads wrangler.toml and
/// checks the live worker against it, and against the little the
/// account adds: its secrets by name, and that it is reached only by
/// its custom domain. A difference is fixed by deploying with wrangler,
/// not by this script.
export const relay = {
  wrangler: 'service/do/wrangler.toml',
  secrets: ['OH_JUROR_SECRET'],
  /// workers.dev off: relay.openhearts.game is its only address.
  workersDev: false,
};

// ---- the zones ------------------------------------------------------------

/// Settings pinned to what they are, so a change to them shows here.
/// Where they differ from Cloudflare's defaults: plain HTTP is sent to
/// HTTPS and nothing older than TLS 1.2 is spoken; a browser keeps a
/// file only as long as the file's own Cache-Control says
/// (browser_cache_ttl 0), so the app's unhashed files are checked on
/// every load rather than kept for Cloudflare's four hours
/// (site/public/_headers); and email_obfuscation is off (it rewrites
/// help@ on the site's pages and injects a script to put it back,
/// docs/explanation/service.md). SSL's mode is left to automatic mode (it chose
/// Full), so `ssl` itself is not pinned.
const tls = {
  ssl_automatic_mode: 'auto',
  always_use_https: 'on',
  min_tls_version: '1.2',
  tls_1_3: 'on',
  browser_cache_ttl: 0,
};

/// Cloudflare-made records (Email Routing's, Email Sending's, a worker's
/// custom domain) are read-only through the DNS API: they are listed to
/// be checked for, by type and name, and made by turning the feature on.
export const zones = {
  'openhearts.game': {
    settings: { ...tls, email_obfuscation: 'off' },
    botFightMode: false,
    dns: [
      { type: 'CNAME', name: 'openhearts.game', content: 'open-hearts.pages.dev', proxied: true, comment: 'Pages: site, /api' },
      { type: 'CNAME', name: 'play.openhearts.game', content: 'open-hearts.pages.dev', proxied: true, comment: 'Pages: the app, /api' },
      { type: 'CNAME', name: 'www.openhearts.game', content: 'openhearts.game', proxied: true, comment: 'redirects to the apex' },
      // Mail from the zone is Cloudflare's (Email Routing in, Email
      // Sending out), and nothing else may send as it.
      { type: 'TXT', name: 'openhearts.game', content: '"v=spf1 include:_spf.mx.cloudflare.net ~all"' },
      { type: 'TXT', name: '_dmarc.openhearts.game', content: '"v=DMARC1; p=reject;"' },
    ],
    cloudflareDns: [
      { type: 'MX', name: 'openhearts.game', by: 'Email Routing', count: 3 },
      { type: 'TXT', name: 'cf2024-1._domainkey.openhearts.game', by: 'Email Routing' },
      { type: 'MX', name: 'cf-bounce.openhearts.game', by: 'Email Sending', count: 3 },
      { type: 'TXT', name: 'cf-bounce.openhearts.game', by: 'Email Sending' },
      { type: 'TXT', name: 'cf-bounce._domainkey.openhearts.game', by: 'Email Sending' },
      { type: 'AAAA', name: 'relay.openhearts.game', by: 'the relay worker\'s custom domain' },
    ],
    rules: {
      http_request_dynamic_redirect: [
        {
          description: 'www to the apex',
          expression: 'http.host eq "www.openhearts.game"',
          action: 'redirect',
          action_parameters: {
            from_value: {
              preserve_query_string: true,
              status_code: 301,
              target_url: { expression: 'concat("https://openhearts.game", http.request.uri.path)' },
            },
          },
          enabled: true,
        },
      ],
      // The one rate-limit rule the Free plan allows.
      // The webhooks are left out — Stripe's, the stores' and Sign in
      // with Apple's: their retries come in bursts from few addresses.
      http_ratelimit: [
        {
          description: 'API and relay: 30 requests per 10 s per address',
          expression:
            '(http.host eq "play.openhearts.game" and starts_with(http.request.uri.path, "/api/") and not http.request.uri.path in {"/api/stripe" "/api/apple" "/api/apple-id" "/api/play"}) or http.host eq "relay.openhearts.game"',
          action: 'block',
          ratelimit: { characteristics: ['cf.colo.id', 'ip.src'], period: 10, requests_per_period: 30, mitigation_timeout: 10 },
          enabled: true,
        },
      ],
    },
    /// help@ forwards to the operator. Where to is OH_HELP_FORWARD, when set,
    /// and otherwise only checked to be a verified destination. alerts@,
    /// the service's own word to the operator (service/functions/alerts.mjs),
    /// goes to the same place: help@'s, when OH_HELP_FORWARD is unset.
    emailRouting: {
      enabled: true,
      forwards: [
        { to: 'help@openhearts.game', destinationFrom: 'OH_HELP_FORWARD' },
        { to: 'alerts@openhearts.game', destinationFrom: 'OH_HELP_FORWARD', sameAs: 'help@openhearts.game' },
      ],
      catchAll: false,
    },
    /// Email Sending (the relay's send_email binding, EMAIL): the zone
    /// onboarded, mail from the apex with bounces to cf-bounce.
    emailSending: { enabled: true, subdomains: [{ name: 'openhearts.game', returnPath: 'cf-bounce.openhearts.game' }] },
    logpush: false,
  },
  // A second name, wholly redirected: every host and path to the same
  // path on openhearts.game, query kept. The AAAA 100:: records are the
  // placeholder a proxied name answers on with no origin behind it.
  'openhearts.lol': {
    settings: {},
    botFightMode: false,
    dns: [
      { type: 'AAAA', name: 'openhearts.lol', content: '100::', proxied: true, comment: 'redirects to openhearts.game' },
      { type: 'AAAA', name: 'www.openhearts.lol', content: '100::', proxied: true, comment: 'redirects to openhearts.game' },
    ],
    cloudflareDns: [],
    rules: {
      http_request_dynamic_redirect: [
        {
          description: 'everything to openhearts.game',
          expression: 'true',
          action: 'redirect',
          action_parameters: {
            from_value: {
              preserve_query_string: true,
              status_code: 301,
              target_url: { expression: 'concat("https://openhearts.game", http.request.uri.path)' },
            },
          },
          enabled: true,
        },
      ],
    },
    emailRouting: { enabled: false },
    emailSending: { enabled: false },
    logpush: false,
  },
};

// ---- the account --------------------------------------------------------

/// Spend alerts, since Cloudflare has no hard cap. Ours are the ones with
/// this description; who is told is OH_ALERT_EMAIL (as observability's).
export const budgetAlerts = {
  description: 'Cloudflare usage charges for the billing period (Open Hearts).',
  dollars: [10, 20, 50, 100, 200],
  name: (dollars) => `Spend reached $${dollars} this month`,
  emailFrom: 'OH_ALERT_EMAIL',
};
