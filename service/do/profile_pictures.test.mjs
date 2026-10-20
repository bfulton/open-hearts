// An account's pictures (profile_pictures.mjs): each checked as the
// account sets it — PhotoDNA through the one object, and the model —
// kept as the account's own copy, with all that is known of it, as its
// picture now, and the one before no longer; a match never kept; and the
// relay carrying an account's picture now and nothing else.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { accountPictures, ownedScreen } from './profile_pictures.mjs';
import { ADA, BAO, KEY, bucket, fakeAi, harmless, jpeg, picture } from './pictures.fixtures.mjs';
import { NOT_THEIRS_WHY, PICTURES_ROW, WITHHELD_FOR_MS, changePicture, pictureDigest, withheldOf } from '../functions/pictures.mjs';
import { memoryStore } from '../functions/rows.mjs';

const keyOf = async (account, n) => `account/${account}/${await pictureDigest(jpeg(n))}.jpg`;
const iso = (t) => new Date(t).toISOString();

/// The account's pictures over a fresh bucket and store, PhotoDNA
/// answering [said] (a function of the picture, or a word), the model
/// [ai], and what was asked, logged and alerted kept.
function setUp({ said = 'clear', ai = fakeAi(() => harmless), env = {}, start = Date.UTC(2026, 9, 20) } = {}) {
  const t = { now: start };
  const b = bucket(() => t.now);
  const store = memoryStore();
  const asked = [];
  const logs = [];
  const alerts = [];
  const household = { idFromName: (n) => n, get: () => ({ fetch: async (_, init) => (alerts.push(JSON.parse(init.body)), Response.json({ status: 200 })) }) };
  const ask =
    said === null
      ? null
      : async (a) => {
          asked.push(a);
          const answer = typeof said === 'function' ? said(a.jpeg) : said;
          if (answer instanceof Error) throw answer;
          return answer;
        };
  const pictures = accountPictures({ OH_PICTURES: b, AI: ai, OH_ALERTS_TO: 'alerts@openhearts.game', HOUSEHOLD: household, ...env }, { now: () => t.now, log: (l) => logs.push(l), ask, store });
  const meta = async (account, n) => s.b.objects.get(await keyOf(account, n))?.customMetadata;
  const s = { t, b, store, asked, logs, alerts, ai, pictures, meta };
  return s;
}

test("a picture set is asked about and kept as the account's own copy, its picture now; the one before is not, from then on", async () => {
  const s = setUp();
  const first = s.t.now;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) }), jpeg(1));
  assert.deepEqual(s.asked, [{ jpeg: jpeg(1), account: ADA, key: KEY }], 'new to her: nobody was shown it');
  const copy = s.b.objects.get(await keyOf(ADA, 1));
  assert.deepEqual(copy.customMetadata, { at: iso(first), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal(copy.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...copy.bytes], [...Buffer.from(jpeg(1), 'base64')]);

  // Another: it is hers now, and 1 no longer, from now.
  s.t.now += 1000;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(2) }), jpeg(2));
  assert.equal((await s.meta(ADA, 1)).replaced, iso(s.t.now));
  assert.equal((await s.meta(ADA, 2)).at, iso(s.t.now));
  assert.ok(!(await s.meta(ADA, 2)).replaced);

  // Bao sets 1 too: a copy of his own, checked for him.
  s.t.now += 1000;
  await s.pictures.set({ account: BAO, key: KEY, picture: jpeg(1) });
  assert.equal(s.ai.calls.length, 3);
  assert.deepEqual(await s.meta(BAO, 1), { at: iso(s.t.now), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal((await s.meta(ADA, 1)).replaced, iso(first + 1000), 'hers as it was');

  // Ada back to 1: hers again, as first set, not checked again, and
  // asked about as one she was shown with; 2 no longer.
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) });
  assert.deepEqual(await s.meta(ADA, 1), { at: iso(first), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal((await s.meta(ADA, 2)).replaced, iso(s.t.now));
  assert.equal(s.ai.calls.length, 3);
  assert.deepEqual(s.asked.at(-1), { jpeg: jpeg(1), account: ADA, key: KEY, shown: true, at: iso(first) });

  // Her profile saved again with 1 unchanged: still hers, nothing
  // written.
  const etag = s.b.objects.get(await keyOf(ADA, 1)).etag;
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) });
  assert.equal(s.b.objects.get(await keyOf(ADA, 1)).etag, etag);

  // None: 1 no longer hers.
  s.t.now += 1000;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: null }), null);
  assert.equal((await s.meta(ADA, 1)).replaced, iso(s.t.now));
  assert.equal(s.asked.length, 5, 'asked at each save, which the object answers from what it holds; nothing asked of no picture');
});

test('a save leaves the account one picture now, whatever a save that stopped part way left', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  // A save of 2 that stopped once its copy was written.
  await s.b.put(await keyOf(ADA, 2), Buffer.from(jpeg(2), 'base64'), { customMetadata: { at: iso(s.t.now), known: 'clear' } });
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(3) });
  for (const n of [1, 2]) assert.equal((await s.meta(ADA, n)).replaced, iso(s.t.now), `${n} no longer hers`);
  assert.ok(!(await s.meta(ADA, 3)).replaced);
  // And taking her picture off takes every one.
  await s.b.put(await keyOf(ADA, 4), Buffer.from(jpeg(4), 'base64'), { customMetadata: { at: iso(s.t.now), known: 'clear' } });
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: null });
  for (const n of [3, 4]) assert.equal((await s.meta(ADA, n)).replaced, iso(s.t.now));
});

test('a copy deleted between its being found and its being changed is made again, and checked', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  const get = s.b.get.bind(s.b);
  s.b.get = async (key) => {
    s.b.get = get;
    await s.b.delete(key);
    return get(key);
  };
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.deepEqual(await s.meta(ADA, 1), { at: iso(s.t.now), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal(s.ai.calls.length, 3, 'checked again, as a copy new to her');
  assert.equal((await s.meta(ADA, 2)).replaced, iso(s.t.now));
});

test('without the bucket, or for no account, a picture is kept as it is, and nothing asked', async () => {
  const s = setUp({ env: { OH_PICTURES: undefined } });
  assert.equal(await s.pictures.set({ account: ADA, picture: jpeg(1) }), jpeg(1));
  const t = setUp();
  assert.equal(await t.pictures.set({ account: 'not one', picture: jpeg(1) }), jpeg(1));
  assert.deepEqual([s.asked.length, t.asked.length, t.b.objects.size], [0, 0, 0]);
});

test("a match is never kept: neither it nor the one before is the account's, and nothing of it is copied", async () => {
  const s = setUp({ said: (p) => (p === jpeg(9) ? 'match' : p === jpeg(8) ? 'off' : 'clear') });
  await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) });
  s.t.now += 1000;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(9) }), null);
  assert.ok(!s.b.objects.has(await keyOf(ADA, 9)));
  assert.equal((await s.meta(ADA, 1)).replaced, iso(s.t.now));
  assert.equal(s.ai.calls.length, 1, 'the model never shown it');

  // One kept while PhotoDNA had not said, and set again once it has
  // matched: asked about as one shown since it was first set, and no
  // longer the account's.
  const first = s.t.now;
  await s.pictures.set({ account: BAO, key: KEY, picture: jpeg(8) });
  assert.equal((await s.meta(BAO, 8)).known, 'off');
  s.t.now += 1000;
  const asked = [];
  const matched = accountPictures({ OH_PICTURES: s.b }, { now: () => s.t.now, ask: async (a) => (asked.push(a), 'match'), store: s.store, log: () => {} });
  assert.equal(await matched.set({ account: BAO, key: KEY, picture: jpeg(8) }), null);
  assert.deepEqual(asked, [{ jpeg: jpeg(8), account: BAO, key: KEY, shown: true, at: iso(first) }]);
  assert.equal((await s.meta(BAO, 8)).replaced, iso(s.t.now));
});

test('PhotoDNA without its key, not answering, or out of reach: the picture is kept, its copy says so, and the operator is told of the object out of reach', async () => {
  for (const [said, known] of [[null, 'off'], ['off', 'off'], ['failed', 'failed']]) {
    const s = setUp({ said });
    assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) }), jpeg(1));
    assert.equal((await s.meta(ADA, 1)).known, known, String(said));
    assert.deepEqual(s.alerts, []);
  }
  const s = setUp({ said: () => new Error('said 503') });
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) }), jpeg(1));
  assert.equal((await s.meta(ADA, 1)).known, 'unreachable');
  assert.deepEqual(s.logs, ['a picture was set unchecked, to be asked about again by the daily run: said 503']);
  assert.equal(s.alerts.length, 1);
  assert.match(s.alerts[0].subject, /automatic handling of abuse images failed \(unreachable\)/);
  assert.ok(!(await s.meta(ADA, 1)).replaced, 'hers all the same');
});

test('what PhotoDNA cleared stays cleared on the copy, once it has said so', async () => {
  let said = 'off';
  const s = setUp({ said: () => said });
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  said = 'clear';
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  const copy = s.b.objects.get(await keyOf(ADA, 1));
  assert.equal(copy.customMetadata.known, 'clear');
  assert.equal(copy.customMetadata.check, 'sexual=0.010 gore=0.010 hate=0.010', 'what else it said kept');
  assert.equal(copy.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...copy.bytes], [...Buffer.from(jpeg(1), 'base64')]);
  said = 'off';
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.equal((await s.meta(ADA, 1)).known, 'clear', 'never taken back');
  // Nor as she sets it again after another, while PhotoDNA has no key.
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.ok(!(await s.meta(ADA, 1)).replaced);
  assert.equal((await s.meta(ADA, 1)).known, 'clear');
});

test('a picture the model takes for nudity, gore or a hate symbol is hidden as it is set; a check or a hiding that fails is told and the picture kept', async () => {
  const scores = { [jpeg(1)]: harmless, [jpeg(2)]: { ...harmless, hate: 0.94 }, [jpeg(3)]: { ...harmless, sexual: 0.5 }, [jpeg(4)]: { ...harmless, gore: 0.49 } };
  const s = setUp({ ai: fakeAi((p) => scores[p] ?? new Error('model down')) });
  for (const n of [1, 2, 3, 4]) await s.pictures.set({ account: ADA, picture: jpeg(n) });
  assert.equal((await s.meta(ADA, 2)).check, 'sexual=0.010 gore=0.010 hate=0.940');
  const withheld = withheldOf(await s.store.get(...PICTURES_ROW), s.t.now);
  assert.deepEqual([...withheld].sort(), [await pictureDigest(jpeg(2)), await pictureDigest(jpeg(3))].sort(), '0.5 hides; 0.49 does not');
  // Ada sets 2 again once its hiding has run out: not checked again,
  // and hidden again for what her copy says.
  s.t.now += WITHHELD_FOR_MS;
  assert.equal(withheldOf(await s.store.get(...PICTURES_ROW), s.t.now).size, 0);
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  assert.equal(s.ai.calls.length, 4);
  assert.deepEqual([...withheldOf(await s.store.get(...PICTURES_ROW), s.t.now)], [await pictureDigest(jpeg(2))]);

  await s.pictures.set({ account: ADA, picture: jpeg(5) });
  assert.equal((await s.meta(ADA, 5)).check, 'failed');
  assert.deepEqual(s.logs, ['picture not checked: model down']);

  const quiet = setUp({ ai: fakeAi(() => ({ ...harmless, gore: 0.9 })) });
  quiet.store.put = async () => {
    throw new Error('store down');
  };
  assert.equal(await quiet.pictures.set({ account: ADA, picture: jpeg(6) }), jpeg(6));
  assert.deepEqual(quiet.logs, ['picture not hidden: store down']);

  const none = setUp({ ai: null, env: { AI: undefined } });
  await none.pictures.set({ account: ADA, picture: jpeg(7) });
  assert.deepEqual(await none.meta(ADA, 7), { at: iso(none.t.now), known: 'clear' }, 'no model: nothing said of it');
});

test('a change to a copy is never lost to another written meanwhile, and never writes back one deleted', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  const key = await keyOf(ADA, 1);
  // The daily run marks it told while her save marks it replaced.
  s.b.meanwhile = () => changePicture(s.b, key, (m) => ({ ...m, told: 'today' }));
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  assert.deepEqual(await s.meta(ADA, 1), { at: iso(s.t.now - 1000), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear', told: 'today', replaced: iso(s.t.now) });

  // Deleted between the read and the write: left deleted.
  s.b.meanwhile = () => s.b.delete(key);
  assert.equal(await changePicture(s.b, key, (m) => ({ ...m, told: 'again' })), null);
  assert.ok(!s.b.objects.has(key));

  // Written by another every time: said so, and nothing written.
  const two = await keyOf(ADA, 2);
  const busy = { ...s.b, get: s.b.get, put: async () => null };
  await assert.rejects(changePicture(busy, two, (m) => ({ ...m, told: 'x' })), /written by another 3 times over/);
  assert.ok(!(await s.meta(ADA, 2)).told);
});

test("the relay carries an account's picture now and nothing else", async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  const logs = [];
  const screen = ownedScreen({ bucket: s.b, log: (l) => logs.push(l) });
  assert.equal(await screen(picture(2), { account: ADA }), null, 'hers now');
  assert.equal(await screen(picture(1), { account: ADA }), NOT_THEIRS_WHY, 'hers no longer');
  assert.equal(await screen(picture(2), { account: BAO }), NOT_THEIRS_WHY, 'never his');
  assert.equal(await screen(picture(3), { account: ADA }), NOT_THEIRS_WHY, 'never set');
  assert.equal(await screen(picture(2), { account: null }), NOT_THEIRS_WHY, 'a backup juror');
  assert.equal(await screen(picture(2), null), NOT_THEIRS_WHY, 'nobody');
  assert.equal(await screen({ kind: picture(2).kind, content: JSON.stringify({ kind: 'picture', jpeg: '***' }) }, { account: ADA }), NOT_THEIRS_WHY, 'not base64');
  // Not a picture, or not the lobby kind: not this screen's.
  assert.equal(await screen({ kind: picture(2).kind, content: '{"kind":"start"}' }, { account: BAO }), null);
  assert.equal(await screen(picture(3, 24245), { account: BAO }), null);
  // No bucket, or one that does not answer: nothing carried.
  assert.equal(await ownedScreen({ bucket: null })(picture(2), { account: ADA }), NOT_THEIRS_WHY);
  const down = { head: async () => { throw new Error('bucket down'); } };
  assert.equal(await ownedScreen({ bucket: down, log: (l) => logs.push(l) })(picture(2), { account: ADA }), NOT_THEIRS_WHY);
  assert.deepEqual(logs, ["a picture's copy was not read: bucket down"]);
});
