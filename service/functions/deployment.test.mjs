import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { appDefines, configEnv, withConfig } from './deployment.mjs';

const committed = JSON.parse(readFileSync(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));

test('the committed configuration is the one the service and the builds expect', () => {
  assert.match(committed.serviceKey, /^[0-9a-f]{64}$/);
  assert.match(committed.turnKeyId, /^[0-9a-f]{32}$/);
  assert.equal(committed.apple.bundleId, 'game.openhearts');
  assert.equal(committed.google.package, 'game.openhearts');
});

test('the relay holds devices to the same service key the builds and the worker name', () => {
  // The relay carries a device only on an activation that key signed
  // (service/do/relay.mjs, serviceGate): one out of step with the
  // service would carry nobody.
  // It reads the one file; a copy in its own settings would be a second
  // place to change, and one would be forgotten.
  const relay = readFileSync(new URL('../do/worker.mjs', import.meta.url), 'utf8');
  assert.match(relay, /^import config from '\.\.\/\.\.\/config\/openhearts\.json';$/m);
  assert.match(relay, /this\.env = withConfig\(env, config\)/);
  assert.match(relay, /super\(state, withConfig\(env, config\)\)/);
  const toml = readFileSync(new URL('../do/wrangler.toml', import.meta.url), 'utf8');
  assert.doesNotMatch(toml, /^OH_SERVICE_KEY\s*=/m);
});

test('the file goes under the names the handlers read, a missing field stays missing', () => {
  const env = configEnv({
    serviceKey: 'k', stripePrice: 'p',
    apple: { bundleId: 'game.openhearts', product: 'yearly', servicesId: 'game.openhearts.play' },
    google: { package: 'game.openhearts', product: 'yearly', webClientId: null },
  });
  assert.equal(env.OH_SERVICE_KEY, 'k');
  assert.equal(env.OH_APPLE_AUDIENCE, 'game.openhearts.play,game.openhearts', 'the web and the phone both');
  assert.equal(env.OH_PLAY_PACKAGE, 'game.openhearts');
  assert.ok(!('OH_GOOGLE_AUDIENCE' in env), 'no Google sign-in without its client');
  assert.ok(!('OH_TURN_KEY_ID' in env));
});

test('a name set on the project, or by a test, wins over the file', () => {
  const env = withConfig({ OH_STRIPE_PRICE: 'other', OH_STORE: 'kv' }, { stripePrice: 'openhearts_annual', serviceKey: 'k' });
  assert.equal(env.OH_STRIPE_PRICE, 'other');
  assert.equal(env.OH_SERVICE_KEY, 'k');
  assert.equal(env.OH_STORE, 'kv');
});

test('the price is the file\'s alone: what the terms state, which no setting on the project changes', () => {
  const env = withConfig({ OH_PRICE: '1 usd' }, { price: { amount: 599, currency: 'usd' } });
  assert.equal(env.OH_PRICE, '599 usd');
  assert.ok(!('OH_PRICE' in withConfig({ OH_PRICE: '1 usd' }, {})), 'no price in the file is none to sell at');
  assert.equal(configEnv(committed).OH_PRICE, `${committed.price.amount} ${committed.price.currency}`);
});

test('a phone build is compiled with the key, the sign-in identifiers and the products, from the same file', () => {
  const defines = appDefines(committed);
  assert.equal(defines.OH_SERVICE_KEY, committed.serviceKey);
  // A phone has no address it was served from: the service it asks,
  // and the links it shares, are at the app's own.
  assert.equal(defines.OH_APP_ORIGIN, 'https://play.openhearts.game');
  assert.equal(defines.OH_APPLE_SERVICE_ID, 'game.openhearts.play');
  // The products are the ones made in App Store Connect and Play
  // Console, and the web's Stripe price has the same name.
  assert.equal(defines.OH_APPLE_PRODUCT, 'openhearts_annual');
  assert.equal(defines.OH_PLAY_PRODUCT, 'openhearts_annual');
  assert.equal(committed.stripePrice, 'openhearts_annual');
  // A field left null is left out, so the build's own default stands.
  assert.deepEqual(appDefines({ serviceKey: 'k', google: { webClientId: null } }), { OH_SERVICE_KEY: 'k' });
});
