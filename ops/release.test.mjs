// Releasing (ops/release.mjs): what the web build is compiled with;
// oh verify's proof that Link sells our checkout (sellsThroughLink), a
// Managed Payments session made as the service makes one and expired
// before anybody could pay with it; and what verify takes as production
// matching its definitions.
//
//   node --test ops/*.test.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { Failed, readConfig, relayHost, root } from './env.mjs';
import { NO_DEVICE, sellsThroughLink, verify } from './release.mjs';
import { stripe as stripeDefinition } from '../infra/stripe.mjs';
import { appDefines, configFor } from '../service/functions/deployment.mjs';
import { checkoutFields } from '../service/functions/stripe.mjs';

test('the web build is compiled with what the config names, whatever the environment holds', async () => {
  const config = await readConfig();
  // What the house and the local rig read, left set in the shell.
  const stray = { OH_SERVICE_KEY: 'a'.repeat(64), OH_HOUSE_KEY: 'b'.repeat(64), OH_RELAYS: 'ws://127.0.0.1:7448/{tag}', OH_GOOGLE_CLIENT_ID: 'x', OH_APPLE_SERVICE_ID: 'y' };
  const defines = (deployment) => {
    const out = join(mkdtempSync(join(tmpdir(), 'defines-')), 'defines.json');
    const made = spawnSync(process.execPath, [join(root, 'app/tool/defines.mjs'), out, deployment], { env: { ...process.env, ...stray }, encoding: 'utf8' });
    assert.equal(made.status, 0, made.stderr);
    return JSON.parse(readFileSync(out, 'utf8'));
  };
  // The config's values, and the build's identity, which is git's and
  // the day's: never the environment's.
  const identity = (made) => {
    const { OH_BUILD_TAG, OH_BUILD_DATE, OH_UPDATE_CHECK, ...rest } = made;
    assert.match(OH_BUILD_TAG, /^[0-9a-f]{7,}\+?$/);
    assert.equal(OH_BUILD_DATE, new Date().toISOString().slice(0, 10));
    assert.equal(OH_UPDATE_CHECK, 'true');
    return rest;
  };
  assert.deepEqual(identity(defines('production')), appDefines(config));
  assert.deepEqual(identity(defines('preview')), { ...appDefines(configFor(config, 'preview')), OH_RELAYS: `wss://${await relayHost('preview')}/{tag}` });
  // And deploy.sh gives the build nothing else.
  const script = readFileSync(join(root, 'deploy.sh'), 'utf8');
  assert.match(script, /--dart-define-from-file=build\/defines\.json/);
  assert.doesNotMatch(script, /--dart-define=/);
});

/// Stripe as the operator's key sees it: the price holding the lookup
/// key ([price]), and a session made, or refused as [refuse] says.
function stripeWith({ price = { id: 'price_1' }, refuse = null } = {}) {
  const calls = [];
  return {
    calls,
    get: async (path) => {
      calls.push(['GET', path]);
      return { data: price ? [price] : [] };
    },
    post: async (path, fields) => {
      calls.push(['POST', path, fields]);
      if (path === '/checkout/sessions' && refuse) throw new Failed(refuse);
      return path === '/checkout/sessions' ? { id: 'cs_live_1' } : { id: 'cs_live_1', status: 'expired' };
    },
  };
}

test('a checkout through Link: made as the service makes one, for no device, and expired at once', async () => {
  const stripe = stripeWith();
  assert.equal(await sellsThroughLink(stripe, 'https://play.openhearts.game'), true);
  const [lookup, made, expired] = stripe.calls;
  assert.equal(lookup[0], 'GET');
  assert.equal(new URLSearchParams(lookup[1].split('?')[1]).get('lookup_keys[]'), stripeDefinition.price.lookupKey);
  const back = 'https://play.openhearts.game/play/';
  assert.deepEqual(made, ['POST', '/checkout/sessions', checkoutFields(NO_DEVICE, 'price_1', back, back, 'en')], 'every field the service sends, branding and the terms box with them');
  assert.equal(made[2]['managed_payments[enabled]'], 'true');
  assert.equal(made[2]['metadata[key]'], '0'.repeat(64), 'no device could be bound to it');
  assert.deepEqual(expired, ['POST', '/checkout/sessions/cs_live_1/expire', undefined], 'expired before anybody could pay');
  assert.equal(stripe.calls.length, 3);
});

test('a checkout through Link: Stripe refusing it, or no price, says why and expires nothing', async () => {
  const refused = stripeWith({ refuse: 'Stripe said 400 to POST /checkout/sessions: Managed Payments is not enabled' });
  await assert.rejects(sellsThroughLink(refused, 'https://play.openhearts.game'), /Managed Payments is not enabled/);
  assert.ok(!refused.calls.some(([, path]) => path.endsWith('/expire')));
  await assert.rejects(sellsThroughLink(stripeWith({ price: null }), 'https://play.openhearts.game'), /no active price holds the lookup key openhearts_annual/);
});

test('oh verify passes the definitions only with nothing to change and nothing to fix by hand', async () => {
  /// What verify says of the definitions when infra/apply.mjs ends with
  /// [infra] and observability/apply.mjs with [newrelic].
  const said = async (infra, newrelic) => {
    const lines = [];
    const ctx = {
      env: { CLOUDFLARE_API_TOKEN: 't', CLOUDFLARE_ACCOUNT_ID: 'a', STRIPE_API_KEY: 'rk_live_x', NEW_RELIC_API_KEY: 'k', NEW_RELIC_ACCOUNT_ID: '1', NEW_RELIC_REGION: 'US' },
      config: async () => ({ appOrigin: 'https://play.example' }),
      fetch: async () => new Response('{}'),
      log: (line) => lines.push(line),
      stripe: () => {
        throw new Error('no Stripe here');
      },
      capture: async (command, args) => {
        if (command !== 'node') return { code: 0, out: 'abc1234\n' };
        return { code: 0, out: args[0].endsWith('infra/apply.mjs') ? infra : newrelic };
      },
    };
    await assert.rejects(verify(ctx), Failed, "production's other answers here fail");
    return lines.filter((l) => /apply\.mjs: /.test(l));
  };
  assert.deepEqual(await said('ok      Pages\n0 change(s), 0 by hand; --apply to make the changes\n', 'ok      monitors\n0 change(s); --apply to make them\n'), [
    'ok     infra/apply.mjs: 0 change(s), 0 by hand; --apply to make the changes',
    'ok     observability/apply.mjs: 0 change(s); --apply to make them',
  ]);
  const byHand = await said('by hand: Pages open-hearts production: secret OH_ID_HMAC is not set\n0 change(s), 1 by hand; --apply to make the changes\n', '1 change(s); --apply to make them\n');
  assert.deepEqual(byHand, ['FAILED infra/apply.mjs: 0 change(s), 1 by hand; --apply to make the changes', 'FAILED observability/apply.mjs: 1 change(s); --apply to make them']);
});
