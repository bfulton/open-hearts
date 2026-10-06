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
  /// Besides open-hearts.pages.dev, which every project has.
  domains: ['openhearts.game'],
  /// Cloudflare Web Analytics, which injects a beacon script into every
  /// page, is off: the site promises no third-party scripts.
  webAnalytics: false,
  environments: {
    production: {
      compatibilityDate: '2026-09-09',
      compatibilityFlags: [],
      /// None: what is not secret is in config/openhearts.json, which
      /// the deploy ships with the worker (docs/06-service.md).
      vars: {},
      /// Encrypted: names only. apply.mjs checks each is set, and cannot
      /// set one (it has no value to set), so a missing one is set by
      /// hand: `npx wrangler pages secret put NAME --project-name open-hearts`.
      secrets: ['OH_ID_HMAC', 'OH_SERVICE_SECRET', 'OH_STRIPE_SECRET', 'OH_STRIPE_WEBHOOK_SECRET', 'OH_TURN_API_TOKEN'],
      kv: { OH_STORE: 'open-hearts-store' },
      r2: { OH_RECORDS: 'open-hearts-records' },
      /// The household object lives in the relay worker (wrangler.toml).
      durableObjects: { HOUSEHOLD: { script: 'open-hearts-relay', class: 'Household' } },
      /// None: OH_METRICS, when bound, is open_hearts_api
      /// (docs/06-service.md).
      analyticsEngine: {},
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

/// R2 buckets: game records, private. No r2.dev address, no custom
/// domain, no CORS: the worker is the only way in.
export const r2 = [
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

/// The Realtime TURN key the worker mints credentials with. Made once;
/// its secret is the project's OH_TURN_API_TOKEN, shown only at creation.
export const turnKeys = [{ name: 'open-hearts-turn', uid: 'd681af4e315018c9dc90b898de5f24be' }];

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

/// Settings pinned to what they are. Only email_obfuscation differs from
/// Cloudflare's default (off: it rewrites help@ on the site's pages and
/// injects a script to put it back, docs/06-service.md); the rest are
/// Cloudflare's defaults, pinned so a change to them shows here. SSL's
/// mode is left to automatic mode (it chose Full), so `ssl` itself is
/// not pinned.
const tls = {
  ssl_automatic_mode: 'auto',
  always_use_https: 'off',
  min_tls_version: '1.0',
  tls_1_3: 'on',
};

/// Cloudflare-made records (Email Routing's, Email Sending's, a worker's
/// custom domain) are read-only through the DNS API: they are listed to
/// be checked for, by type and name, and made by turning the feature on.
export const zones = {
  'openhearts.game': {
    settings: { ...tls, email_obfuscation: 'off' },
    botFightMode: false,
    dns: [
      { type: 'CNAME', name: 'openhearts.game', content: 'open-hearts.pages.dev', proxied: true, comment: 'Pages: site, app, /api' },
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
      // Stores' and Stripe's webhooks are left out: their retries come in
      // bursts from few addresses.
      http_ratelimit: [
        {
          description: 'API and relay: 30 requests per 10 s per address',
          expression:
            '(http.host eq "openhearts.game" and starts_with(http.request.uri.path, "/api/") and not http.request.uri.path in {"/api/stripe" "/api/apple" "/api/play"}) or http.host eq "relay.openhearts.game"',
          action: 'block',
          ratelimit: { characteristics: ['cf.colo.id', 'ip.src'], period: 10, requests_per_period: 30, mitigation_timeout: 10 },
          enabled: true,
        },
      ],
    },
    /// help@ forwards to the operator. Where to is OH_HELP_FORWARD, when set,
    /// and otherwise only checked to be a verified destination.
    emailRouting: {
      enabled: true,
      forwards: [{ to: 'help@openhearts.game', destinationFrom: 'OH_HELP_FORWARD' }],
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
