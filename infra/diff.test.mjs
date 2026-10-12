// What apply.mjs compares, in node's own test runner: node --test infra/
// Pure functions over answers shaped as Cloudflare's and Stripe's are
// (taken from the live accounts, ids kept, nothing secret in them).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

import { pages, playSecrets, relay, zones } from './cloudflare.mjs';
import {
  budgetPlan,
  describe,
  dnsPlan,
  drift,
  emailRoutingPlan,
  form,
  formBody,
  keyMode,
  madeByCloudflare,
  zoneOf,
  pagesDomainProblems,
  pagesDomainsPlan,
  pagesEnvPlan,
  parseToml,
  portalPlan,
  pricePlan,
  relayProblems,
  rulesPlan,
  settingsPlan,
  webhookPlan,
  wranglerBindings,
} from './diff.mjs';
import { stripe } from './stripe.mjs';

const clone = (x) => structuredClone(x);

// ---- drift ------------------------------------------------------------------

test('drift looks only at what the definition names', () => {
  assert.deepEqual(drift({ a: 1 }, { a: 1, b: 2, id: 'x' }), []);
  assert.deepEqual(drift({ a: { b: 1 } }, { a: { b: 2 } }), [{ path: 'a.b', want: 1, have: 2 }]);
  assert.deepEqual(drift({ a: 1 }, {}), [{ path: 'a', want: 1, have: undefined }]);
});

test('drift takes null and absent as the same', () => {
  assert.deepEqual(drift({ a: null }, {}), []);
  assert.deepEqual(drift({ a: null }, { a: null }), []);
});

test('drift compares lists of values as sets, lists of objects in order', () => {
  assert.deepEqual(drift(['b', 'a'], ['a', 'b']), []);
  assert.equal(drift(['a', 'b'], ['a']).length, 1);
  assert.equal(drift(['a', 'a'], ['a', 'b']).length, 1);
  assert.deepEqual(drift([{ x: 1 }, { x: 2 }], [{ x: 1 }, { x: 2 }]), []);
  assert.deepEqual(drift([{ x: 1 }, { x: 2 }], [{ x: 2 }, { x: 1 }]).map((d) => d.path), ['[0].x', '[1].x']);
});

test('describe says what is and what is wanted', () => {
  assert.equal(describe({ path: 'a.b', want: 'on', have: 'off' }), 'a.b: "off" -> "on"');
  assert.equal(describe({ path: 'a', want: 1, have: undefined }), 'a: absent -> 1');
});

// ---- DNS ------------------------------------------------------------------

const game = zones['openhearts.game'];
const liveRecords = () => [
  { id: 'r1', type: 'CNAME', name: 'openhearts.game', content: 'open-hearts.pages.dev', proxied: true, ttl: 1, comment: 'Pages: site, /api', meta: {} },
  { id: 'r2', type: 'CNAME', name: 'www.openhearts.game', content: 'openhearts.game', proxied: true, ttl: 1, comment: 'redirects to the apex', meta: {} },
  { id: 'r3', type: 'TXT', name: 'openhearts.game', content: '"v=spf1 include:_spf.mx.cloudflare.net ~all"', proxied: false, ttl: 1, comment: null, meta: {} },
  { id: 'r4', type: 'TXT', name: '_dmarc.openhearts.game', content: '"v=DMARC1; p=reject;"', proxied: false, ttl: 1, comment: null, meta: {} },
  { id: 'r5', type: 'CNAME', name: 'play.openhearts.game', content: 'open-hearts.pages.dev', proxied: true, ttl: 1, comment: 'Pages: the app, /api', meta: {} },
  ...[78, 67, 82].map((priority, i) => ({ id: `mx${i}`, type: 'MX', name: 'openhearts.game', content: `route${i + 1}.mx.cloudflare.net`, priority, meta: { email_routing: true, read_only: true } })),
  ...[78, 67, 82].map((priority, i) => ({ id: `bx${i}`, type: 'MX', name: 'cf-bounce.openhearts.game', content: `route${i + 1}.mx.cloudflare.net`, priority, meta: { email_routing: true, read_only: true } })),
  { id: 'k1', type: 'TXT', name: 'cf2024-1._domainkey.openhearts.game', content: '"v=DKIM1; …"', meta: { email_routing: true, read_only: true } },
  { id: 'k2', type: 'TXT', name: 'cf-bounce._domainkey.openhearts.game', content: '"v=DKIM1; …"', meta: { email_routing: true, read_only: true } },
  { id: 'k3', type: 'TXT', name: 'cf-bounce.openhearts.game', content: '"v=spf1 include:_spf.mx.cloudflare.net ~all"', meta: { email_routing: true, read_only: true } },
  { id: 'w1', type: 'AAAA', name: 'relay.openhearts.game', content: '100::', proxied: true, meta: { origin_worker_id: 'a9c2', read_only: true } },
];

test('DNS: the zone as it is matches its definition', () => {
  assert.deepEqual(dnsPlan(game, liveRecords()), { create: [], update: [], remove: [], missing: [] });
});

test("DNS: Cloudflare's own records are never ours to change", () => {
  assert.equal(madeByCloudflare({ meta: { read_only: true } }), true);
  assert.equal(madeByCloudflare({ meta: { origin_worker_id: 'x' } }), true);
  assert.equal(madeByCloudflare({ meta: {} }), false);
  const plan = dnsPlan({ dns: [], cloudflareDns: [] }, liveRecords().filter(madeByCloudflare));
  assert.deepEqual(plan.remove, []);
});

test('DNS: a missing record is created, a changed one updated, a stray one deleted', () => {
  const have = liveRecords().filter((r) => r.id !== 'r4');
  have[1].proxied = false;
  have.push({ id: 'x1', type: 'A', name: 'old.openhearts.game', content: '192.0.2.1', proxied: false, ttl: 1, meta: {} });
  const plan = dnsPlan(game, have);
  assert.deepEqual(plan.create.map((r) => r.name), ['_dmarc.openhearts.game']);
  assert.deepEqual(plan.update.map((u) => [u.id, u.diffs.map(describe)]), [['r2', ['proxied: false -> true']]]);
  assert.deepEqual(plan.remove.map((r) => r.id), ['x1']);
  assert.deepEqual(plan.missing, []);
});

test('DNS: a record whose content changed is updated in place, not made twice', () => {
  const have = liveRecords();
  have[3].content = '"v=DMARC1; p=none;"';
  const plan = dnsPlan(game, have);
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.remove, []);
  assert.equal(plan.update[0].id, 'r4');
});

test("DNS: the app's host, play, is made where it is missing", () => {
  // As it was before the app moved: the apex's record only, and its
  // comment from when the apex served the app.
  const have = liveRecords().filter((r) => r.id !== 'r5');
  have[0].comment = 'Pages: site, app, /api';
  const plan = dnsPlan(game, have);
  assert.deepEqual(plan.create, [
    { type: 'CNAME', name: 'play.openhearts.game', content: 'open-hearts.pages.dev', proxied: true, ttl: 1, comment: 'Pages: the app, /api' },
  ]);
  assert.deepEqual(plan.update.map((u) => [u.id, u.diffs.map(describe)]), [['r1', ['comment: "Pages: site, app, /api" -> "Pages: site, /api"']]]);
  assert.deepEqual(plan.remove, []);
});

test("DNS: one of Cloudflare's records missing is put back by hand", () => {
  const have = liveRecords().filter((r) => r.id !== 'mx1' && r.id !== 'w1');
  const plan = dnsPlan(game, have);
  assert.deepEqual(plan.missing.map((m) => `${m.type} ${m.name}`), ['MX openhearts.game', 'AAAA relay.openhearts.game']);
});

// ---- settings and rules --------------------------------------------------------

test('settings: only those that differ', () => {
  const have = { ...game.settings, email_obfuscation: 'on' };
  assert.deepEqual(settingsPlan(game.settings, have), [{ id: 'email_obfuscation', want: 'off', have: 'on' }]);
  assert.deepEqual(settingsPlan(game.settings, { ...game.settings }), []);
});

const liveRules = () => ({
  http_request_dynamic_redirect: game.rules.http_request_dynamic_redirect.map((r) => ({ ...clone(r), id: 'a', ref: 'a', version: '1', last_updated: 'then' })),
  http_ratelimit: game.rules.http_ratelimit.map((r) => ({
    ...clone(r),
    id: 'b',
    version: '1',
    // As the API answers it: its own order.
    ratelimit: { characteristics: ['cf.colo.id', 'ip.src'], mitigation_timeout: 10, period: 10, requests_per_period: 30 },
  })),
});

test('rules: as they are, nothing to do', () => {
  assert.deepEqual(rulesPlan(game.rules, liveRules()), []);
});

test('rules: a changed rule replaces its phase', () => {
  const have = liveRules();
  have.http_ratelimit[0].ratelimit.period = 60;
  const plan = rulesPlan(game.rules, have);
  assert.equal(plan.length, 1);
  assert.equal(plan[0].phase, 'http_ratelimit');
  assert.deepEqual(plan[0].diffs.map(describe), ['[0].ratelimit.period: 60 -> 10']);
});

test('rules: a phase missing is made, one undefined is emptied, an extra rule goes', () => {
  const have = liveRules();
  delete have.http_ratelimit;
  have.http_request_firewall_custom = [{ description: 'stray', expression: 'true', action: 'block', enabled: true }];
  have.http_request_dynamic_redirect.push({ description: 'another', expression: 'true', action: 'redirect', enabled: true });
  const plan = Object.fromEntries(rulesPlan(game.rules, have).map((p) => [p.phase, p]));
  assert.deepEqual(Object.keys(plan).sort(), ['http_ratelimit', 'http_request_dynamic_redirect', 'http_request_firewall_custom']);
  assert.equal(plan.http_ratelimit.rules.length, 1);
  assert.deepEqual(plan.http_request_firewall_custom.rules, []);
  assert.equal(plan.http_request_dynamic_redirect.rules.length, 1);
});

test('rules: a field on the live rule the definition does not set is a difference', () => {
  const have = liveRules();
  have.http_request_dynamic_redirect[0].ratelimit = { period: 10 };
  assert.equal(rulesPlan(game.rules, have).length, 1);
});

// ---- Pages ------------------------------------------------------------------

const ids = {
  kv: { 'open-hearts-store': '5b65', 'open-hearts-store-preview': 'ab41' },
  durableObjects: { 'open-hearts-relay/Household': 'fcae' },
};
const secret = { type: 'secret_text', value: '' };
const plain = (value) => ({ type: 'plain_text', value });
const liveProduction = () => ({
  env_vars: {
    OH_ID_HMAC: secret,
    OH_SERVICE_SECRET: secret,
    OH_STRIPE_SECRET: secret,
    OH_STRIPE_WEBHOOK_SECRET: secret,
    OH_TURN_API_TOKEN: secret,
    ...Object.fromEntries(playSecrets.map((name) => [name, secret])),
  },
  kv_namespaces: { OH_STORE: { namespace_id: '5b65' } },
  durable_object_namespaces: { HOUSEHOLD: { namespace_id: 'fcae' } },
  r2_buckets: { OH_RECORDS: { name: 'open-hearts-records' } },
  analytics_engine_datasets: { OH_METRICS: { dataset: 'open_hearts_api' } },
  compatibility_date: '2026-09-09',
  compatibility_flags: [],
});

test('Pages: production as it is matches', () => {
  assert.deepEqual(pagesEnvPlan(pages.environments.production, liveProduction(), ids), { patch: {}, lines: [], owner: [] });
});

test('Pages: preview has its own store and no household', () => {
  const have = liveProduction();
  for (const k of ['OH_STRIPE_SECRET', 'OH_STRIPE_WEBHOOK_SECRET', ...playSecrets]) delete have.env_vars[k];
  have.kv_namespaces.OH_STORE.namespace_id = 'ab41';
  have.r2_buckets.OH_RECORDS.name = 'open-hearts-records-preview';
  delete have.durable_object_namespaces;
  delete have.analytics_engine_datasets;
  assert.deepEqual(pagesEnvPlan(pages.environments.preview, have, ids), { patch: {}, lines: [], owner: [] });
  // And production's store on preview is a rebinding.
  have.kv_namespaces.OH_STORE.namespace_id = '5b65';
  assert.deepEqual(pagesEnvPlan(pages.environments.preview, have, ids).patch, { kv_namespaces: { OH_STORE: { namespace_id: 'ab41' } } });
  // As is production's bucket: a game played on a preview is no game of record.
  have.kv_namespaces.OH_STORE.namespace_id = 'ab41';
  have.r2_buckets.OH_RECORDS.name = 'open-hearts-records';
  assert.deepEqual(pagesEnvPlan(pages.environments.preview, have, ids).lines, ['rebind OH_RECORDS (r2_buckets) to open-hearts-records-preview']);
});

// The project holds no plain variables today (config/openhearts.json);
// the planning for one is still checked, against a definition that has one.
const withVar = { ...pages.environments.production, vars: { OH_STRIPE_PRICE: 'openhearts_annual' } };

test('Pages: a plain variable is set, a stray one removed', () => {
  const have = liveProduction();
  have.env_vars.OH_STRIPE_PRICE = plain('price_old');
  have.env_vars.OH_DEBUG = plain('1');
  const plan = pagesEnvPlan(withVar, have, ids);
  assert.deepEqual(plan.patch.env_vars, { OH_STRIPE_PRICE: plain('openhearts_annual'), OH_DEBUG: null });
  assert.deepEqual(plan.lines, ['set OH_STRIPE_PRICE: "price_old" -> "openhearts_annual"', 'remove variable OH_DEBUG, which is not defined']);
});

test('Pages: a missing secret is set by hand, and nothing is patched for it', () => {
  const have = liveProduction();
  delete have.env_vars.OH_ID_HMAC;
  have.env_vars.OH_SERVICE_SECRET = plain('oops');
  const plan = pagesEnvPlan(pages.environments.production, have, ids);
  assert.deepEqual(plan.patch, {});
  assert.equal(plan.owner.length, 2);
  assert.match(plan.owner[0], /OH_ID_HMAC is not set/);
  assert.match(plan.owner[1], /OH_SERVICE_SECRET is plain_text, not a secret/);
  // The plain value it holds is not repeated.
  assert.doesNotMatch(plan.owner.join(' '), /oops/);
});

test('Pages: the command for a missing secret sets it in its own environment', () => {
  const production = liveProduction();
  delete production.env_vars.OH_ID_HMAC;
  const [prod] = pagesEnvPlan(pages.environments.production, production, ids, 'production').owner;
  assert.match(prod, /secret put OH_ID_HMAC --project-name <project>`$/);
  const preview = liveProduction();
  delete preview.env_vars.OH_ID_HMAC;
  const [prev] = pagesEnvPlan(pages.environments.production, preview, ids, 'preview').owner;
  assert.match(prev, /secret put OH_ID_HMAC --project-name <project> --env preview`$/);
});

test("Pages: production wants Play's service account when the config names Play, as the worker does", () => {
  const config = JSON.parse(readFileSync(new URL('../config/openhearts.json', import.meta.url), 'utf8'));
  const named = Boolean(config.google?.package && config.google?.product);
  assert.equal(pages.environments.production.secrets.includes('OH_PLAY_SERVICE_ACCOUNT'), named);
});

test("Pages: a secret's value is never in a line", () => {
  const have = liveProduction();
  have.env_vars.OH_STRAY = { type: 'secret_text', value: 'hunter2' };
  have.env_vars.OH_STRIPE_PRICE = { type: 'secret_text', value: 'hunter3' };
  const plan = pagesEnvPlan(withVar, have, ids);
  assert.doesNotMatch(plan.lines.join('\n'), /hunter/);
  assert.deepEqual(plan.lines, ['set OH_STRIPE_PRICE as plain text (it is secret_text)', 'remove secret OH_STRAY, which is not defined']);
});

test('Pages: bindings added, rebound and removed', () => {
  const have = liveProduction();
  delete have.durable_object_namespaces;
  have.r2_buckets.OH_RECORDS.name = 'elsewhere';
  have.analytics_engine_datasets = { OH_METRICS: { dataset: 'elsewhere' } };
  have.services = { OTHER: { service: 'x' } };
  const plan = pagesEnvPlan(pages.environments.production, have, ids);
  assert.deepEqual(plan.patch, {
    durable_object_namespaces: { HOUSEHOLD: { namespace_id: 'fcae' } },
    r2_buckets: { OH_RECORDS: { name: 'open-hearts-records' } },
    analytics_engine_datasets: { OH_METRICS: { dataset: 'open_hearts_api' } },
    services: { OTHER: null },
  });
});

test('Pages: compatibility date and flags', () => {
  const have = liveProduction();
  have.compatibility_date = '2024-01-01';
  have.compatibility_flags = ['nodejs_compat'];
  const plan = pagesEnvPlan(pages.environments.production, have, ids);
  assert.deepEqual(plan.patch, { compatibility_date: '2026-09-09', compatibility_flags: [] });
});

test('Pages: the site at the apex and the app at play, one project', () => {
  assert.deepEqual(pages.domains, ['openhearts.game', 'play.openhearts.game']);
  const live = [
    { name: 'openhearts.game', status: 'active' },
    { name: 'play.openhearts.game', status: 'active' },
  ];
  assert.deepEqual(pagesDomainsPlan(pages.domains, live), { add: [], remove: [], pending: [] });
});

test('Pages: a subdomain missing is added; one still being checked is the owner\'s; a stray one goes', () => {
  // Before the move: the apex alone.
  assert.deepEqual(pagesDomainsPlan(pages.domains, [{ name: 'openhearts.game', status: 'active' }]), {
    add: ['play.openhearts.game'],
    remove: [],
    pending: [],
  });
  // Just added: Cloudflare checks the record and issues a certificate.
  assert.deepEqual(
    pagesDomainsPlan(pages.domains, [
      { name: 'openhearts.game', status: 'active' },
      { name: 'play.openhearts.game', status: 'pending' },
      { name: 'old.openhearts.game', status: 'active' },
    ]),
    { add: [], remove: ['old.openhearts.game'], pending: [{ name: 'play.openhearts.game', status: 'pending' }] },
  );
});

test('Pages: every custom domain has its proxied CNAME to the project in its zone', () => {
  assert.deepEqual(pagesDomainProblems(pages, zones), []);
  assert.equal(zoneOf('play.openhearts.game', Object.keys(zones)), 'openhearts.game');
  assert.equal(zoneOf('openhearts.game', Object.keys(zones)), 'openhearts.game');
  assert.equal(zoneOf('play.openhearts.gamer', Object.keys(zones)), null);
  assert.equal(zoneOf('a.b.example', ['example', 'b.example']), 'b.example', 'the longest zone wins');
  // Each way it can go wrong.
  const without = (name) => ({ ...zones, 'openhearts.game': { ...zones['openhearts.game'], dns: zones['openhearts.game'].dns.filter((r) => r.name !== name) } });
  assert.deepEqual(pagesDomainProblems(pages, without('play.openhearts.game')), ['play.openhearts.game has no CNAME in openhearts.game']);
  const elsewhere = {
    ...zones,
    'openhearts.game': {
      ...zones['openhearts.game'],
      dns: zones['openhearts.game'].dns.map((r) => (r.name === 'play.openhearts.game' ? { ...r, content: 'other.pages.dev', proxied: false } : r)),
    },
  };
  assert.deepEqual(pagesDomainProblems(pages, elsewhere), ["play.openhearts.game's CNAME is other.pages.dev (not proxied), not open-hearts.pages.dev (proxied)"]);
  assert.deepEqual(pagesDomainProblems({ ...pages, domains: ['play.openhearts.example'] }, zones), ['play.openhearts.example is in no zone defined here']);
});

test("rules: the API's rate limit covers /api/ on the app's host, the one that serves it", () => {
  const [limit] = game.rules.http_ratelimit;
  assert.match(limit.expression, /http\.host eq "play\.openhearts\.game" and starts_with\(http\.request\.uri\.path, "\/api\/"\)/);
});

test("rules: the webhooks are left out of the API's rate limit, and nothing else is", () => {
  const [limit] = game.rules.http_ratelimit;
  const left = /not http\.request\.uri\.path in \{([^}]*)\}/.exec(limit.expression)?.[1];
  // Stripe's, the App Store's, Sign in with Apple's and Play's
  // (service/functions/worker.mjs): each sent again in bursts from few
  // addresses, and each checked by its sender's signature.
  assert.deepEqual(left?.match(/"[^"]*"/g), ['"/api/stripe"', '"/api/apple"', '"/api/apple-id"', '"/api/play"']);
});

// ---- the relay's wrangler.toml ------------------------------------------------

test('toml: tables, arrays of tables, inline tables, comments', () => {
  const t = parseToml(`
name = "w" # a comment
n = 3
flag = true
routes = [{ pattern = "a.example", custom_domain = true }]
list = [
  "x", # one
  "y#z",
]
[vars]
A = "b\\"c"
[[things]]
k = "1"
[[things]]
k = "2"
[observability]
enabled = true
`);
  assert.deepEqual(t, {
    name: 'w',
    n: 3,
    flag: true,
    routes: [{ pattern: 'a.example', custom_domain: true }],
    list: ['x', 'y#z'],
    vars: { A: 'b"c' },
    things: [{ k: '1' }, { k: '2' }],
    observability: { enabled: true },
  });
});

const wrangler = parseToml(await readFile(new URL('../service/do/wrangler.toml', import.meta.url), 'utf8'));

test("toml: the relay's own wrangler.toml reads", () => {
  assert.equal(wrangler.name, 'open-hearts-relay');
  assert.deepEqual(wrangler.routes, [{ pattern: 'relay.openhearts.game', custom_domain: true }]);
  assert.deepEqual(
    wranglerBindings(wrangler).map((b) => `${b.type}:${b.name}`).sort(),
    ['analytics_engine:OH_METRICS', 'durable_object_namespace:BENCH', 'durable_object_namespace:HOUSEHOLD', 'durable_object_namespace:TABLE', 'kv_namespace:OH_STORE', 'plain_text:OH_MAIL_FROM', 'send_email:EMAIL', 'version_metadata:CF_VERSION_METADATA'],
  );
});

const liveRelay = () => ({
  settings: {
    compatibility_date: wrangler.compatibility_date,
    compatibility_flags: [],
    observability: { enabled: true },
    bindings: [
      { class_name: 'Bench', name: 'BENCH', namespace_id: 'fba6', type: 'durable_object_namespace' },
      { name: 'CF_VERSION_METADATA', type: 'version_metadata' },
      { name: 'EMAIL', type: 'send_email' },
      { class_name: 'Household', name: 'HOUSEHOLD', namespace_id: 'a1c3', type: 'durable_object_namespace' },
      { name: 'OH_JUROR_SECRET', type: 'secret_text' },
      { dataset: 'open_hearts_relay', name: 'OH_METRICS', type: 'analytics_engine' },
      { name: 'OH_MAIL_FROM', text: 'noreply@openhearts.game', type: 'plain_text' },
      { name: 'OH_STORE', namespace_id: '5b65151de63341dc9f7a9d417c9b6a4e', type: 'kv_namespace' },
      { class_name: 'TagRelay', name: 'TABLE', namespace_id: '744b', type: 'durable_object_namespace' },
    ],
  },
  secrets: ['OH_JUROR_SECRET'],
  domains: [{ hostname: 'relay.openhearts.game', service: 'open-hearts-relay', enabled: true }],
  subdomain: { enabled: false },
  namespaces: ['TagRelay', 'Household', 'Bench'].map((c) => ({ script: 'open-hearts-relay', class: c })),
  containers: [{ name: 'open-hearts-relay-bench', max_instances: 1 }],
});

test('relay: as deployed, it matches wrangler.toml', () => {
  assert.deepEqual(relayProblems(wrangler, relay, liveRelay()), []);
});

test('relay: each kind of drift is said', () => {
  const live = liveRelay();
  live.settings.compatibility_date = '2024-01-01';
  live.settings.bindings = live.settings.bindings.filter((b) => b.name !== 'EMAIL' && b.name !== 'CF_VERSION_METADATA');
  live.settings.bindings.find((b) => b.name === 'OH_MAIL_FROM').text = 'other@openhearts.game';
  live.settings.bindings.push({ name: 'EXTRA', type: 'plain_text', text: '' });
  live.secrets = [];
  live.domains = [];
  live.subdomain = { enabled: true };
  live.namespaces = live.namespaces.filter((n) => n.class !== 'Household');
  live.containers[0].max_instances = 3;
  const problems = relayProblems(wrangler, relay, live).join('\n');
  for (const said of [/compatibility date/, /EMAIL .* not on the worker/, /CF_VERSION_METADATA .* not on the worker/, /OH_MAIL_FROM: text/, /EXTRA .* not in wrangler.toml/, /OH_JUROR_SECRET is not set/, /relay.openhearts.game is not attached/, /workers.dev address is on/, /namespace for Household/, /max_instances is 3/]) {
    assert.match(problems, said);
  }
});

test('relay: not deployed at all', () => {
  assert.deepEqual(relayProblems(wrangler, relay, { settings: null }), ['worker open-hearts-relay is not deployed']);
});

// ---- Email Routing --------------------------------------------------------

const routing = game.emailRouting;
const ADDRESS = 'owner@example.com';
const liveRouting = () => ({
  settings: { enabled: true },
  rules: [
    { id: 'h', matchers: [{ type: 'literal', field: 'to', value: 'help@openhearts.game' }], actions: [{ type: 'forward', value: [ADDRESS] }], enabled: true },
    { id: 'a', matchers: [{ type: 'literal', field: 'to', value: 'alerts@openhearts.game' }], actions: [{ type: 'forward', value: [ADDRESS] }], enabled: true },
    { id: 'c', matchers: [{ type: 'all' }], actions: [{ type: 'drop' }], enabled: false },
  ],
  catchAll: { id: 'c', matchers: [{ type: 'all' }], actions: [{ type: 'drop' }], enabled: false },
});
const verified = [{ email: ADDRESS, verified: true }];

test('Email Routing: as it is, with the destination known or not', () => {
  for (const to of [() => ADDRESS, () => null]) {
    assert.deepEqual(emailRoutingPlan(routing, liveRouting(), verified, to), { lines: [], owner: [], rules: [], catchAll: null });
  }
});

test('Email Routing: a different destination is changed, and never named', () => {
  const plan = emailRoutingPlan(routing, liveRouting(), [...verified, { email: 'new@example.com', verified: true }], () => 'new@example.com');
  assert.deepEqual(plan.rules, [
    { op: 'update', id: 'h', to: 'help@openhearts.game', dest: 'new@example.com' },
    { op: 'update', id: 'a', to: 'alerts@openhearts.game', dest: 'new@example.com' },
  ]);
  assert.doesNotMatch([...plan.lines, ...plan.owner].join('\n'), /example\.com/);
});

test('Email Routing: an unverified destination is the owner\'s; an unknown one is added', () => {
  let plan = emailRoutingPlan(routing, liveRouting(), [{ email: ADDRESS, verified: false }], () => null);
  assert.match(plan.owner.join(), /not verified/);
  plan = emailRoutingPlan(routing, liveRouting(), [], () => ADDRESS);
  assert.match(plan.lines.join(), /add \$OH_HELP_FORWARD as a destination/);
});

test('Email Routing: no rule and no destination known is for the owner; catch-all on is turned off', () => {
  const have = liveRouting();
  have.rules = have.rules.filter((r) => r.id !== 'h');
  have.catchAll.enabled = true;
  const plan = emailRoutingPlan(routing, have, verified, () => null);
  assert.match(plan.owner.join(), /no rule forwards help@openhearts.game: set OH_HELP_FORWARD/);
  assert.deepEqual(plan.catchAll, { enabled: false });
});

test('Email Routing: alerts@ is made to go where help@ goes, with no destination given', () => {
  const have = liveRouting();
  have.rules = have.rules.filter((r) => r.id !== 'a');
  const plan = emailRoutingPlan(routing, have, verified, () => null);
  assert.deepEqual(plan.rules, [{ op: 'create', to: 'alerts@openhearts.game', dest: ADDRESS }]);
  assert.deepEqual(plan.lines, ['create a rule forwarding alerts@openhearts.game to where help@openhearts.game goes']);
  assert.deepEqual(plan.owner, []);
});

test('Email Routing: a stray rule is deleted; off where it is defined off', () => {
  const have = liveRouting();
  have.rules.push({ id: 's', matchers: [{ type: 'literal', field: 'to', value: 'sales@openhearts.game' }], actions: [{ type: 'drop' }], enabled: true });
  assert.deepEqual(emailRoutingPlan(routing, have, verified, () => null).rules, [{ op: 'delete', id: 's' }]);
  assert.deepEqual(emailRoutingPlan({ enabled: false }, { settings: { enabled: false } }, [], () => null).lines, []);
  assert.deepEqual(emailRoutingPlan({ enabled: false }, { settings: { enabled: true } }, [], () => null).lines, ['disable Email Routing']);
});

// ---- spend alerts -------------------------------------------------------------

const alerts = { description: 'ours', dollars: [10, 20], name: (d) => `Spend $${d}`, emailFrom: 'OH_ALERT_EMAIL' };
const policy = (id, d, extra = {}) => ({ id, name: `Spend $${d}`, description: 'ours', enabled: true, alert_type: 'billing_budget_alert', mechanisms: { email: [{ id: ADDRESS }] }, filters: { total_spend_dollars: [String(d)] }, ...extra });

test('spend alerts: as they are', () => {
  const have = [policy('a', 10), policy('b', 20), policy('x', 5, { description: "someone else's" })];
  assert.deepEqual(budgetPlan(alerts, have, null), { create: [], fix: [], remove: [] });
  assert.deepEqual(budgetPlan(alerts, have, ADDRESS), { create: [], fix: [], remove: [] });
});

test('spend alerts: missing, wrong and stray', () => {
  const have = [policy('a', 10, { enabled: false }), policy('c', 50)];
  const plan = budgetPlan(alerts, have, 'other@example.com');
  assert.deepEqual(plan.create, [20]);
  assert.deepEqual(plan.fix, [{ id: 'a', dollars: 10, why: ['disabled', 'emails someone other than $OH_ALERT_EMAIL'] }]);
  assert.deepEqual(plan.remove, [{ id: 'c', dollars: 50 }]);
});

// ---- Stripe ----------------------------------------------------------------

test('a key says its mode, and whether it is restricted', () => {
  assert.deepEqual(keyMode('rk_live_abc'), { mode: 'live', restricted: true });
  assert.deepEqual(keyMode('sk_test_abc'), { mode: 'test', restricted: false });
  assert.equal(keyMode('pk_live_abc'), null);
  assert.equal(keyMode(undefined), null);
});

test("Stripe's form encoding, nested", () => {
  assert.deepEqual(form({ a: 1, b: { c: [true, 'x'], d: null }, e: [{ f: 2 }] }), [
    ['a', '1'],
    ['b[c][0]', 'true'],
    ['b[c][1]', 'x'],
    ['b[d]', ''],
    ['e[0][f]', '2'],
  ]);
  assert.equal(formBody({ enabled_events: ['a.b'] }), 'enabled_events%5B0%5D=a.b');
});

const livePrice = () => ({
  id: 'price_1ULw2d5GXiRLIecgFYXHOchW',
  active: true,
  currency: 'usd',
  lookup_key: 'openhearts_annual',
  recurring: { interval: 'year', interval_count: 1, usage_type: 'licensed' },
  tax_behavior: 'unspecified',
  type: 'recurring',
  unit_amount: 599,
});

test('price: as it is; another amount is a new price', () => {
  assert.equal(pricePlan(stripe.price, livePrice()).create, false);
  assert.equal(pricePlan(stripe.price, null).create, true);
  const dearer = { ...livePrice(), unit_amount: 699 };
  assert.deepEqual(pricePlan(stripe.price, dearer), { create: true, why: 'unit_amount: 699 -> 599', diffs: [{ path: 'unit_amount', want: 599, have: 699 }] });
  assert.equal(pricePlan(stripe.price, { ...livePrice(), recurring: { interval: 'month', interval_count: 1 } }).create, true);
});

const liveWebhooks = () => [
  { id: 'we_1', url: 'https://play.openhearts.game/api/stripe', api_version: '2025-11-17.clover', status: 'enabled', enabled_events: [...stripe.webhooks[0].events].reverse() },
  { id: 'we_2', url: 'https://other.example/hook', api_version: '2020-01-01', status: 'enabled', enabled_events: ['*'] },
];

test("webhooks: as they are; another app's is not ours", () => {
  assert.deepEqual(webhookPlan(stripe.webhooks, liveWebhooks(), stripe.hosts), { update: [], remove: [], owner: [] });
});

test('webhooks: events and status are fixed, a stray one of ours deleted, a missing one is the owner\'s', () => {
  const have = liveWebhooks();
  have[0].enabled_events = ['checkout.session.completed'];
  have[0].status = 'disabled';
  have.push({ id: 'we_3', url: 'https://dev.open-hearts.pages.dev/api/stripe', api_version: '2025-11-17.clover', status: 'enabled', enabled_events: [] });
  const plan = webhookPlan(stripe.webhooks, have, stripe.hosts);
  assert.deepEqual(plan.update.map((u) => [u.id, Object.keys(u.changes)]), [['we_1', ['enabled_events', 'disabled']]]);
  assert.deepEqual(plan.remove, [{ id: 'we_3', url: 'https://dev.open-hearts.pages.dev/api/stripe' }]);
  assert.match(webhookPlan(stripe.webhooks, [], stripe.hosts).owner.join(), /no webhook to https:\/\/play.openhearts.game\/api\/stripe.*OH_STRIPE_WEBHOOK_SECRET/);
});

test('webhooks: one of ours at the same path on another of our hosts is moved, keeping its secret', () => {
  const have = liveWebhooks();
  have[0].url = 'https://openhearts.game/api/stripe';
  const plan = webhookPlan(stripe.webhooks, have, stripe.hosts);
  assert.deepEqual(plan.update, [
    { id: 'we_1', url: 'https://play.openhearts.game/api/stripe', changes: { url: 'https://play.openhearts.game/api/stripe' }, had: { url: 'https://openhearts.game/api/stripe', events: have[0].enabled_events, status: 'enabled' } },
  ]);
  assert.deepEqual(plan.remove, []);
  assert.deepEqual(plan.owner, [], 'no new endpoint, so no new secret to set');
});

test('webhooks: another API version can only be made anew', () => {
  const have = liveWebhooks();
  have[0].api_version = '2024-06-20';
  assert.match(webhookPlan(stripe.webhooks, have, stripe.hosts).owner.join(), /API version 2024-06-20/);
});

const livePortal = () => ({
  id: 'bpc_1',
  active: true,
  is_default: true,
  business_profile: { headline: null, privacy_policy_url: 'https://openhearts.game/privacy', terms_of_service_url: 'https://openhearts.game/terms' },
  default_return_url: null,
  features: {
    customer_update: { allowed_updates: ['name', 'email', 'address', 'phone'], enabled: true },
    invoice_history: { enabled: true },
    payment_method_update: { enabled: true, payment_method_configuration: null },
    subscription_cancel: {
      cancellation_reason: { enabled: true, feedback_options: [], options: ['too_expensive', 'switched_service', 'unused', 'other'] },
      enabled: true,
      mode: 'at_period_end',
      proration_behavior: 'none',
    },
    subscription_pause: { enabled: false },
    subscription_update: { billing_cycle_anchor: 'unchanged', default_allowed_updates: [], enabled: false, proration_behavior: 'always_invoice' },
  },
  login_page: { enabled: false, url: null },
});

test('portal: as it is; cancelling switched off is a difference', () => {
  assert.deepEqual(portalPlan(stripe.portal, livePortal()), { create: false, diffs: [] });
  const have = livePortal();
  have.features.subscription_cancel.enabled = false;
  have.business_profile.terms_of_service_url = null;
  assert.deepEqual(portalPlan(stripe.portal, have).diffs.map(describe), [
    'business_profile.terms_of_service_url: null -> "https://openhearts.game/terms"',
    'features.subscription_cancel.enabled: false -> true',
  ]);
  assert.equal(portalPlan(stripe.portal, null).create, true);
});

// ---- the definitions themselves ------------------------------------------------

test('no secret value and no address but our own is in a definition', async () => {
  for (const file of ['cloudflare.mjs', 'stripe.mjs']) {
    const text = await readFile(new URL(file, import.meta.url), 'utf8');
    assert.doesNotMatch(text, /\b(sk|rk)_(live|test)_|whsec_/, file);
    const addresses = text.match(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g) ?? [];
    assert.deepEqual(addresses.filter((a) => !a.endsWith('@openhearts.game')), [], file);
  }
});

test('every secret a Pages environment needs is named, and none is also a plain variable', () => {
  for (const [env, e] of Object.entries(pages.environments)) {
    for (const s of e.secrets) assert.equal(s in e.vars, false, `${env} ${s}`);
  }
});
