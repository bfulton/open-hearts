// The refusals the app knows by their words (refusals.mjs), held to
// the app's own table of them. node --test service/functions
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

import { REFUSED } from './refusals.mjs';
import { notConfigured } from './settings.mjs';

test('the refusals the app knows by their words are said here in those words, each under the reason the app reads it as', async () => {
  const dart = await readFile(new URL('../../app/lib/net/household.dart', import.meta.url), 'utf8');
  const table = /static const _named = \{([\s\S]*?)\n {2}\};/.exec(dart)[1];
  const named = Object.fromEntries([...table.matchAll(/^\s*(['"])(.+)\1: '(\w+)',$/gm)].map(([, , words, reason]) => [reason, words]));
  const { signInNotSetUp, ...rest } = named;
  assert.deepEqual(rest, REFUSED);
  // The one the service says of a secret it is missing, by its name.
  assert.equal(signInNotSetUp, notConfigured('OH_ID_HMAC').error);
});
