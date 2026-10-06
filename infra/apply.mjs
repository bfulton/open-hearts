// Makes the Cloudflare and Stripe accounts match cloudflare.mjs and
// stripe.mjs, for this app and nothing else in them.
//
//   node infra/apply.mjs                        what would change, and stop
//   node infra/apply.mjs --apply                change it
//   node infra/apply.mjs --only cloudflare      one account (or: stripe)
//
// Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID for Cloudflare,
// STRIPE_API_KEY for Stripe; OH_HELP_FORWARD and OH_ALERT_EMAIL, when
// set, are where help@ forwards and who the spend alerts email (unset,
// those are checked to exist and not compared). A dry run only reads.
//
// What it says comes in four kinds: `would …` is a change --apply makes;
// `by hand:` is a difference only the operator (or a wrangler deploy) can
// fix — a secret this has no value for, a setting the API will not
// take; `unread:` is something the credentials could not read, with
// Cloudflare's or Stripe's own words; `ok` is a part that matches. No
// secret is printed, and no address: the env vars are named instead.

import { readFile } from 'node:fs/promises';

import { budgetAlerts, kv, pages, r2, relay, turnKeys, zones } from './cloudflare.mjs';
import {
  budgetPlan,
  describe,
  dnsPlan,
  drift,
  emailRoutingPlan,
  formBody,
  keyMode,
  pagesDomainProblems,
  pagesDomainsPlan,
  pagesEnvPlan,
  parseToml,
  portalPlan,
  pricePlan,
  recordLine,
  relayProblems,
  rulesPlan,
  settingsPlan,
  webhookPlan,
} from './diff.mjs';
import { stripe } from './stripe.mjs';

const args = process.argv.slice(2);
const write = args.includes('--apply');
const onlyAt = args.indexOf('--only');
const only = onlyAt >= 0 ? args[onlyAt + 1] : null;
if (only !== null && !['cloudflare', 'stripe'].includes(only)) {
  console.error('apply: --only takes cloudflare or stripe');
  process.exit(2);
}

const counts = { change: 0, owner: 0, unread: 0 };
const say = (line) => {
  counts.change++;
  console.log(`${write ? '' : 'would '}${line}`);
};
const owner = (line) => {
  counts.owner++;
  console.log(`by hand: ${line}`);
};
const ok = (line) => console.log(`ok      ${line}`);
const note = (line) => console.log(`note:   ${line}`);

/// Whatever an API says back, without anything that could be a key.
const clean = (text) =>
  String(text)
    .replace(/\b(sk|rk|pk|whsec)_[A-Za-z0-9_*]+/g, '$1_…')
    .replaceAll(process.env.CLOUDFLARE_ACCOUNT_ID || '\u0000', '<account>');

class ApiError extends Error {}

/// A part that could not be read is said so, and the run goes on.
async function part(what, fn) {
  try {
    await fn();
  } catch (e) {
    if (!(e instanceof ApiError)) throw e;
    counts.unread++;
    console.log(`unread: ${what}: ${e.message}`);
  }
}

// ---- Cloudflare -------------------------------------------------------------

const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const acct = `/accounts/${account}`;

async function cf(method, path, body) {
  const res = await fetch(`https://api.cloudflare.com/client/v4${path}`, {
    method,
    headers: { Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const out = await res.json().catch(() => null);
  if (!out?.success) {
    const errors = out?.errors?.map((e) => `${e.code} ${e.message}`).join('; ') || `HTTP ${res.status}`;
    throw new ApiError(clean(`${method} ${path} answered ${res.status}: ${errors}`));
  }
  return out;
}
const get = async (path) => (await cf('GET', path)).result;
/// Every page of a paged list.
async function all(path) {
  const out = [];
  for (let page = 1; ; page++) {
    const r = await cf('GET', `${path}${path.includes('?') ? '&' : '?'}page=${page}&per_page=100`);
    out.push(...(r.result ?? []));
    const info = r.result_info;
    if (!info || !info.total_pages || page >= info.total_pages) break;
  }
  return out;
}
/// A read that may find nothing: null for a 404.
async function maybe(path) {
  try {
    return await get(path);
  } catch (e) {
    if (e instanceof ApiError && / answered 404:/.test(e.message)) return null;
    throw e;
  }
}

async function applyPages() {
  const p = pages.project;
  const project = await maybe(`${acct}/pages/projects/${p}`);
  if (!project) {
    say(`create Pages project ${p} (production branch ${pages.productionBranch})`);
    if (write) await cf('POST', `${acct}/pages/projects`, { name: p, production_branch: pages.productionBranch });
    return;
  }
  const before = counts.change + counts.owner;
  if (project.production_branch !== pages.productionBranch) {
    say(`set ${p}'s production branch: ${project.production_branch} -> ${pages.productionBranch}`);
    if (write) await cf('PATCH', `${acct}/pages/projects/${p}`, { production_branch: pages.productionBranch });
  }
  // Web Analytics, set on the project, injects its beacon into every page.
  if (!pages.webAnalytics && project.build_config?.web_analytics_tag) {
    say(`turn off Web Analytics on ${p}`);
    if (write) await cf('PATCH', `${acct}/pages/projects/${p}`, { build_config: { web_analytics_tag: null, web_analytics_token: null } });
  }

  // Custom domains, the apex's and play's alike; each one's CNAME is
  // the zone's (applyZone), and the definition is checked to give it one.
  for (const line of pagesDomainProblems(pages, zones)) owner(`${p}: ${line} (infra/cloudflare.mjs)`);
  const domains = await get(`${acct}/pages/projects/${p}/domains`);
  const plan = pagesDomainsPlan(pages.domains, domains);
  for (const name of plan.add) {
    say(`add custom domain ${name} to ${p}`);
    if (write) await cf('POST', `${acct}/pages/projects/${p}/domains`, { name });
  }
  for (const d of plan.pending) owner(`${p}'s domain ${d.name} is ${d.status}: see the project's Custom domains`);
  for (const name of plan.remove) {
    say(`remove custom domain ${name} from ${p}, which is not defined`);
    if (write) await cf('DELETE', `${acct}/pages/projects/${p}/domains/${name}`);
  }

  // Environments: variables, secrets by name, bindings.
  const namespaces = await all(`${acct}/storage/kv/namespaces`);
  const objects = await all(`${acct}/workers/durable_objects/namespaces`);
  const ids = {
    kv: Object.fromEntries(namespaces.map((n) => [n.title, n.id])),
    durableObjects: Object.fromEntries(objects.map((n) => [`${n.script}/${n.class}`, n.id])),
  };
  const summary = [];
  for (const [env, want] of Object.entries(pages.environments)) {
    const have = project.deployment_configs?.[env] ?? {};
    const { patch, lines, owner: theirs } = pagesEnvPlan(want, have, ids);
    for (const line of theirs) owner(`${p} ${env}: ${line.replace('<project>', p)}`);
    for (const line of lines) say(`${p} ${env}: ${line}`);
    if (write && Object.keys(patch).length) await cf('PATCH', `${acct}/pages/projects/${p}`, { deployment_configs: { [env]: patch } });
    const bindings = ['kv', 'r2', 'durableObjects', 'analyticsEngine'].reduce((n, k) => n + Object.keys(want[k] ?? {}).length, 0);
    summary.push(`${env} ${Object.keys(want.vars).length} variables, ${want.secrets.length} secrets set, ${bindings} bindings`);
  }
  if (counts.change + counts.owner === before) {
    ok(`Pages ${p}: branch ${pages.productionBranch}, domains ${pages.domains.join(', ')}, no Web Analytics; ${summary.join('; ')}`);
  }
}

async function applyStores() {
  const namespaces = await all(`${acct}/storage/kv/namespaces`);
  for (const title of kv) {
    if (namespaces.some((n) => n.title === title)) continue;
    say(`create KV namespace ${title}`);
    if (write) await cf('POST', `${acct}/storage/kv/namespaces`, { title });
  }
  ok(`KV namespaces ${kv.join(', ')}`);

  for (const b of r2) {
    const base = `${acct}/r2/buckets/${b.name}`;
    const bucket = await maybe(base);
    if (!bucket) {
      say(`create R2 bucket ${b.name} (${b.location})`);
      if (write) await cf('POST', `${acct}/r2/buckets`, { name: b.name, locationHint: b.location.toLowerCase(), storageClass: b.storageClass });
      continue;
    }
    const before = counts.change + counts.owner;
    if (bucket.location !== b.location) owner(`R2 bucket ${b.name} is in ${bucket.location}, defined as ${b.location}: a bucket cannot move`);
    if (bucket.storage_class !== b.storageClass) owner(`R2 bucket ${b.name} is ${bucket.storage_class}, defined as ${b.storageClass}`);
    const managed = await get(`${base}/domains/managed`);
    if (managed.enabled !== b.publicDevUrl) {
      say(`${b.publicDevUrl ? 'open' : 'close'} R2 bucket ${b.name}'s public r2.dev address`);
      if (write) await cf('PUT', `${base}/domains/managed`, { enabled: b.publicDevUrl });
    }
    const custom = (await get(`${base}/domains/custom`)).domains ?? [];
    for (const d of custom.filter((x) => !b.customDomains.includes(x.domain))) {
      say(`detach custom domain ${d.domain} from R2 bucket ${b.name}`);
      if (write) await cf('DELETE', `${base}/domains/custom/${d.domain}`);
    }
    for (const d of b.customDomains.filter((x) => !custom.some((c) => c.domain === x))) {
      owner(`attach custom domain ${d} to R2 bucket ${b.name} (the dashboard's Settings, Custom Domains)`);
    }
    // No CORS rules: a page elsewhere has no business reading it.
    const cors = await maybe(`${base}/cors`).catch((e) => {
      // 404 and "does not exist" (10059) both mean none.
      if (e instanceof ApiError && /10059/.test(e.message)) return null;
      throw e;
    });
    if (cors?.rules?.length) {
      say(`remove R2 bucket ${b.name}'s CORS rules`);
      if (write) await cf('DELETE', `${base}/cors`);
    }
    if (counts.change + counts.owner === before) ok(`R2 bucket ${b.name}: ${bucket.location}, ${bucket.storage_class}, no public address, no custom domain, no CORS`);
  }

  const keys = await get(`${acct}/calls/turn_keys`);
  for (const t of turnKeys) {
    const k = keys.find((x) => x.name === t.name);
    if (!k) owner(`no Realtime TURN key ${t.name}: make one (its secret, shown once, is OH_TURN_API_TOKEN) and set OH_TURN_KEY_ID to its id`);
    else if (k.uid !== t.uid) owner(`TURN key ${t.name} is ${k.uid}, defined as ${t.uid}: set OH_TURN_KEY_ID in cloudflare.mjs and the project`);
    else ok(`Realtime TURN key ${t.name}`);
  }
}

async function applyRelay() {
  const toml = parseToml(await readFile(new URL(`../${relay.wrangler}`, import.meta.url), 'utf8'));
  const name = toml.name;
  const settings = await maybe(`${acct}/workers/scripts/${name}/settings`);
  const live = { settings, secrets: [], domains: [], subdomain: null, namespaces: [], containers: [] };
  if (settings) {
    live.secrets = (await get(`${acct}/workers/scripts/${name}/secrets`)).map((s) => s.name);
    live.domains = (await get(`${acct}/workers/domains`)).filter(
      (d) => d.service === name || (toml.routes ?? []).some((r) => r.pattern === d.hostname),
    );
    live.subdomain = await get(`${acct}/workers/scripts/${name}/subdomain`);
    live.namespaces = (await all(`${acct}/workers/durable_objects/namespaces`)).filter((n) => n.script === name);
    if (toml.containers?.length) live.containers = await get(`${acct}/containers/applications`);
  }
  const problems = relayProblems(toml, relay, live);
  for (const line of problems) owner(`relay ${name}: ${line} (deploy with wrangler from service/do)`);
  if (!problems.length) {
    const routes = (toml.routes ?? []).map((r) => r.pattern).join(', ');
    ok(`relay worker ${name} matches ${relay.wrangler}: ${routes} only, ${settings.bindings.length} bindings, secrets ${relay.secrets.join(', ')}`);
  }
}

async function zoneId(name) {
  const found = await get(`/zones?name=${name}&account.id=${account}`);
  return found[0]?.id ?? null;
}

async function applyZone(name, def, destinations) {
  const z = await zoneId(name);
  if (!z) {
    owner(`zone ${name} is not on the account: add it in the dashboard and point the registrar at Cloudflare`);
    return;
  }
  const at = `/zones/${z}`;

  await part(`${name} settings`, async () => {
    const have = {};
    for (const id of Object.keys(def.settings)) have[id] = (await get(`${at}/settings/${id}`)).value;
    const changes = settingsPlan(def.settings, have);
    for (const c of changes) {
      say(`set ${name} ${c.id}: ${JSON.stringify(c.have)} -> ${JSON.stringify(c.want)}`);
      if (write) await cf('PATCH', `${at}/settings/${c.id}`, { value: c.want });
    }
    const bots = await get(`${at}/bot_management`);
    if ((bots.fight_mode ?? false) !== def.botFightMode) {
      say(`turn ${def.botFightMode ? 'on' : 'off'} ${name} Bot Fight Mode`);
      if (write) await cf('PUT', `${at}/bot_management`, { fight_mode: def.botFightMode });
    }
    if (!changes.length && (bots.fight_mode ?? false) === def.botFightMode) {
      const pinned = Object.entries(def.settings).map(([k, v]) => `${k} ${v}`);
      ok(`${name} settings: ${[...pinned, `bot fight mode ${def.botFightMode ? 'on' : 'off'}`].join(', ')}`);
    }
  });

  await part(`${name} DNS`, async () => {
    const records = await all(`${at}/dns_records`);
    const plan = dnsPlan(def, records);
    for (const r of plan.create) {
      say(`create ${recordLine(r)}`);
      if (write) await cf('POST', `${at}/dns_records`, r);
    }
    for (const u of plan.update) {
      say(`update ${u.record.type} ${u.record.name}: ${u.diffs.map(describe).join(', ')}`);
      if (write) await cf('PATCH', `${at}/dns_records/${u.id}`, u.record);
    }
    for (const r of plan.remove) {
      say(`delete ${recordLine(r)}, which is not defined`);
      if (write) await cf('DELETE', `${at}/dns_records/${r.id}`);
    }
    for (const m of plan.missing) owner(`${m.type} ${m.name}, which ${m.by} makes, is missing: turn ${m.by} on again`);
    if (!plan.create.length && !plan.update.length && !plan.remove.length && !plan.missing.length) {
      const extra = def.cloudflareDns.length ? ` and ${def.cloudflareDns.reduce((n, m) => n + (m.count ?? 1), 0)} of Cloudflare's own (${[...new Set(def.cloudflareDns.map((m) => m.by))].join(', ')})` : '';
      ok(`${name} DNS: ${def.dns.length} records${extra}`);
    }
  });

  await part(`${name} rules`, async () => {
    const sets = (await get(`${at}/rulesets`)).filter((s) => s.kind === 'zone');
    const have = {};
    for (const s of sets) have[s.phase] = (await get(`${at}/rulesets/${s.id}`)).rules ?? [];
    const plan = rulesPlan(def.rules, have);
    for (const p of plan) {
      const why = p.diffs.length ? p.diffs.map(describe).join(', ') : `${p.had} rule(s) -> ${p.rules.length}`;
      say(`replace ${name}'s ${p.phase} rules: ${why}`);
      if (write) await cf('PUT', `${at}/rulesets/phases/${p.phase}/entrypoint`, { rules: p.rules });
    }
    const routes = await get(`${at}/workers/routes`);
    for (const r of routes) {
      say(`delete worker route ${r.pattern} (${r.script ?? 'no script'}): this app's workers use custom domains`);
      if (write) await cf('DELETE', `${at}/workers/routes/${r.id}`);
    }
    if (!plan.length && !routes.length) {
      ok(`${name} rules: ${Object.entries(def.rules).map(([phase, rules]) => `${phase} (${rules.map((r) => r.description).join('; ')})`).join(', ')}; no worker routes`);
    }
  });

  // Page rules are not readable with an account-owned token, which is
  // the kind this is meant to run with; nothing here uses them.
  await part(`${name} page rules`, async () => {
    try {
      const rules = await get(`${at}/pagerules`);
      if (rules.length) owner(`${name} has ${rules.length} page rule(s); none is defined (they are deprecated: use rules)`);
    } catch (e) {
      if (e instanceof ApiError && /\b1011\b/.test(e.message)) note(`${name} page rules not read: an account-owned token cannot (Cloudflare 1011); none are defined`);
      else throw e;
    }
  });

  await part(`${name} Email Routing`, async () => {
    const want = def.emailRouting;
    const settings = await get(`${at}/email/routing`);
    const have = { settings };
    if (want.enabled) {
      have.rules = await all(`${at}/email/routing/rules`);
      have.catchAll = await get(`${at}/email/routing/rules/catch_all`);
    }
    const plan = emailRoutingPlan(want, have, destinations ?? [], (f) => process.env[f.destinationFrom] || null);
    for (const line of plan.owner) owner(`${name}: ${line}`);
    for (const line of plan.lines) say(`${name}: ${line}`);
    if (write) {
      if (want.enabled !== (settings.enabled === true)) await cf('POST', `${at}/email/routing/${want.enabled ? 'enable' : 'disable'}`, {});
      for (const f of want.forwards ?? []) {
        const dest = process.env[f.destinationFrom];
        if (dest && !(destinations ?? []).some((d) => d.email === dest)) await cf('POST', `${acct}/email/routing/addresses`, { email: dest });
      }
      for (const r of plan.rules) {
        const body = { name: '', enabled: true, matchers: [{ type: 'literal', field: 'to', value: r.to }], actions: [{ type: 'forward', value: [r.dest] }] };
        if (r.op === 'create') await cf('POST', `${at}/email/routing/rules`, body);
        if (r.op === 'update') await cf('PUT', `${at}/email/routing/rules/${r.id}`, body);
        if (r.op === 'delete') await cf('DELETE', `${at}/email/routing/rules/${r.id}`);
      }
      if (plan.catchAll) {
        await cf('PUT', `${at}/email/routing/rules/catch_all`, {
          enabled: plan.catchAll.enabled,
          matchers: [{ type: 'all' }],
          actions: have.catchAll?.actions ?? [{ type: 'drop' }],
        });
      }
    }
    if (!plan.lines.length && !plan.owner.length) {
      const set = (want.forwards ?? []).map((f) => (process.env[f.destinationFrom] ? `$${f.destinationFrom}` : `a verified address (${f.destinationFrom} unset, not compared)`));
      ok(
        want.enabled
          ? `${name} Email Routing: on; ${(want.forwards ?? []).map((f, i) => `${f.to} forwards to ${set[i]}`).join('; ')}; catch-all off`
          : `${name} Email Routing: off`,
      );
    }
  });

  await part(`${name} Email Sending`, async () => {
    const want = def.emailSending;
    const onboarded = (await get(`${acct}/email/sending/zones`)).find((x) => x.name === name);
    const on = onboarded?.enabled === true;
    if (on !== want.enabled) {
      owner(`${name} Email Sending is ${on ? 'on' : 'off'}, defined ${want.enabled ? 'on' : 'off'}: the dashboard's Email Service onboards a domain`);
      return;
    }
    if (!want.enabled) return ok(`${name} Email Sending: off`);
    const subs = await get(`${at}/email/sending/subdomains`);
    let fine = true;
    for (const w of want.subdomains) {
      const s = subs.find((x) => x.name === w.name);
      if (!s || !s.enabled || s.return_path_domain !== w.returnPath) {
        fine = false;
        owner(`${name} Email Sending: ${w.name} is ${s ? `${s.enabled ? 'on' : 'off'}, bounces to ${s.return_path_domain}` : 'not set up'}; defined on, bouncing to ${w.returnPath}`);
      }
    }
    if (fine) ok(`${name} Email Sending: on, from ${want.subdomains.map((s) => `${s.name} (bounces to ${s.returnPath})`).join(', ')}`);
  });

  await part(`${name} Logpush`, async () => {
    const jobs = await get(`${at}/logpush/jobs`);
    for (const j of jobs) {
      say(`delete ${name} Logpush job ${j.name ?? j.id} (${j.dataset}): the privacy page promises no request logs are kept`);
      if (write) await cf('DELETE', `${at}/logpush/jobs/${j.id}`);
    }
    if (!jobs.length && !def.logpush) ok(`${name} Logpush: no jobs`);
  });
}

async function applyWebAnalytics() {
  // Web Analytics sites are the account's; ours are those on our zones.
  const sites = (await get(`${acct}/rum/site_info/list`)).filter((s) => s.ruleset?.zone_name in zones || s.host in zones);
  let fine = true;
  for (const s of sites) {
    if (pages.webAnalytics) continue;
    if (s.ruleset?.enabled || s.auto_install) {
      fine = false;
      say(`turn off Web Analytics on ${s.ruleset?.zone_name ?? s.host} (it injects a beacon script)`);
      if (write) await cf('PUT', `${acct}/rum/site_info/${s.site_tag}`, { auto_install: false, enabled: false, zone_tag: s.ruleset?.zone_tag });
    }
  }
  if (fine) ok(`Web Analytics: off on ${Object.keys(zones).join(', ')}`);
}

async function applyBudgets() {
  const email = process.env[budgetAlerts.emailFrom] || null;
  const policies = await get(`${acct}/alerting/v3/policies`);
  const plan = budgetPlan(budgetAlerts, policies, email);
  const body = (dollars) => ({
    name: budgetAlerts.name(dollars),
    description: budgetAlerts.description,
    enabled: true,
    alert_type: 'billing_budget_alert',
    mechanisms: { email: [{ id: email }] },
    filters: { total_spend_dollars: [String(dollars)] },
  });
  for (const dollars of plan.create) {
    if (!email) {
      owner(`no spend alert at $${dollars}: set ${budgetAlerts.emailFrom} and run this again`);
      continue;
    }
    say(`create spend alert at $${dollars}, emailing $${budgetAlerts.emailFrom}`);
    if (write) await cf('POST', `${acct}/alerting/v3/policies`, body(dollars));
  }
  for (const f of plan.fix) {
    if (!email) {
      owner(`spend alert at $${f.dollars} is ${f.why.join(', ')}: set ${budgetAlerts.emailFrom} and run this again`);
      continue;
    }
    say(`fix spend alert at $${f.dollars} (${f.why.join(', ')})`);
    if (write) await cf('PUT', `${acct}/alerting/v3/policies/${f.id}`, body(f.dollars));
  }
  for (const r of plan.remove) {
    say(`delete spend alert at $${r.dollars}, which is not defined`);
    if (write) await cf('DELETE', `${acct}/alerting/v3/policies/${r.id}`);
  }
  if (!plan.create.length && !plan.fix.length && !plan.remove.length) {
    ok(`spend alerts at ${budgetAlerts.dollars.map((d) => `$${d}`).join(', ')}, emailing ${email ? `$${budgetAlerts.emailFrom}` : `someone (${budgetAlerts.emailFrom} unset, not compared)`}`);
  }
}

async function cloudflare() {
  if (!process.env.CLOUDFLARE_API_TOKEN || !account) {
    console.error('apply: Cloudflare needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID');
    process.exit(2);
  }
  console.log('== cloudflare (the account in CLOUDFLARE_ACCOUNT_ID)');
  await part('Pages', applyPages);
  await part('KV, R2 and TURN', applyStores);
  await part('the relay worker', applyRelay);
  let destinations = null;
  await part('Email Routing destination addresses', async () => {
    destinations = (await all(`${acct}/email/routing/addresses`)).map((d) => ({ email: d.email, verified: Boolean(d.verified) }));
  });
  for (const [name, def] of Object.entries(zones)) await applyZone(name, def, destinations);
  await part('Web Analytics', applyWebAnalytics);
  await part('spend alerts', applyBudgets);
}

// ---- Stripe -------------------------------------------------------------------

async function st(method, path, body) {
  const res = await fetch(`https://api.stripe.com/v1${path}`, {
    method,
    headers: { Authorization: `Bearer ${process.env.STRIPE_API_KEY}`, 'content-type': 'application/x-www-form-urlencoded' },
    body: body === undefined ? undefined : formBody(body),
  });
  const out = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(clean(`${method} ${path} answered ${res.status}: ${out?.error?.message ?? 'no message'}`));
  return out;
}

async function applyStripe() {
  const key = keyMode(process.env.STRIPE_API_KEY);
  if (!key) {
    console.error('apply: Stripe needs STRIPE_API_KEY (sk_… or rk_…)');
    process.exit(2);
  }
  console.log(`== stripe (${key.mode} mode, ${key.restricted ? 'a restricted key' : 'a secret key'})`);
  if (key.mode !== stripe.mode) {
    console.error(`apply: stripe.mjs describes ${stripe.mode} mode and STRIPE_API_KEY is a ${key.mode} key; nothing compared`);
    process.exit(2);
  }

  let price = null;
  await part('the price and product', async () => {
    const found = await st('GET', `/prices?active=true&lookup_keys[]=${encodeURIComponent(stripe.price.lookupKey)}&expand[]=data.product`);
    price = found.data[0] ?? null;
    const plan = pricePlan(stripe.price, price);
    const product = price?.product ?? null;
    const productDiffs = product ? drift({ ...stripe.product, active: true }, product) : [];
    if (plan.create) {
      say(`create a price ${stripe.price.unitAmount / 100} ${stripe.price.currency.toUpperCase()} a ${stripe.price.interval}, taking lookup key ${stripe.price.lookupKey} over (${plan.why})`);
      if (write) {
        const made = await st('POST', '/prices', {
          currency: stripe.price.currency,
          unit_amount: stripe.price.unitAmount,
          recurring: { interval: stripe.price.interval, interval_count: stripe.price.intervalCount },
          tax_behavior: stripe.price.taxBehavior,
          lookup_key: stripe.price.lookupKey,
          transfer_lookup_key: true,
          ...(product ? { product: product.id } : { product_data: { name: stripe.product.name } }),
        });
        await st('POST', `/products/${made.product}`, { default_price: made.id, description: stripe.product.description });
      }
    }
    if (productDiffs.length) {
      say(`update product ${product.id}: ${productDiffs.map(describe).join(', ')}`);
      if (write) await st('POST', `/products/${product.id}`, { name: stripe.product.name, description: stripe.product.description, active: true });
    }
    if (product && !plan.create && product.default_price !== price.id) {
      say(`make ${price.id} product ${product.id}'s default price`);
      if (write) await st('POST', `/products/${product.id}`, { default_price: price.id });
    }
    if (!plan.create && !productDiffs.length && product.default_price === price.id) {
      ok(`price ${stripe.price.lookupKey} (${price.id}): $${(price.unit_amount / 100).toFixed(2)} ${price.currency} every ${price.recurring.interval_count} ${price.recurring.interval}, active, the default of "${product.name}" (${product.id})`);
    }
  });

  await part('the customer portal', async () => {
    const configs = (await st('GET', '/billing_portal/configurations?limit=100')).data;
    const portal = configs.find((c) => c.is_default) ?? null;
    const plan = portalPlan(stripe.portal, portal);
    if (plan.create) {
      owner('no default customer portal configuration: save the portal settings once in the dashboard (Settings, Billing, Customer portal)');
      return;
    }
    if (!portal.active) owner(`the default portal configuration ${portal.id} is inactive`);
    if (plan.diffs.length) {
      say(`update portal configuration ${portal.id}: ${plan.diffs.map(describe).join(', ')}`);
      if (write) await st('POST', `/billing_portal/configurations/${portal.id}`, stripe.portal);
    } else {
      ok(`customer portal ${portal.id} (default): cancel at period end without proration, card and details updates, invoices; no pause or plan changes; privacy and terms links`);
    }
  });

  await part('webhooks', async () => {
    const endpoints = (await st('GET', '/webhook_endpoints?limit=100')).data;
    const plan = webhookPlan(stripe.webhooks, endpoints, stripe.hosts);
    for (const line of plan.owner) owner(line);
    for (const u of plan.update) {
      const parts = [];
      if (u.changes.enabled_events) parts.push(`events ${u.had.events?.length ?? 0} -> ${u.changes.enabled_events.length}`);
      if ('disabled' in u.changes) parts.push(`${u.had.status} -> enabled`);
      say(`update webhook ${u.id} to ${u.url}: ${parts.join(', ')}`);
      if (write) await st('POST', `/webhook_endpoints/${u.id}`, u.changes);
    }
    for (const r of plan.remove) {
      say(`delete webhook ${r.id} to ${r.url}, which is not defined`);
      if (write) await st('DELETE', `/webhook_endpoints/${r.id}`);
    }
    if (!plan.update.length && !plan.remove.length && !plan.owner.length) {
      for (const w of stripe.webhooks) ok(`webhook to ${w.url}: enabled, ${w.events.length} events, API version ${w.apiVersion} (its signing secret not read)`);
    }
  });

  note("the service's restricted key (OH_STRIPE_SECRET) cannot be read through the API: checked only as a secret set on the Pages project");
}

// ---- the run -------------------------------------------------------------------

if (only !== 'stripe') await cloudflare();
if (only !== 'cloudflare') await applyStripe();
const tail = [`${counts.owner} by hand`, ...(counts.unread ? [`${counts.unread} unread`] : [])].join(', ');
console.log(write ? `applied: ${counts.change} change(s); ${tail}` : `${counts.change} change(s), ${tail}; --apply to make the changes`);
process.exitCode = counts.unread ? 1 : 0;
