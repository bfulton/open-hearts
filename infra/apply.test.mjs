// The scripts that make the accounts match their definitions
// (infra/apply.mjs, observability/apply.mjs), run as `oh infra` and
// `oh verify` run them, with no network: each loads whole, every
// import found, and stops before asking anything when its credentials
// are not set; and Stripe is asked in the webhook's API version.
//
//   node --test infra/*.test.mjs

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { stripe } from './stripe.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));

/// [script] run with [args] and nothing in its environment but PATH and
/// [env]: {code, out}.
const run = (script, args = [], env = {}, node = []) => {
  const done = spawnSync(process.execPath, [...node, join(root, script), ...args], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });
  return { code: done.status, out: `${done.stdout}${done.stderr}` };
};

test('without credentials, each script loads whole and stops before asking anything', () => {
  const cases = [
    ['infra/apply.mjs', [], /^apply: Cloudflare needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID$/m],
    ['infra/apply.mjs', ['--only', 'stripe'], /^apply: Stripe needs STRIPE_API_KEY/m],
    ['observability/apply.mjs', [], /^apply: needs NEW_RELIC_API_KEY and NEW_RELIC_ACCOUNT_ID$/m],
  ];
  for (const [script, args, said] of cases) {
    const { code, out } = run(script, args);
    assert.equal(code, 2, `${script} ${args.join(' ')}: ${out}`);
    assert.match(out, said);
  }
});

test("infra reads Stripe in the webhook's API version, as the service does, not the account's default", () => {
  // Stripe stood in for by a fetch that notes each call and answers
  // that there is nothing.
  const dir = mkdtempSync(join(tmpdir(), 'stripe-'));
  const asked = join(dir, 'asked');
  writeFileSync(asked, '');
  const stand = join(dir, 'stand.mjs');
  writeFileSync(stand, `import { appendFileSync } from 'node:fs';\nglobalThis.fetch = async (url, init = {}) => {\n  appendFileSync(${JSON.stringify(asked)}, JSON.stringify({ url: String(url), headers: init.headers }) + '\\n');\n  return Response.json({ data: [] });\n};\n`);
  const { code, out } = run('infra/apply.mjs', ['--only', 'stripe'], { STRIPE_API_KEY: 'rk_live_x' }, ['--import', pathToFileURL(stand).href]);
  assert.equal(code, 0, out);
  const calls = readFileSync(asked, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(calls.length >= 3, out);
  for (const { url, headers } of calls) {
    assert.ok(url.startsWith('https://api.stripe.com/v1/'), url);
    assert.equal(headers['stripe-version'], stripe.webhooks[0].apiVersion, url);
  }
});
