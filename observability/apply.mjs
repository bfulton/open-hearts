// Makes the New Relic account match monitoring.mjs, for this app and
// nothing else in the account.
//
//   node observability/apply.mjs            what would change, and stop
//   node observability/apply.mjs --apply    change it
//
// Needs NEW_RELIC_API_KEY (a User key), NEW_RELIC_ACCOUNT_ID and
// NEW_RELIC_REGION (US or EU) in the environment, and OH_ALERT_EMAIL for
// who is told. Talks to NerdGraph, New Relic's GraphQL API.
//
// What it owns is what carries the app's key: monitors tagged
// `app: <key>` and named with the app's prefix, the policy, destination,
// channel and workflow named with it, and the workload of its name. A
// monitor of ours that is no longer in the definition is deleted;
// nothing without our tag is read, let alone touched.
//
// Each monitor and the condition carry a short digest of what defined
// them (the `definition` tag, the end of the description), so a run
// changes only what the definition changed. New Relic's search lags a
// minute behind what is created, so a second --apply straight after a
// first could create a monitor twice; run it a minute later instead.

import { createHash } from 'node:crypto';

import { readFile, writeFile } from 'node:fs/promises';

import { alerts, app, browser, synthetics } from './monitoring.mjs';

const write = process.argv.includes('--apply');
const key = process.env.NEW_RELIC_API_KEY;
const account = Number(process.env.NEW_RELIC_ACCOUNT_ID);
const region = (process.env.NEW_RELIC_REGION ?? 'US').toUpperCase();
if (!key || !account) {
  console.error('apply: needs NEW_RELIC_API_KEY and NEW_RELIC_ACCOUNT_ID');
  process.exit(2);
}
const endpoint = region === 'EU' ? 'https://api.eu.newrelic.com/graphql' : 'https://api.newrelic.com/graphql';

const prefix = `${app.name}: `;
const managed = [
  { key: 'app', values: [app.key] },
  { key: 'managed-by', values: [`${app.key}/observability`] },
];

/// A short digest of what defines a thing: a change to it is a change.
const digest = (thing) => createHash('sha256').update(JSON.stringify(thing)).digest('hex').slice(0, 12);

async function graph(query, variables = {}) {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'API-Key': key, 'content-type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  });
  const out = await res.json();
  if (out.errors?.length) throw new Error(out.errors.map((e) => e.message).join('; '));
  return out.data;
}

/// A mutation's own errors, which NerdGraph returns as data.
function check(what, result) {
  const errors = result?.errors ?? (result?.error ? [result.error] : []);
  if (errors?.length) throw new Error(`${what}: ${errors.map((e) => e.description ?? e.details ?? JSON.stringify(e)).join('; ')}`);
  return result;
}

const plan = [];
const say = (line) => {
  plan.push(line);
  console.log(`${write ? '' : 'would '}${line}`);
};

// ---- synthetics ---------------------------------------------------------

async function ourMonitors() {
  const data = await graph(
    `query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid name
      tags { key values } } } } } }`,
    { q: `domain = 'SYNTH' AND type = 'MONITOR' AND accountId = ${account} AND tags.app = '${app.key}'` },
  );
  return data.actor.entitySearch.results.entities;
}

function monitorInput(m) {
  const input = {
    name: prefix + m.name,
    uri: m.uri,
    period: synthetics.period,
    status: 'ENABLED',
    locations: { public: synthetics.locations },
    tags: managed,
    advancedOptions: {
      responseValidationText: m.expect,
      // A GET, so the answer's text can be checked.
      shouldBypassHeadRequest: true,
      useTlsValidation: true,
      redirectIsFailure: false,
    },
  };
  input.tags = [...managed, { key: 'definition', values: [digest(input)] }];
  return input;
}

const definitionOf = (entity) => entity.tags?.find((t) => t.key === 'definition')?.values?.[0];

async function applySynthetics() {
  const have = await ourMonitors();
  const wanted = synthetics.monitors.map(monitorInput);
  for (const want of wanted) {
    const found = have.find((e) => e.name === want.name);
    if (!found) {
      say(`create monitor "${want.name}" on ${want.uri}`);
      if (write) {
        const r = await graph(
          `mutation($a: Int!, $m: SyntheticsCreateSimpleMonitorInput!) {
            syntheticsCreateSimpleMonitor(accountId: $a, monitor: $m) { monitor { guid } errors { type description } } }`,
          { a: account, m: want },
        );
        check(want.name, r.syntheticsCreateSimpleMonitor);
      }
    } else if (definitionOf(found) !== want.tags.at(-1).values[0]) {
      say(`update monitor "${want.name}"`);
      if (write) {
        const r = await graph(
          `mutation($g: EntityGuid!, $m: SyntheticsUpdateSimpleMonitorInput!) {
            syntheticsUpdateSimpleMonitor(guid: $g, monitor: $m) { errors { type description } } }`,
          { g: found.guid, m: want },
        );
        check(want.name, r.syntheticsUpdateSimpleMonitor);
      }
    }
  }
  for (const gone of have.filter((e) => !wanted.some((w) => w.name === e.name))) {
    say(`delete monitor "${gone.name}", which is no longer defined`);
    if (write) {
      await graph(`mutation($g: EntityGuid!) { syntheticsDeleteMonitor(guid: $g) { deletedGuid } }`, { g: gone.guid });
    }
  }
}

// ---- alerts -------------------------------------------------------------

const policyName = prefix + alerts.policy;
const conditionName = `${prefix}a monitor failing`;
const notifyName = `${prefix}email`;

async function applyPolicy() {
  const data = await graph(
    `query($a: Int!, $n: String!) { actor { account(id: $a) { alerts { policiesSearch(searchCriteria: { name: $n }) { policies { id name } } } } } }`,
    { a: account, n: policyName },
  );
  const found = data.actor.account.alerts.policiesSearch.policies.find((p) => p.name === policyName);
  if (found) return found.id;
  say(`create alert policy "${policyName}"`);
  if (!write) return null;
  const r = await graph(
    `mutation($a: Int!, $p: AlertsPolicyInput!) { alertsPolicyCreate(accountId: $a, policy: $p) { id } }`,
    { a: account, p: { name: policyName, incidentPreference: 'PER_CONDITION_AND_TARGET' } },
  );
  return r.alertsPolicyCreate.id;
}

function conditionInput() {
  const names = synthetics.monitors.map((m) => `'${(prefix + m.name).replaceAll("'", "\\'")}'`).join(', ');
  return {
    name: conditionName,
    description: `A ${app.name} monitor failing from ${alerts.failingFrom} locations for ${alerts.forSeconds / 60} minutes (observability/monitoring.mjs).`,
    enabled: true,
    nrql: {
      query: `SELECT filter(count(*), WHERE result = 'FAILED') FROM SyntheticCheck WHERE monitorName IN (${names}) FACET monitorName`,
    },
    signal: { aggregationWindow: 60, aggregationMethod: 'EVENT_FLOW', aggregationDelay: 120, fillOption: 'STATIC', fillValue: 0 },
    terms: [
      {
        operator: 'ABOVE_OR_EQUALS',
        priority: 'CRITICAL',
        threshold: alerts.failingFrom,
        thresholdDuration: alerts.forSeconds,
        thresholdOccurrences: 'ALL',
      },
    ],
    violationTimeLimitSeconds: 86400,
  };
}

/// The condition with its digest at the end of its description.
function conditionWanted() {
  const c = conditionInput();
  return { ...c, description: `${c.description} [${digest(c)}]` };
}

async function applyCondition(policyId) {
  const want = conditionWanted();
  if (policyId === null) {
    say(`create condition "${conditionName}"`);
    return;
  }
  const data = await graph(
    `query($a: Int!, $p: ID!, $n: String!) { actor { account(id: $a) { alerts {
      nrqlConditionsSearch(searchCriteria: { policyId: $p, name: $n }) { nrqlConditions { id name description } } } } } }`,
    { a: account, p: String(policyId), n: conditionName },
  );
  const found = data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions.find((c) => c.name === conditionName);
  if (found?.description === want.description) return;
  say(`${found ? 'update' : 'create'} condition "${conditionName}"`);
  if (!write) return;
  if (found) {
    await graph(
      `mutation($a: Int!, $id: ID!, $c: AlertsNrqlConditionUpdateStaticInput!) {
        alertsNrqlConditionStaticUpdate(accountId: $a, id: $id, condition: $c) { id } }`,
      { a: account, id: found.id, c: want },
    );
  } else {
    await graph(
      `mutation($a: Int!, $p: ID!, $c: AlertsNrqlConditionStaticInput!) {
        alertsNrqlConditionStaticCreate(accountId: $a, policyId: $p, condition: $c) { id } }`,
      { a: account, p: String(policyId), c: want },
    );
  }
}

async function applyNotifications(policyId) {
  const email = process.env[alerts.emailFrom];
  if (!email || !email.includes('@')) throw new Error(`set ${alerts.emailFrom} to the address alerts go to`);
  // Where: an email destination.
  const dests = await graph(
    `query($a: Int!, $n: String!) { actor { account(id: $a) { aiNotifications {
      destinations(filters: { name: $n }) { entities { id name properties { key value } } } } } } }`,
    { a: account, n: notifyName },
  );
  let dest = dests.actor.account.aiNotifications.destinations.entities.find((d) => d.name === notifyName);
  // Until the address is verified (New Relic emails it a link) it is
  // held as `link_sent_email` rather than `email`.
  const sameAddress = dest?.properties?.some((p) => (p.key === 'email' || p.key === 'link_sent_email') && p.value === email);
  if (!dest || !sameAddress) {
    say(`${dest ? 'update' : 'create'} email destination "${notifyName}"`);
    if (write) {
      const input = { type: 'EMAIL', name: notifyName, properties: [{ key: 'email', value: email }] };
      if (dest) {
        const r = await graph(
          `mutation($a: Int!, $id: ID!, $d: AiNotificationsDestinationUpdate!) {
            aiNotificationsUpdateDestination(accountId: $a, destinationId: $id, destination: $d) { destination { id } error { ... on AiNotificationsResponseError { description } } } }`,
          { a: account, id: dest.id, d: { name: notifyName, properties: input.properties } },
        );
        check('destination', r.aiNotificationsUpdateDestination);
      } else {
        const r = await graph(
          `mutation($a: Int!, $d: AiNotificationsDestinationInput!) {
            aiNotificationsCreateDestination(accountId: $a, destination: $d) { destination { id } error { ... on AiNotificationsResponseError { description } } } }`,
          { a: account, d: input },
        );
        dest = check('destination', r.aiNotificationsCreateDestination).destination;
      }
    }
  }
  // How: an email channel through it.
  const chans = await graph(
    `query($a: Int!, $n: String!) { actor { account(id: $a) { aiNotifications {
      channels(filters: { name: $n }) { entities { id name } } } } } }`,
    { a: account, n: notifyName },
  );
  let channel = chans.actor.account.aiNotifications.channels.entities.find((c) => c.name === notifyName);
  if (!channel) {
    say(`create email channel "${notifyName}"`);
    if (write && dest) {
      const r = await graph(
        `mutation($a: Int!, $c: AiNotificationsChannelInput!) {
          aiNotificationsCreateChannel(accountId: $a, channel: $c) { channel { id } error { ... on AiNotificationsResponseError { description } } } }`,
        {
          a: account,
          c: { type: 'EMAIL', name: notifyName, destinationId: dest.id, product: 'IINT', properties: [{ key: 'subject', value: `${app.name}: {{ issueTitle }}` }] },
        },
      );
      channel = check('channel', r.aiNotificationsCreateChannel).channel;
    }
  }
  // When: every issue from this app's policy, and no other.
  const flows = await graph(
    `query($a: Int!, $n: String!) { actor { account(id: $a) { aiWorkflows {
      workflows(filters: { name: $n }) { entities { id name } } } } } }`,
    { a: account, n: notifyName },
  );
  const flow = flows.actor.account.aiWorkflows.workflows.entities.find((w) => w.name === notifyName);
  if (!flow) {
    say(`create workflow "${notifyName}" for the policy's issues`);
    if (write && channel && policyId !== null) {
      const r = await graph(
        `mutation($a: Int!, $w: AiWorkflowsCreateWorkflowInput!) {
          aiWorkflowsCreateWorkflow(accountId: $a, createWorkflowData: $w) { workflow { id } errors { type description } } }`,
        {
          a: account,
          w: {
            name: notifyName,
            workflowEnabled: true,
            destinationsEnabled: true,
            enrichmentsEnabled: false,
            mutingRulesHandling: 'NOTIFY_ALL_ISSUES',
            issuesFilter: {
              name: notifyName,
              type: 'FILTER',
              predicates: [{ attribute: 'labels.policyIds', operator: 'EXACTLY_MATCHES', values: [String(policyId)] }],
            },
            destinationConfigurations: [{ channelId: channel.id, notificationTriggers: ['ACTIVATED', 'CLOSED'] }],
          },
        },
      );
      check('workflow', r.aiWorkflowsCreateWorkflow);
    }
  }
}

// ---- the browser -------------------------------------------------------

const browserName = prefix + browser.name;
const browserSettings = {
  browserMonitoring: { privacy: { cookiesEnabled: false }, distributedTracing: { enabled: false } },
  sessionReplay: { enabled: false, autoStart: false },
  sessionTrace: { enabled: false },
};

async function applyBrowser() {
  const found = await graph(
    `query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid name tags { key values } } } } } }`,
    { q: `domain = 'BROWSER' AND type = 'APPLICATION' AND accountId = ${account} AND name = '${browserName}'` },
  );
  let guid = found.actor.entitySearch.results.entities.find((e) => e.name === browserName)?.guid ?? null;
  for (const old of guid ? [] : browser.formerly ?? []) {
    const was = await graph(
      `query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid name tags { key values } } } } } }`,
      { q: `domain = 'BROWSER' AND type = 'APPLICATION' AND accountId = ${account} AND name = '${prefix + old}' AND tags.app = '${app.key}'` },
    );
    const e = was.actor.entitySearch.results.entities.find((x) => x.name === prefix + old);
    if (!e) continue;
    // New Relic renames APM apps only; a browser app under an old name is
    // deleted, with what it had collected, and made again under the new.
    say(`delete browser app "${prefix + old}" to make it again as "${browserName}" (browser apps cannot be renamed)`);
    if (write) {
      await graph(`mutation($g: EntityGuid!) { agentApplicationDelete(guid: $g) { success } }`, { g: e.guid });
    }
    break;
  }
  if (!guid) {
    say(`create browser app "${browserName}" (no cookies, no session replay, no session traces)`);
    if (!write) return;
    const r = await graph(
      `mutation($a: Int!, $n: String!, $s: AgentApplicationBrowserSettingsInput) {
        agentApplicationCreateBrowser(accountId: $a, name: $n, settings: $s) { guid } }`,
      { a: account, n: browserName, s: { cookiesEnabled: false, distributedTracingEnabled: false, loaderType: browser.loader } },
    );
    guid = r.agentApplicationCreateBrowser.guid;
    await graph(
      `mutation($g: EntityGuid!, $t: [TaggingTagInput!]!) { taggingAddTagsToEntity(guid: $g, tags: $t) { errors { message } } }`,
      { g: guid, t: managed },
    );
  }
  // Settings every time: they are cheap, and the loader below has to
  // reflect them.
  if (write) {
    await graph(
      `mutation($g: EntityGuid!, $s: AgentApplicationSettingsUpdateInput!) { agentApplicationSettingsUpdate(guid: $g, settings: $s) { guid } }`,
      { g: guid, s: browserSettings },
    );
  }
  // A browser app just made has no loader for a minute or two.
  let loader = null;
  for (let tries = 0; tries < 24 && !loader; tries++) {
    if (tries) await new Promise((r) => setTimeout(r, 5000));
    const props = await graph(
      `query($g: EntityGuid!) { actor { entity(guid: $g) { ... on BrowserApplicationEntity { browserProperties { jsLoaderScript } } } } }`,
      { g: guid },
    );
    loader = props.actor.entity?.browserProperties?.jsLoaderScript ?? null;
  }
  if (!loader) throw new Error('browser: New Relic gave no loader script');
  // And off in the page itself, not only in New Relic's settings: what
  // the page may do is decided here, where it is read.
  const script = loader
    .replace(/^\s*<script[^>]*>/i, '')
    .replace(/<\/script>\s*$/i, '')
    .replace('NREUM.init={', 'NREUM.init={session_replay:{enabled:false},session_trace:{enabled:false},');
  if (!script.includes('session_trace:{enabled:false}')) throw new Error('browser: the loader is not the shape expected; look at it');
  const file = [
    '// New Relic Browser (observability/monitoring.mjs, `browser`), written by',
    '// observability/apply.mjs: run it again rather than editing this. Only on',
    `// ${browser.onlyOn}, so a fork or a local build reports nothing to us.`,
    `if (location.hostname === ${JSON.stringify(browser.onlyOn)}) {`,
    script.trim(),
    '}',
    '',
  ].join('\n');
  const out = new URL(`../${browser.out}`, import.meta.url);
  const was = await readFile(out, 'utf8').catch(() => null);
  if (was === file) return;
  say(`write ${browser.out} with the browser app's loader`);
  if (write) await writeFile(out, file);
}

// ---- the workload ------------------------------------------------------

async function applyWorkload() {
  const data = await graph(`query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid name } } } } }`, {
    q: `type = 'WORKLOAD' AND accountId = ${account} AND name = '${app.name}'`,
  });
  if (data.actor.entitySearch.results.entities.some((e) => e.name === app.name)) return;
  say(`create workload "${app.name}" of everything tagged app: ${app.key}`);
  if (!write) return;
  await graph(
    `mutation($a: Int!, $w: WorkloadCreateInput!) { workloadCreate(accountId: $a, workload: $w) { guid } }`,
    { a: account, w: { name: app.name, entitySearchQueries: [{ query: `tags.app = '${app.key}'` }] } },
  );
}

await applySynthetics();
const policyId = await applyPolicy();
await applyCondition(policyId);
await applyNotifications(policyId);
await applyBrowser();
await applyWorkload();
console.log(write ? `applied: ${plan.length} change(s)` : `${plan.length} change(s); --apply to make them`);
