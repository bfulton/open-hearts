// An account's pictures (profile_pictures.mjs): each checked as the
// account sets it — Shield through the one object, and the model —
// kept as the account's own copy, with all that is known of it, set
// last, which makes it its picture now, and the one before no longer; a
// match never kept; and the relay carrying an account's picture now and
// nothing else.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { accountPictures, ownedScreen } from './profile_pictures.mjs';
import { ADA, BAO, KEY, bucket, fakeAi, harmless, jpeg, picture } from './pictures.fixtures.mjs';
import { NOT_THEIRS_WHY, PICTURES_ROW, WITHHELD_FOR_MS, changePicture, copiesOf, currentOf, deleteCopy, pictureDigest, withheldOf } from '../functions/pictures.mjs';
import { memoryStore } from '../functions/rows.mjs';

const keyOf = async (account, n) => `account/${account}/${await pictureDigest(jpeg(n))}.jpg`;
const iso = (t) => new Date(t).toISOString();

/// The account's pictures over a fresh bucket and store, the object
/// answering [said] (a function of the picture, or a word, or the whole
/// answer with its receipt), the model [ai], and what was asked, logged
/// and alerted kept.
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
          return typeof answer === 'string' ? { said: answer } : answer;
        };
  const pictures = accountPictures({ OH_PICTURES: b, AI: ai, OH_ALERTS_TO: 'alerts@openhearts.game', HOUSEHOLD: household, ...env }, { now: () => t.now, log: (l) => logs.push(l), ask, store });
  const meta = async (account, n) => s.b.objects.get(await keyOf(account, n))?.customMetadata;
  const s = { t, b, store, asked, logs, alerts, ai, pictures, meta };
  return s;
}

test("a picture set is asked about and kept as the account's own copy, set last, its picture now; the one before is not, from then on", async () => {
  const s = setUp();
  const first = s.t.now;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) }), jpeg(1));
  assert.deepEqual(s.asked, [{ jpeg: jpeg(1), account: ADA, key: KEY }], 'new to her: nobody was shown it');
  const copy = s.b.objects.get(await keyOf(ADA, 1));
  assert.deepEqual(copy.customMetadata, { at: iso(first), last: iso(first), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal(copy.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...copy.bytes], [...Buffer.from(jpeg(1), 'base64')]);

  // Another: it is hers now, and 1 no longer, from now.
  s.t.now += 1000;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(2) }), jpeg(2));
  assert.equal((await s.meta(ADA, 1)).ended, iso(s.t.now));
  assert.equal((await s.meta(ADA, 2)).last, iso(s.t.now));
  assert.ok(!(await s.meta(ADA, 2)).ended);

  // Bao sets 1 too: a copy of his own, checked for him.
  s.t.now += 1000;
  await s.pictures.set({ account: BAO, key: KEY, picture: jpeg(1) });
  assert.equal(s.ai.calls.length, 3);
  assert.deepEqual(await s.meta(BAO, 1), { at: iso(s.t.now), last: iso(s.t.now), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal((await s.meta(ADA, 1)).ended, iso(first + 1000), 'hers as it was');

  // Ada back to 1: set last, as first set, not checked again, and
  // asked about as one she was shown with; 2 no longer.
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) });
  assert.deepEqual(await s.meta(ADA, 1), { at: iso(first), last: iso(s.t.now), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal((await s.meta(ADA, 2)).ended, iso(s.t.now));
  assert.equal(s.ai.calls.length, 3);
  assert.deepEqual(s.asked.at(-1), { jpeg: jpeg(1), account: ADA, key: KEY, shown: true, at: iso(first) });

  // Her profile saved again with 1 unchanged: still hers, nothing
  // written.
  const etags = [...s.b.objects.values()].map((o) => o.etag);
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) });
  assert.deepEqual([...s.b.objects.values()].map((o) => o.etag), etags);

  // None: 1 no longer hers, and none is.
  s.t.now += 1000;
  const off = s.t.now;
  assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: null }), null);
  assert.equal((await s.meta(ADA, 1)).ended, iso(s.t.now));
  assert.equal(currentOf(await copiesOf(s.b, ADA)), null);
  assert.equal(s.asked.length, 5, 'asked at each save, which the object answers from what it holds; nothing asked of no picture');
  // And set again after: hers, as first set.
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(2) });
  assert.deepEqual(await s.meta(ADA, 2), { at: iso(first + 1000), last: iso(s.t.now), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal(currentOf(await copiesOf(s.b, ADA))?.key, await keyOf(ADA, 2));
  assert.equal((await s.meta(ADA, 1)).ended, iso(off), 'still from when she took it off');
});

test('the picture set last is the one set last, whatever the clock of the save that sets it says', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  const was = s.t.now;
  s.t.now -= 5000;
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  assert.equal((await s.meta(ADA, 2)).last, iso(was + 1));
  assert.equal((await s.meta(ADA, 1)).ended, iso(was + 1));
  assert.equal(currentOf(await copiesOf(s.b, ADA))?.key, await keyOf(ADA, 2));
  s.t.now -= 5000;
  await s.pictures.set({ account: ADA, picture: null });
  assert.equal((await s.meta(ADA, 2)).ended, iso(was + 2));
});

test('the one set last is the account\'s picture now, whatever a save that stopped part way left; the next save mends it', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  // A save of 2 that stopped once its copy was written.
  s.t.now += 1000;
  const two = iso(s.t.now);
  await s.b.put(await keyOf(ADA, 2), Buffer.from(jpeg(2), 'base64'), { customMetadata: { at: two, last: two, known: 'clear' } });
  const screen = ownedScreen({ bucket: s.b });
  assert.equal(await screen(picture(2), { account: ADA }), null, 'hers now');
  assert.equal(await screen(picture(1), { account: ADA }), NOT_THEIRS_WHY, 'though 1 does not yet say it has ended');
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(3) });
  assert.equal((await s.meta(ADA, 2)).ended, iso(s.t.now));
  assert.equal((await s.meta(ADA, 1)).ended, two, 'from when 2 was set');
  assert.ok(!(await s.meta(ADA, 3)).ended);
  // And taking her picture off, after another such save.
  s.t.now += 1000;
  const four = iso(s.t.now);
  await s.b.put(await keyOf(ADA, 4), Buffer.from(jpeg(4), 'base64'), { customMetadata: { at: four, last: four, known: 'clear' } });
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: null });
  assert.equal((await s.meta(ADA, 4)).ended, iso(s.t.now));
  assert.equal((await s.meta(ADA, 3)).ended, four);
  // A write lost every time is left for the daily run: the picture set
  // is hers all the same.
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(5) });
  const put = s.b.put.bind(s.b);
  s.b.put = async (key, bytes, o = {}) => (o.onlyIf ? null : put(key, bytes, o));
  s.t.now += 1000;
  assert.equal(await s.pictures.set({ account: ADA, picture: jpeg(6) }), jpeg(6));
  assert.ok(!(await s.meta(ADA, 5)).ended);
  assert.equal(currentOf(await copiesOf(s.b, ADA))?.key, await keyOf(ADA, 6));
  assert.deepEqual(s.logs, [`a picture before this one left for the daily run: ${await keyOf(ADA, 5)} written by another 3 times over`]);
});

test('a picture set again after saves that stopped part way: each before it ends when the one after it was set', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  // Saves of 2, then 3, that each stopped once its copy was written.
  const stopped = async (n) => {
    s.t.now += 1000;
    await s.b.put(await keyOf(ADA, n), Buffer.from(jpeg(n), 'base64'), { customMetadata: { at: iso(s.t.now), last: iso(s.t.now), known: 'clear' } });
    return iso(s.t.now);
  };
  const two = await stopped(2);
  const three = await stopped(3);
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  assert.equal((await s.meta(ADA, 3)).ended, iso(s.t.now));
  assert.equal((await s.meta(ADA, 1)).ended, two, 'from when 2 was first set, not from 3');
  assert.deepEqual(await s.meta(ADA, 2), { at: two, last: iso(s.t.now), known: 'clear' });
  assert.ok(three < iso(s.t.now));
});

test('a copy deleted between its being found and its being changed is made again, and checked', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  const get = s.b.get.bind(s.b);
  s.b.get = async (key) => {
    s.b.get = get;
    await s.b.delete(key);
    return get(key);
  };
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.deepEqual(await s.meta(ADA, 1), { at: iso(s.t.now), last: iso(s.t.now), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear' });
  assert.equal(s.ai.calls.length, 3, 'checked again, as a copy new to her');
  assert.equal((await s.meta(ADA, 2)).ended, iso(s.t.now));
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
  assert.equal((await s.meta(ADA, 1)).ended, iso(s.t.now));
  assert.equal(s.ai.calls.length, 1, 'the model never shown it');

  // One kept while Shield had not said, and set again once it has
  // matched: asked about as one shown since it was first set, and no
  // longer the account's.
  const first = s.t.now;
  await s.pictures.set({ account: BAO, key: KEY, picture: jpeg(8) });
  assert.equal((await s.meta(BAO, 8)).known, 'off');
  s.t.now += 1000;
  const asked = [];
  const matched = accountPictures({ OH_PICTURES: s.b }, { now: () => s.t.now, ask: async (a) => (asked.push(a), { said: 'match' }), store: s.store, log: () => {} });
  assert.equal(await matched.set({ account: BAO, key: KEY, picture: jpeg(8) }), null);
  assert.deepEqual(asked, [{ jpeg: jpeg(8), account: BAO, key: KEY, shown: true, at: iso(first) }]);
  assert.equal((await s.meta(BAO, 8)).ended, iso(s.t.now));
});

test('a picture that cannot be read, or that Shield knows as harmful, is never kept either, nor the one before it', async () => {
  for (const said of ['unreadable', 'harmful']) {
    const s = setUp({ said: (p) => (p === jpeg(9) ? said : 'clear') });
    await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(1) });
    s.t.now += 1000;
    assert.equal(await s.pictures.set({ account: ADA, key: KEY, picture: jpeg(9) }), null, said);
    assert.ok(!s.b.objects.has(await keyOf(ADA, 9)), said);
    assert.equal((await s.meta(ADA, 1)).ended, iso(s.t.now), said);
    assert.equal(s.ai.calls.length, 1, `${said}: the model never shown it`);
    assert.deepEqual(s.alerts, [], said);
  }
});

test('Shield without its key, not answering, or out of reach: the picture is kept, its copy says so, and the operator is told of the object out of reach', async () => {
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
  assert.ok(!(await s.meta(ADA, 1)).ended, 'hers all the same');
});

test('what a checker cleared stays cleared on the copy, once it has said so, with its receipt', async () => {
  let said = 'off';
  const s = setUp({ said: () => said });
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  said = { said: 'clear', knownBy: 'photodna', knownAt: '2026-10-20T01:02:03.000Z' };
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  const copy = s.b.objects.get(await keyOf(ADA, 1));
  assert.deepEqual([copy.customMetadata.known, copy.customMetadata.knownBy, copy.customMetadata.knownAt], ['clear', 'photodna', '2026-10-20T01:02:03.000Z']);
  assert.equal(copy.customMetadata.check, 'sexual=0.010 gore=0.010 hate=0.010', 'what else it said kept');
  assert.equal(copy.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...copy.bytes], [...Buffer.from(jpeg(1), 'base64')]);
  said = 'off';
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.equal((await s.meta(ADA, 1)).known, 'clear', 'never taken back');
  // Nor as she sets it again after another, while Shield has no key.
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.ok(!(await s.meta(ADA, 1)).ended);
  assert.equal((await s.meta(ADA, 1)).known, 'clear');
  // Another checker's answer later changes nothing, its receipt
  // included.
  said = { said: 'clear', knownBy: 'shield', knownAt: '2026-10-21T00:00:00.000Z' };
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  assert.equal((await s.meta(ADA, 1)).knownBy, 'photodna');

  // A new picture keeps its receipt as it is first copied; one with
  // nothing said of it, none.
  said = { said: 'clear', knownBy: 'shield', knownAt: '2026-10-21T00:00:00.000Z' };
  await s.pictures.set({ account: BAO, picture: jpeg(3) });
  const bao = await s.meta(BAO, 3);
  assert.deepEqual([bao.known, bao.knownBy, bao.knownAt], ['clear', 'shield', '2026-10-21T00:00:00.000Z']);
  said = 'failed';
  await s.pictures.set({ account: BAO, picture: jpeg(4) });
  assert.deepEqual(Object.keys(await s.meta(BAO, 4)).filter((k) => k.startsWith('known')), ['known']);
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
  assert.deepEqual(await none.meta(ADA, 7), { at: iso(none.t.now), last: iso(none.t.now), known: 'clear' }, 'no model: nothing said of it');
});

test('a change to a copy is never lost to another written meanwhile, and never writes back one deleted', async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  const key = await keyOf(ADA, 1);
  // The daily run marks it told while her save says it has ended.
  s.b.meanwhile = () => changePicture(s.b, key, (m) => ({ ...m, told: 'today' }));
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  assert.deepEqual(await s.meta(ADA, 1), { at: iso(s.t.now - 1000), last: iso(s.t.now - 1000), check: 'sexual=0.010 gore=0.010 hate=0.010', known: 'clear', told: 'today', ended: iso(s.t.now) });

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
  assert.equal(await screen(picture(2), { account: null }), NOT_THEIRS_WHY, 'the house, of no account');
  assert.equal(await screen(picture(2), null), NOT_THEIRS_WHY, 'nobody');
  assert.equal(await screen({ kind: picture(2).kind, content: JSON.stringify({ kind: 'picture', jpeg: '***' }) }, { account: ADA }), NOT_THEIRS_WHY, 'not base64');
  // Not a picture, or not the lobby kind: not this screen's.
  assert.equal(await screen({ kind: picture(2).kind, content: '{"kind":"start"}' }, { account: BAO }), null);
  assert.equal(await screen(picture(3, 24245), { account: BAO }), null);
  // No bucket, or one that does not answer: nothing carried.
  assert.equal(await ownedScreen({ bucket: null })(picture(2), { account: ADA }), NOT_THEIRS_WHY);
  const down = { list: async () => { throw new Error('bucket down'); } };
  assert.equal(await ownedScreen({ bucket: down, log: (l) => logs.push(l) })(picture(2), { account: ADA }), NOT_THEIRS_WHY);
  assert.deepEqual(logs, ["an account's copies were not read: bucket down"]);
});

test("a copy deleted as a match is acted on leaves none set before it the account's picture now, and its picture now as it is if that is another", async () => {
  const s = setUp();
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(2) });
  const etag = s.b.objects.get(await keyOf(ADA, 2)).etag;
  await deleteCopy(s.b, ADA, await pictureDigest(jpeg(1)));
  assert.ok(!s.b.objects.has(await keyOf(ADA, 1)));
  assert.equal(s.b.objects.get(await keyOf(ADA, 2)).etag, etag, 'hers now, untouched');
  // Her picture now: then she has none, and 2 is not hers again.
  s.t.now += 1000;
  await s.pictures.set({ account: ADA, picture: jpeg(1) });
  await deleteCopy(s.b, ADA, await pictureDigest(jpeg(1)));
  assert.equal(currentOf(await copiesOf(s.b, ADA)), null);
  assert.equal((await s.meta(ADA, 2)).ended, iso(s.t.now));
});
