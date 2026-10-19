// What apply.mjs compares, as pure functions: a definition and what an
// API answered in, what differs out. No network and no environment, so
// node --test infra/ holds them to their word.

// ---- general --------------------------------------------------------------

const isObject = (x) => x !== null && typeof x === 'object' && !Array.isArray(x);

/// Lists of plain values are compared as sets: the APIs answer them in
/// orders of their own.
const sameList = (a, b) => {
  if (a.length !== b.length) return false;
  const key = (x) => JSON.stringify(x);
  const [x, y] = [a.map(key).sort(), b.map(key).sort()];
  return x.every((v, i) => v === y[i]);
};

/// Where `have` differs from `want`, looking only at what `want` names:
/// what the API adds besides (ids, timestamps, settings this does not
/// pin) is not a difference. Returns [{path, want, have}].
export function drift(want, have, path = '') {
  if (isObject(want)) {
    if (!isObject(have)) return [{ path: path || '.', want, have }];
    return Object.keys(want).flatMap((k) => drift(want[k], have[k], path ? `${path}.${k}` : k));
  }
  if (Array.isArray(want)) {
    if (!Array.isArray(have)) return [{ path: path || '.', want, have }];
    if (want.some(isObject)) {
      // Lists of objects keep their order: rules, records.
      if (want.length !== have.length) return [{ path: path || '.', want, have }];
      return want.flatMap((w, i) => drift(w, have[i], `${path}[${i}]`));
    }
    return sameList(want, have) ? [] : [{ path: path || '.', want, have }];
  }
  // null and absent are the same thing to every API here.
  if ((want ?? null) === (have ?? null)) return [];
  return [{ path: path || '.', want, have }];
}

/// One difference as a line: `path: have -> want`.
export const describe = (d) => `${d.path}: ${show(d.have)} -> ${show(d.want)}`;
const show = (v) => (v === undefined ? 'absent' : JSON.stringify(v));

// ---- DNS ------------------------------------------------------------------

/// Records Cloudflare made for a feature (Email Routing, Email Sending,
/// a worker's custom domain): read-only through the API, so not ours to
/// make, change or delete here.
export const madeByCloudflare = (r) => Boolean(r.meta?.read_only || r.meta?.email_routing || r.meta?.origin_worker_id);

const recordFields = (r) => ({
  type: r.type,
  name: r.name,
  content: r.content,
  proxied: r.proxied ?? false,
  ttl: r.ttl ?? 1,
  comment: r.comment ?? null,
  ...(r.priority != null ? { priority: r.priority } : {}),
});

/// The zone's own records against the definition's: what to create,
/// update (by id) and delete, and which of Cloudflare's own are missing.
export function dnsPlan(zone, have) {
  const mine = have.filter((r) => !madeByCloudflare(r));
  const used = new Set();
  const create = [];
  const update = [];
  const take = (pred) => {
    const r = mine.find((x) => !used.has(x.id) && pred(x));
    if (r) used.add(r.id);
    return r;
  };
  for (const want of zone.dns) {
    const w = recordFields(want);
    const found =
      take((r) => r.type === w.type && r.name === w.name && r.content === w.content) ??
      take((r) => r.type === w.type && r.name === w.name);
    if (!found) {
      create.push(w);
      continue;
    }
    const diffs = drift(w, recordFields(found));
    if (diffs.length) update.push({ id: found.id, record: w, diffs });
  }
  const remove = mine.filter((r) => !used.has(r.id)).map((r) => ({ ...recordFields(r), id: r.id }));
  const missing = (zone.cloudflareDns ?? []).filter((want) => {
    const n = have.filter((r) => madeByCloudflare(r) && r.type === want.type && r.name === want.name).length;
    return n < (want.count ?? 1);
  });
  return { create, update, remove, missing };
}

export const recordLine = (r) => `${r.type} ${r.name} ${r.content}${r.priority != null ? ` (priority ${r.priority})` : ''}${r.proxied ? ' (proxied)' : ''}`;

// ---- zone settings and rules --------------------------------------------

/// Settings to change: [{id, want, have}].
export function settingsPlan(want, have) {
  return Object.entries(want)
    .filter(([id, value]) => drift(value, have[id]).length > 0)
    .map(([id, value]) => ({ id, want: value, have: have[id] }));
}

const ruleKeys = ['description', 'expression', 'action', 'action_parameters', 'ratelimit', 'enabled'];
/// A rule as it is defined, without the ids and versions the API adds.
export const ruleOf = (r) => Object.fromEntries(ruleKeys.filter((k) => r[k] !== undefined).map((k) => [k, r[k]]));

/// Phases whose rules differ, each to be replaced whole: the phase's
/// entrypoint is the zone's, and these zones are the app's. A phase
/// with rules the definition does not name is emptied.
/// `have` maps phase -> rules (from the zone-kind entrypoints).
export function rulesPlan(want, have) {
  const phases = new Set([...Object.keys(want), ...Object.keys(have).filter((p) => (have[p] ?? []).length)]);
  const out = [];
  for (const phase of phases) {
    const w = want[phase] ?? [];
    const h = have[phase] ?? [];
    const diffs = drift(w, h.map(ruleOf));
    // drift looks only at what the definition names; a rule that has
    // more (a field this does not set) is a difference too.
    const extra = h.some((r, i) => w[i] && Object.keys(ruleOf(r)).some((k) => !(k in w[i])));
    if (diffs.length || extra || w.length !== h.length) out.push({ phase, rules: w, had: h.length, diffs });
  }
  return out;
}

// ---- Pages ------------------------------------------------------------------

/// One environment of the Pages project against its definition. `have`
/// is the project's deployment_configs[env]; `ids` resolves names:
/// { kv: {title: id}, durableObjects: {"script/class": id} }.
///
/// Returns { patch, lines, owner }: `patch` is the deployment_configs
/// entry a PATCH of the project takes (null deletes), `lines` say what
/// it changes, and `owner` what only the operator can do — a secret
/// missing, which this has no value for, with the oh command that sets
/// it. Secret values are never read: a secret is present or it is not.
export function pagesEnvPlan(want, have, ids) {
  const patch = {};
  const lines = [];
  const owner = [];
  const vars = have.env_vars ?? {};
  const envPatch = {};
  for (const [name, value] of Object.entries(want.vars)) {
    const h = vars[name];
    if (h?.type === 'plain_text' && h.value === value) continue;
    envPatch[name] = { type: 'plain_text', value };
    lines.push(h ? (h.type === 'plain_text' ? `set ${name}: ${JSON.stringify(h.value)} -> ${JSON.stringify(value)}` : `set ${name} as plain text (it is ${h.type})`) : `add ${name} = ${JSON.stringify(value)}`);
  }
  // oh sets a secret in every environment that lists it, so one command
  // puts right a secret missing from either (docs/reference/oh.md).
  const put = (name) => `\`./oh secret set ${name} --apply\``;
  for (const name of want.secrets) {
    const h = vars[name];
    if (h?.type === 'secret_text') continue;
    owner.push(h ? `${name} is ${h.type}, not a secret: set it with ${put(name)}` : `secret ${name} is not set: ${put(name)}`);
  }
  for (const [name, h] of Object.entries(vars)) {
    if (name in want.vars || want.secrets.includes(name)) continue;
    envPatch[name] = null;
    lines.push(`remove ${h.type === 'secret_text' ? 'secret' : 'variable'} ${name}, which is not defined`);
  }
  if (Object.keys(envPatch).length) patch.env_vars = envPatch;

  if (have.compatibility_date !== want.compatibilityDate) {
    patch.compatibility_date = want.compatibilityDate;
    lines.push(`compatibility date ${have.compatibility_date} -> ${want.compatibilityDate}`);
  }
  if (!sameList(want.compatibilityFlags, have.compatibility_flags ?? [])) {
    patch.compatibility_flags = want.compatibilityFlags;
    lines.push(`compatibility flags ${JSON.stringify(have.compatibility_flags ?? [])} -> ${JSON.stringify(want.compatibilityFlags)}`);
  }

  // Bindings, each kind by what names it.
  const kinds = [
    ['kv_namespaces', want.kv, (title) => ({ namespace_id: ids.kv[title] }), (h) => h.namespace_id, (title) => ids.kv[title] ?? `(no namespace "${title}")`],
    ['r2_buckets', want.r2, (name) => ({ name }), (h) => h.name, (name) => name],
    [
      'durable_object_namespaces',
      want.durableObjects,
      (d) => ({ namespace_id: ids.durableObjects[`${d.script}/${d.class}`] }),
      (h) => h.namespace_id,
      (d) => ids.durableObjects[`${d.script}/${d.class}`] ?? `(no ${d.class} in ${d.script})`,
    ],
    ['analytics_engine_datasets', want.analyticsEngine ?? {}, (dataset) => ({ dataset }), (h) => h.dataset, (d) => d],
  ];
  const known = new Set(kinds.map(([k]) => k));
  for (const [kind, wanted, make, idOf, target] of kinds) {
    const had = have[kind] ?? {};
    const kp = {};
    for (const [binding, what] of Object.entries(wanted)) {
      const t = target(what);
      if (had[binding] && idOf(had[binding]) === t) continue;
      kp[binding] = make(what);
      lines.push(`${had[binding] ? 'rebind' : 'bind'} ${binding} (${kind}) to ${typeof what === 'string' ? what : `${what.script}/${what.class}`}`);
    }
    for (const binding of Object.keys(had)) {
      if (binding in wanted) continue;
      kp[binding] = null;
      lines.push(`unbind ${binding} (${kind}), which is not defined`);
    }
    if (Object.keys(kp).length) patch[kind] = kp;
  }
  // Binding kinds the definition has no word for at all.
  const bindingKinds = ['d1_databases', 'services', 'queue_producers', 'ai_bindings', 'vectorize_bindings', 'hyperdrive_bindings', 'mtls_certificates', 'browsers'];
  for (const kind of bindingKinds) {
    if (known.has(kind)) continue;
    const had = have[kind] ?? {};
    if (!Object.keys(had).length) continue;
    patch[kind] = Object.fromEntries(Object.keys(had).map((b) => [b, null]));
    for (const b of Object.keys(had)) lines.push(`unbind ${b} (${kind}), which is not defined`);
  }
  return { patch, lines, owner };
}

/// The project's custom domains against the definition's, apex or
/// subdomain alike: `have` is the API's list ([{name, status}]). Returns
/// { add: [names], remove: [names], pending: [{name, status}] } — a
/// domain the API has but not yet active (its certificate or its
/// record still being checked) is the operator's to look at, not one to
/// add again.
export function pagesDomainsPlan(want, have) {
  const add = want.filter((name) => !have.some((d) => d.name === name));
  const remove = have.filter((d) => !want.includes(d.name)).map((d) => d.name);
  const pending = have.filter((d) => want.includes(d.name) && d.status !== 'active').map((d) => ({ name: d.name, status: d.status }));
  return { add, remove, pending };
}

/// The zone a hostname is in: the longest zone name it is, or ends in.
export function zoneOf(hostname, zoneNames) {
  return zoneNames.filter((z) => hostname === z || hostname.endsWith(`.${z}`)).sort((a, b) => b.length - a.length)[0] ?? null;
}

/// What a custom domain of the project needs and the definition does
/// not give it: a zone of ours to be in, and a proxied CNAME there to
/// the project's own address. Pages answers a domain only once its
/// record points at the project, so a domain without one is a domain
/// that never comes up. Lines, empty when all is well.
export function pagesDomainProblems(pages, zones) {
  const target = `${pages.project}.pages.dev`;
  const out = [];
  for (const name of pages.domains) {
    const zone = zoneOf(name, Object.keys(zones));
    if (!zone) {
      out.push(`${name} is in no zone defined here`);
      continue;
    }
    const record = zones[zone].dns.find((r) => r.name === name && r.type === 'CNAME');
    if (!record) out.push(`${name} has no CNAME in ${zone}`);
    else if (record.content !== target || !record.proxied) out.push(`${name}'s CNAME is ${record.content}${record.proxied ? '' : ' (not proxied)'}, not ${target} (proxied)`);
  }
  return out;
}

// ---- the relay's wrangler.toml -------------------------------------------

/// Enough TOML for a wrangler.toml: tables, arrays of tables, and values
/// that are strings, numbers, booleans, arrays and inline tables.
export function parseToml(text) {
  const root = {};
  let here = root;
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let line = stripComment(lines[i]).trim();
    if (!line) continue;
    let m;
    if ((m = line.match(/^\[\[\s*([\w.-]+)\s*\]\]$/))) {
      const parent = walk(root, m[1].split('.').slice(0, -1));
      const key = m[1].split('.').at(-1);
      (parent[key] ??= []).push((here = {}));
      continue;
    }
    if ((m = line.match(/^\[\s*([\w.-]+)\s*\]$/))) {
      here = walk(root, m[1].split('.'));
      continue;
    }
    // A value spread over lines: read on until its brackets close.
    while (!balanced(line) && i + 1 < lines.length) line += ' ' + stripComment(lines[++i]).trim();
    const eq = line.indexOf('=');
    if (eq < 0) throw new Error(`toml: cannot read "${line}"`);
    const key = line.slice(0, eq).trim().replace(/^"(.*)"$/, '$1');
    const [value, rest] = readValue(line.slice(eq + 1).trim());
    if (rest.trim()) throw new Error(`toml: trailing "${rest}" after ${key}`);
    here[key] = value;
  }
  return root;
}

const walk = (obj, path) => path.reduce((o, k) => (o[k] ??= {}), obj);

function stripComment(line) {
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    if (line[i] === '"' && line[i - 1] !== '\\') quoted = !quoted;
    if (line[i] === '#' && !quoted) return line.slice(0, i);
  }
  return line;
}

function balanced(s) {
  let depth = 0;
  let quoted = false;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '"' && s[i - 1] !== '\\') quoted = !quoted;
    if (quoted) continue;
    if (s[i] === '[' || s[i] === '{') depth++;
    if (s[i] === ']' || s[i] === '}') depth--;
  }
  return depth <= 0;
}

function readValue(s) {
  s = s.trimStart();
  if (s.startsWith('"')) {
    let i = 1;
    let out = '';
    for (; i < s.length && s[i] !== '"'; i++) {
      if (s[i] === '\\') {
        const c = s[++i];
        out += { n: '\n', t: '\t', '"': '"', '\\': '\\' }[c] ?? c;
      } else out += s[i];
    }
    return [out, s.slice(i + 1)];
  }
  if (s.startsWith('[')) {
    const out = [];
    s = s.slice(1).trimStart();
    while (!s.startsWith(']')) {
      const [v, rest] = readValue(s);
      out.push(v);
      s = rest.trimStart().replace(/^,/, '').trimStart();
    }
    return [out, s.slice(1)];
  }
  if (s.startsWith('{')) {
    const out = {};
    s = s.slice(1).trimStart();
    while (!s.startsWith('}')) {
      const m = s.match(/^([\w-]+|"[^"]*")\s*=\s*/);
      if (!m) throw new Error(`toml: cannot read "${s}"`);
      const [v, rest] = readValue(s.slice(m[0].length));
      out[m[1].replace(/^"(.*)"$/, '$1')] = v;
      s = rest.trimStart().replace(/^,/, '').trimStart();
    }
    return [out, s.slice(1)];
  }
  const m = s.match(/^(true|false|[+-]?\d[\d_]*(\.\d+)?)/);
  if (!m) throw new Error(`toml: cannot read value "${s}"`);
  const v = m[1] === 'true' ? true : m[1] === 'false' ? false : Number(m[1].replaceAll('_', ''));
  return [v, s.slice(m[1].length)];
}

/// The bindings a wrangler.toml declares, as the worker settings API
/// names them: [{name, type, ...what identifies it}].
export function wranglerBindings(toml) {
  const out = [];
  for (const d of toml.durable_objects?.bindings ?? []) out.push({ name: d.name, type: 'durable_object_namespace', class_name: d.class_name });
  for (const k of toml.kv_namespaces ?? []) out.push({ name: k.binding, type: 'kv_namespace', namespace_id: k.id });
  for (const r of toml.r2_buckets ?? []) out.push({ name: r.binding, type: 'r2_bucket', bucket_name: r.bucket_name });
  for (const e of toml.send_email ?? []) out.push({ name: e.name, type: 'send_email' });
  for (const a of toml.analytics_engine_datasets ?? []) out.push({ name: a.binding, type: 'analytics_engine', dataset: a.dataset });
  for (const s of toml.services ?? []) out.push({ name: s.binding, type: 'service', service: s.service });
  if (toml.version_metadata) out.push({ name: toml.version_metadata.binding, type: 'version_metadata' });
  if (toml.ai) out.push({ name: toml.ai.binding, type: 'ai' });
  for (const [name, text] of Object.entries(toml.vars ?? {})) out.push({ name, type: 'plain_text', text });
  return out;
}

/// The live relay against its wrangler.toml and the definition's few
/// additions. Every difference is the operator's (or a deploy's) to fix,
/// so this returns lines, not changes.
/// live = { settings, secrets: [names], domains: [{hostname, service, enabled}],
///          subdomain: {enabled}, namespaces: [{script, class}], containers: [{name, max_instances}] }
export function relayProblems(toml, relay, live) {
  const out = [];
  const name = toml.name;
  const s = live.settings;
  if (!s) return [`worker ${name} is not deployed`];
  if (s.compatibility_date !== toml.compatibility_date) out.push(`compatibility date is ${s.compatibility_date}, wrangler.toml says ${toml.compatibility_date}`);
  if (!sameList(s.compatibility_flags ?? [], toml.compatibility_flags ?? [])) out.push(`compatibility flags differ from wrangler.toml`);
  const obs = toml.observability?.enabled ?? false;
  if ((s.observability?.enabled ?? false) !== obs) out.push(`observability (Workers Logs) is ${s.observability?.enabled ? 'on' : 'off'}, wrangler.toml says ${obs ? 'on' : 'off'}`);
  const liveBindings = (s.bindings ?? []).filter((b) => b.type !== 'secret_text');
  for (const want of wranglerBindings(toml)) {
    const b = liveBindings.find((x) => x.name === want.name);
    if (!b) {
      out.push(`binding ${want.name} (${want.type}) is in wrangler.toml but not on the worker`);
      continue;
    }
    const diffs = drift(want, b);
    if (diffs.length) out.push(`binding ${want.name}: ${diffs.map(describe).join(', ')}`);
  }
  for (const b of liveBindings) {
    if (!wranglerBindings(toml).some((w) => w.name === b.name)) out.push(`binding ${b.name} (${b.type}) is on the worker but not in wrangler.toml`);
  }
  for (const secret of relay.secrets) {
    if (!live.secrets.includes(secret)) out.push(`secret ${secret} is not set: \`./oh secret set ${secret} --apply\``);
  }
  for (const secret of live.secrets) {
    if (!relay.secrets.includes(secret) && !(relay.optionalSecrets ?? []).includes(secret)) out.push(`secret ${secret} is set but not defined (infra/cloudflare.mjs, relay.secrets)`);
  }
  // Its addresses: the routes wrangler.toml gives, as custom domains.
  const routes = (toml.routes ?? []).filter((r) => r.custom_domain);
  for (const r of routes) {
    const d = live.domains.find((x) => x.hostname === r.pattern);
    if (!d) out.push(`custom domain ${r.pattern} is not attached`);
    else if (d.service !== name || d.enabled === false) out.push(`custom domain ${r.pattern} serves ${d.service}${d.enabled === false ? ' (disabled)' : ''}, not ${name}`);
  }
  for (const d of live.domains.filter((x) => x.service === name)) {
    if (!routes.some((r) => r.pattern === d.hostname)) out.push(`custom domain ${d.hostname} serves ${name} but is not in wrangler.toml`);
  }
  if ((live.subdomain?.enabled ?? false) !== relay.workersDev) out.push(`workers.dev address is ${live.subdomain?.enabled ? 'on' : 'off'}, should be ${relay.workersDev ? 'on' : 'off'} (workers_dev in wrangler.toml)`);
  // Every class the migrations made has its namespace.
  const classes = (toml.migrations ?? []).flatMap((m) => [...(m.new_sqlite_classes ?? []), ...(m.new_classes ?? [])]);
  for (const c of classes) {
    if (!live.namespaces.some((n) => n.script === name && n.class === c)) out.push(`no Durable Object namespace for ${c}`);
  }
  for (const c of toml.containers ?? []) {
    const app = live.containers.find((x) => x.name === `${name}-${c.class_name.toLowerCase()}`);
    if (!app) out.push(`container ${c.class_name} is not deployed`);
    else if (c.max_instances != null && app.max_instances !== c.max_instances) out.push(`container ${c.class_name} max_instances is ${app.max_instances}, wrangler.toml says ${c.max_instances}`);
  }
  return out;
}

// ---- Email Routing --------------------------------------------------------

/// The zone's routing against its definition. `have` = { settings, rules,
/// catchAll }, `destinations` = the account's addresses ({email, verified}).
/// `forwardTo(rule)` gives the address a forward should go to, or null
/// when it is not known here (the env var unset): then any verified
/// destination will do. Addresses are never put in a line.
export function emailRoutingPlan(want, have, destinations, forwardTo) {
  const lines = [];
  const owner = [];
  const rules = [];
  const enabled = have.settings?.enabled === true;
  if (want.enabled !== enabled) lines.push(`${want.enabled ? 'enable' : 'disable'} Email Routing`);
  if (!want.enabled) return { lines, owner, rules, catchAll: null };
  const verified = (address) => destinations.some((d) => d.email === address && d.verified);
  const literal = (r) => r.matchers?.length === 1 && r.matchers[0].type === 'literal' && r.matchers[0].field === 'to' ? r.matchers[0].value : null;
  const ours = (have.rules ?? []).filter((r) => !r.matchers?.some((m) => m.type === 'all'));
  for (const f of want.forwards) {
    const rule = ours.find((r) => literal(r) === f.to);
    // Where another address goes, for one that goes there too.
    const alike = f.sameAs ? ours.find((r) => literal(r) === f.sameAs)?.actions?.find((a) => a.type === 'forward')?.value?.[0] : null;
    const dest = forwardTo(f) ?? alike ?? null;
    const forward = rule?.actions?.find((a) => a.type === 'forward');
    const targets = forward?.value ?? [];
    if (!rule) {
      if (dest) {
        rules.push({ op: 'create', to: f.to, dest });
        lines.push(`create a rule forwarding ${f.to} to ${forwardTo(f) ? `$${f.destinationFrom}` : `where ${f.sameAs} goes`}`);
      } else owner.push(`no rule forwards ${f.to}: set ${f.destinationFrom} to where it should go, and run this again`);
    } else {
      if (dest && (targets.length !== 1 || targets[0] !== dest)) {
        rules.push({ op: 'update', id: rule.id, to: f.to, dest });
        lines.push(`point the rule for ${f.to} at $${f.destinationFrom} (it goes elsewhere now)`);
      } else if (!rule.enabled) {
        rules.push({ op: 'update', id: rule.id, to: f.to, dest: targets[0] });
        lines.push(`enable the rule forwarding ${f.to}`);
      }
      if (!dest && !targets.length) owner.push(`the rule for ${f.to} forwards nowhere: set ${f.destinationFrom}`);
    }
    const final = dest ?? targets[0];
    if (final && !verified(final)) {
      if (destinations.some((d) => d.email === final)) owner.push(`the destination for ${f.to} is not verified yet: open the link Cloudflare emailed it`);
      else lines.push(`add $${f.destinationFrom} as a destination address (Cloudflare emails it a link to verify)`);
    }
  }
  for (const r of ours) {
    if (want.forwards.some((f) => f.to === literal(r))) continue;
    rules.push({ op: 'delete', id: r.id });
    lines.push(`delete the routing rule for ${literal(r) ?? 'an address'}, which is not defined`);
  }
  let catchAll = null;
  if ((have.catchAll?.enabled ?? false) !== want.catchAll) {
    catchAll = { enabled: want.catchAll };
    lines.push(`${want.catchAll ? 'enable' : 'disable'} the catch-all rule`);
  }
  return { lines, owner, rules, catchAll };
}

// ---- budget alerts --------------------------------------------------------

/// Spend alerts against the definition: which thresholds to create,
/// which policies to fix or delete. `email` is OH_ALERT_EMAIL or null.
export function budgetPlan(want, have, email) {
  const ours = have.filter((p) => p.alert_type === 'billing_budget_alert' && p.description === want.description);
  const amount = (p) => Number(p.filters?.total_spend_dollars?.[0]);
  const create = [];
  const fix = [];
  for (const dollars of want.dollars) {
    const p = ours.find((x) => amount(x) === dollars);
    if (!p) {
      create.push(dollars);
      continue;
    }
    const emails = (p.mechanisms?.email ?? []).map((e) => e.id);
    const why = [];
    if (!p.enabled) why.push('disabled');
    if (p.name !== want.name(dollars)) why.push(`named "${p.name}"`);
    if (email ? emails.length !== 1 || emails[0] !== email : !emails.length) why.push(email ? 'emails someone other than $' + want.emailFrom : 'emails nobody');
    if (why.length) fix.push({ id: p.id, dollars, why });
  }
  const remove = ours.filter((p) => !want.dollars.includes(amount(p))).map((p) => ({ id: p.id, dollars: amount(p) }));
  return { create, fix, remove };
}

// ---- Stripe ----------------------------------------------------------------

/// Which mode a key is for, from its prefix.
export function keyMode(key) {
  const m = /^(sk|rk)_(live|test)_/.exec(key ?? '');
  return m ? { mode: m[2], restricted: m[1] === 'rk' } : null;
}

/// Stripe's form encoding, nested as it reads it: a[b][0]=c.
export function form(obj, prefix = '') {
  const out = [];
  const add = (k, v) => {
    if (v === undefined) return;
    if (v === null) out.push([k, '']);
    else if (Array.isArray(v)) v.forEach((x, i) => (isObject(x) || Array.isArray(x) ? out.push(...form(x, `${k}[${i}]`)) : out.push([`${k}[${i}]`, String(x)])));
    else if (isObject(v)) out.push(...form(v, k));
    else out.push([k, String(v)]);
  };
  if (prefix) {
    if (Array.isArray(obj)) obj.forEach((x, i) => add(`${prefix}[${i}]`, x));
    else for (const [k, v] of Object.entries(obj)) add(`${prefix}[${k}]`, v);
    return out;
  }
  for (const [k, v] of Object.entries(obj)) add(k, v);
  return out;
}
export const formBody = (obj) => new URLSearchParams(form(obj)).toString();

/// The price holding the lookup key against the definition. A price's
/// amount, currency and interval cannot change, so a difference in them
/// means a new price that takes the lookup key over; its tax behaviour
/// can be set once, from unspecified, which is an update of it instead
/// ({update: {tax_behavior}}).
export function pricePlan(want, price) {
  if (!price) return { create: true, why: 'no active price holds the lookup key', diffs: [] };
  const diffs = drift(
    { currency: want.currency, unit_amount: want.unitAmount, type: 'recurring', recurring: { interval: want.interval, interval_count: want.intervalCount }, tax_behavior: want.taxBehavior, active: true },
    price,
  );
  const settable = diffs.length === 1 && diffs[0].path === 'tax_behavior' && price.tax_behavior === 'unspecified';
  if (settable) return { create: false, update: { tax_behavior: want.taxBehavior }, why: describe(diffs[0]), diffs };
  return { create: diffs.length > 0, why: diffs.map(describe).join(', '), diffs };
}

/// Webhooks to this app's hosts against the definition.
export function webhookPlan(want, have, hosts) {
  const host = (u) => {
    try {
      return new URL(u).hostname;
    } catch {
      return null;
    }
  };
  const ours = have.filter((e) => hosts.some((h) => host(e.url) === h || host(e.url)?.endsWith(`.${h}`)));
  const update = [];
  const owner = [];
  const used = new Set();
  const pathOf = (u) => {
    try {
      return new URL(u).pathname;
    } catch {
      return null;
    }
  };
  for (const w of want) {
    // The endpoint at this address, or else one of ours at the same path
    // on another of our hosts: moved, not made again, so its signing
    // secret — which only the dashboard shows, once — stays the one the
    // Pages project holds.
    const e = ours.find((x) => x.url === w.url) ?? ours.find((x) => !used.has(x.id) && pathOf(x.url) === pathOf(w.url));
    if (!e) {
      // Its signing secret is shown once, at creation, and has to go to
      // the Pages project: that is done by hand, not by a script that
      // would hold the secret.
      owner.push(`no webhook to ${w.url}: create it in the dashboard with ${w.events.length} events and API version ${w.apiVersion}, and set its signing secret as OH_STRIPE_WEBHOOK_SECRET on the Pages project`);
      continue;
    }
    used.add(e.id);
    const changes = {};
    if (e.url !== w.url) changes.url = w.url;
    if (!sameList(w.events, e.enabled_events ?? [])) changes.enabled_events = w.events;
    if (e.status !== 'enabled') changes.disabled = false;
    if (Object.keys(changes).length) update.push({ id: e.id, url: w.url, changes, had: { url: e.url, events: e.enabled_events, status: e.status } });
    if (w.apiVersion && e.api_version !== w.apiVersion) owner.push(`webhook to ${w.url} is on API version ${e.api_version}, defined as ${w.apiVersion}: Stripe sets it only at creation, so make a new endpoint (and its secret) to change it`);
  }
  const remove = ours.filter((e) => !used.has(e.id)).map((e) => ({ id: e.id, url: e.url }));
  return { update, remove, owner };
}

/// The portal configuration's differences, and the body that fixes them.
export function portalPlan(want, have) {
  if (!have) return { create: true, diffs: [] };
  const diffs = drift(want, have);
  return { create: false, diffs };
}
