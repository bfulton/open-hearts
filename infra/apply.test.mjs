// The scripts that make the accounts match their definitions
// (infra/apply.mjs, observability/apply.mjs), run as `oh infra` and
// `oh verify` run them, with no network: each loads whole, every
// import found, and stops before asking anything when its credentials
// are not set; Stripe is asked in the webhook's API version; and a
// stripePrice that is a price id is refused before Stripe is asked.
//
//   node --test infra/*.test.mjs

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { stripe } from './stripe.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));

/// [script] (from the repository's root, or an absolute path) run with
/// [args] and nothing in its environment but PATH and [env]: {code, out}.
const run = (script, args = [], env = {}, node = []) => {
  const done = spawnSync(process.execPath, [...node, resolve(root, script), ...args], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });
  return { code: done.status, out: `${done.stdout}${done.stderr}` };
};

/// A preload, written into [dir], that stands in for Stripe: a fetch
/// that notes each call's URL and headers in the file at [asked], and
/// answers that there is nothing.
const standInFor = (dir, asked) => {
  const stand = join(dir, 'stand.mjs');
  writeFileSync(asked, '');
  writeFileSync(stand, `import { appendFileSync } from 'node:fs';\nglobalThis.fetch = async (url, init = {}) => {\n  appendFileSync(${JSON.stringify(asked)}, JSON.stringify({ url: String(url), headers: init.headers }) + '\\n');\n  return Response.json({ data: [] });\n};\n`);
  return pathToFileURL(stand).href;
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
  const { code, out } = run('infra/apply.mjs', ['--only', 'stripe'], { STRIPE_API_KEY: 'rk_live_x' }, ['--import', standInFor(dir, asked)]);
  assert.equal(code, 0, out);
  const calls = readFileSync(asked, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(calls.length >= 3, out);
  for (const { url, headers } of calls) {
    assert.ok(url.startsWith('https://api.stripe.com/v1/'), url);
    assert.equal(headers['stripe-version'], stripe.webhooks[0].apiVersion, url);
  }
});

test('infra refuses a stripePrice that is a price id, before asking Stripe anything', () => {
  // The service takes a price id there, but infra keeps the price under
  // its lookup key, and would make a second price under the id. A copy
  // of infra/ beside a config naming the price by its id, with Stripe
  // stood in for.
  const dir = mkdtempSync(join(tmpdir(), 'price-id-'));
  cpSync(join(root, 'infra'), join(dir, 'infra'), { recursive: true });
  mkdirSync(join(dir, 'config'));
  const config = JSON.parse(readFileSync(join(root, 'config', 'openhearts.json'), 'utf8'));
  writeFileSync(join(dir, 'config', 'openhearts.json'), JSON.stringify({ ...config, stripePrice: 'price_1ULw2d5GXiRLIecgFYXHOchW' }));
  const asked = join(dir, 'asked');
  const { code, out } = run(join(dir, 'infra', 'apply.mjs'), ['--only', 'stripe'], { STRIPE_API_KEY: 'rk_live_x' }, ['--import', standInFor(dir, asked)]);
  assert.equal(code, 2, out);
  assert.match(out, /^apply: stripePrice in config\/openhearts\.json is a price id \(price_1ULw2d5GXiRLIecgFYXHOchW\); infra keeps the price under its lookup key/m);
  assert.equal(readFileSync(asked, 'utf8'), '', 'Stripe asked nothing');
});
