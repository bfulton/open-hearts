// The pictures accounts set, kept for the operator to look at
// (review.mjs, profile_pictures.mjs): the day's run goes over every
// account's copy of every picture and does only what each copy's flags
// say is still to do — holds each account's copies to the order it set
// them in, keeps each for a year after it stops being its account's and
// no longer, asks
// Arachnid Shield again about what it has not cleared, keeps hidden what the
// check found should be, and emails the operator, account by account,
// every picture each set since the last — the ones it has since replaced
// too — with what the check made of each, and the commands that take
// them down or put them back.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CHECK_MODEL, PICTURES_ORIGIN, PICTURE_KEPT_DAYS, REVIEW_MOST, checkPicture, reviewEmail, reviewRun } from './review.mjs';
import { accountPictures } from './profile_pictures.mjs';
import { ADA, BAO, CY, DAY, bucket, fakeAi, harmless, jpeg } from './pictures.fixtures.mjs';
import { r2 } from '../../infra/cloudflare.mjs';
import { HOLD_DAYS } from '../functions/holds.mjs';
import { PICTURES_ROW, WITHHELD_FOR_MS, allowing, copiesOf, currentOf, pictureDigest, withheldOf } from '../functions/pictures.mjs';
import { memoryStore } from '../functions/rows.mjs';

const keyOf = async (account, n) => `account/${account}/${await pictureDigest(jpeg(n))}.jpg`;
const urlOf = async (account, n) => `${PICTURES_ORIGIN}/${await keyOf(account, n)}`;
const digestOf = (n) => pictureDigest(jpeg(n));
const withheldIn = async (store, t) => withheldOf(await store.get(...PICTURES_ROW), t);
const iso = (t) => new Date(t).toISOString();

/// A deployment's pictures: the bucket, the store, a clock, the
/// account's turn setting [n] as an account's picture and saving its
/// profile with what it keeps (profile.mjs), and the day's run.
function setUp({ ai = null, ask = async () => 'clear', start = Date.UTC(2026, 9, 20, 9) } = {}) {
  const t = { now: start };
  const b = bucket(() => t.now);
  const store = memoryStore();
  const pictures = accountPictures({ OH_PICTURES: b, AI: ai }, { now: () => t.now, ask, store, log: () => {} });
  const set = async (account, n) => {
    const picture = await pictures.set({ account, picture: n === null ? null : jpeg(n) });
    await store.put(`ACCOUNT#${account}`, 'PROFILE', { name: account.slice(0, 4), picture });
    t.now += 60 * 1000;
  };
  const run = (sent = [], more = {}) => reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t.now, ...more });
  const meta = async (account, n) => b.objects.get(await keyOf(account, n))?.customMetadata;
  return { t, b, store, set, run, meta };
}

test("review: the copies are served where the bucket's custom domain is", () => {
  const pictures = r2.find((x) => x.name === 'open-hearts-pictures');
  assert.deepEqual(pictures.customDomains, [new URL(PICTURES_ORIGIN).host]);
  assert.equal(pictures.publicDevUrl, false);
});

test("review: a picture is kept as long as one reported, a year after it stops being its account's", () => {
  assert.equal(PICTURE_KEPT_DAYS, HOLD_DAYS);
  assert.equal(PICTURE_KEPT_DAYS, 365);
});

test('review: a picture swapped back before the email is in it — every picture each account set, account by account', async () => {
  const s = setUp();
  // Day one: Ada's picture is 1, and the operator is told of it.
  await s.set(ADA, 1);
  await s.run([]);
  // Day two: Ada sets 2, then 3, then 1 again, which is hers by the
  // email; Bao sets 3 as well, and it is his.
  s.t.now += DAY;
  await s.set(ADA, 2);
  await s.set(ADA, 3);
  await s.set(BAO, 3);
  await s.set(ADA, 1);
  const sent = [];
  assert.deepEqual(await s.run(sent), { deleted: 0, asked: 0, sent: 3, more: 0 });
  const [mail] = sent;
  assert.equal(mail.subject, 'Open Hearts: 3 new pictures to look at, from 2 accounts');
  // Ada first, with both she set, in order, neither hers now, and no
  // take-off command: suspension. Then Bao's, his now.
  const ada = mail.text.indexOf(`Account ${ADA}: 2 pictures`);
  const bao = mail.text.indexOf(`Account ${BAO}: 1 picture`);
  assert.ok(ada > 0 && bao > ada, 'account by account, oldest first');
  const adaPart = mail.text.slice(ada, bao);
  assert.ok(adaPart.indexOf(await urlOf(ADA, 2)) < adaPart.indexOf(await urlOf(ADA, 3)), 'in the order she set them, her own copies');
  assert.match(adaPart, /no longer its profile picture/);
  assert.ok(!adaPart.includes(await urlOf(ADA, 1)), 'what she was told of before is not news');
  assert.ok(!adaPart.includes('account remove'));
  assert.ok(adaPart.includes(`./oh account suspend ${ADA} --apply`));
  const baoPart = mail.text.slice(bao);
  assert.ok(baoPart.includes(await urlOf(BAO, 3)) && baoPart.includes('its profile picture now'));
  assert.ok(baoPart.includes(`./oh account remove ${BAO} picture --apply`));
  assert.ok(mail.html.includes(`<img src="${await urlOf(ADA, 2)}"`) && mail.html.includes(`<img src="${await urlOf(BAO, 3)}"`));
  assert.match(mail.text, /handle-abuse-material\.md/);
  assert.match(mail.text, /Every picture each account set since the last email/);
  // Told once, and the copy says so without forgetting the rest.
  const two = await s.meta(ADA, 2);
  assert.deepEqual(Object.keys(two).sort(), ['at', 'ended', 'known', 'last', 'told']);
  assert.equal(two.told, iso(s.t.now));
  s.t.now += DAY;
  const again = [];
  assert.deepEqual(await s.run(again), { deleted: 0, asked: 0, sent: 0, more: 0 });
  assert.equal(again.length, 0);
});

test('review: an email that does not go is sent again the next day', async () => {
  const s = setUp();
  await s.set(ADA, 1);
  await assert.rejects(s.run([], { send: async () => { throw new Error('no mail today'); } }));
  s.t.now += DAY;
  assert.equal((await s.run([])).sent, 1);
});

test('review: a copy whose told is never written, another writing it each time, is left for the next run, and said so', async () => {
  const s = setUp();
  await s.set(ADA, 1);
  const put = s.b.put.bind(s.b);
  s.b.put = async (key, bytes, o = {}) => (o.onlyIf ? null : put(key, bytes, o));
  const logs = [];
  assert.equal((await s.run([], { log: (l) => logs.push(l) })).sent, 1);
  assert.deepEqual(logs, [`picture ${await keyOf(ADA, 1)} left for the next run: ${await keyOf(ADA, 1)} written by another 3 times over`]);
  s.b.put = put;
  s.t.now += DAY;
  assert.equal((await s.run([])).sent, 1, 'emailed again, and told');
  assert.ok((await s.meta(ADA, 1)).told);
});

test('review: whole accounts, up to a hundred pictures; the rest the next day, and one account is never split', async () => {
  const s = setUp();
  // Ada 60, Bao 50, Cy 3: Ada alone fits; Bao would pass a hundred.
  for (const [account, n0, count] of [[ADA, 0, 60], [BAO, 100, 50], [CY, 200, 3]]) {
    for (let n = n0; n < n0 + count; n++) await s.set(account, n);
  }
  const sent = [];
  assert.deepEqual(await s.run(sent), { deleted: 0, asked: 0, sent: 60, more: 53 });
  assert.match(sent[0].text, /53 more will come in the next email\./);
  s.t.now += DAY;
  assert.deepEqual(await s.run(sent), { deleted: 0, asked: 0, sent: 53, more: 0 });
  // And an account of more than a hundred goes whole, on its own.
  for (let n = 300; n < 300 + REVIEW_MOST + 5; n++) await s.set(CY, n);
  s.t.now += DAY;
  assert.equal((await s.run(sent)).sent, REVIEW_MOST + 5);
});

test("review: a copy is kept a year after it stops being its account's, and no longer; another account's copy of the same picture is its own", async () => {
  const s = setUp();
  const start = s.t.now;
  await s.set(ADA, 1);
  await s.set(BAO, 1);
  s.t.now = start + DAY;
  await s.set(ADA, 2);
  const replaced = s.t.now - 60 * 1000;
  s.t.now = replaced + (PICTURE_KEPT_DAYS - 1) * DAY;
  assert.equal((await s.run()).deleted, 0);
  assert.ok(s.b.objects.has(await keyOf(ADA, 1)), 'a day short of a year: kept');
  s.t.now = replaced + PICTURE_KEPT_DAYS * DAY;
  assert.equal((await s.run()).deleted, 1);
  assert.ok(!s.b.objects.has(await keyOf(ADA, 1)), 'a year: gone');
  assert.ok(s.b.objects.has(await keyOf(BAO, 1)), "Bao's own copy kept for as long as it is his");
  assert.ok(s.b.objects.has(await keyOf(ADA, 2)));

  // One set again just before the run would delete it stays hers.
  await s.set(ADA, 3);
  s.t.now += PICTURE_KEPT_DAYS * DAY;
  const head = s.b.head.bind(s.b);
  s.b.head = async (key) => {
    s.b.head = head;
    await s.set(ADA, 2);
    return head(key);
  };
  assert.equal((await s.run()).deleted, 0);
  assert.ok(!(await s.meta(ADA, 2)).ended, 'set again: hers, and kept');
  assert.ok(s.b.objects.has(await keyOf(ADA, 3)), 'and the one before it, which went first, then stops');
});

test('review: a copy set again while the run holds the copies to their order is the account\'s picture now; and the one before it ends when that was first set', async () => {
  const s = setUp();
  await s.set(ADA, 1);
  // A save of 2 that stopped once its copy was written; and as the run
  // is about to say 1 has ended, Ada sets 1 again.
  const two = iso(s.t.now);
  await s.b.put(await keyOf(ADA, 2), Buffer.from(jpeg(2), 'base64'), { customMetadata: { at: two, last: two, known: 'clear' } });
  s.t.now += 1000;
  s.b.meanwhile = () => s.set(ADA, 1);
  await s.run();
  assert.ok(!(await s.meta(ADA, 1)).ended, 'hers now');
  assert.equal(currentOf(await copiesOf(s.b, ADA))?.key, await keyOf(ADA, 1));

  // Two saves that stopped, of 3 then 4, and 3's set again as the run
  // is about to say it has ended, by a save that stops too: 2 ends when
  // 3 was first set.
  const t = setUp();
  await t.set(BAO, 2);
  const stopped = async (n) => {
    t.t.now += 1000;
    await t.b.put(await keyOf(BAO, n), Buffer.from(jpeg(n), 'base64'), { customMetadata: { at: iso(t.t.now), last: iso(t.t.now), known: 'clear' } });
    return iso(t.t.now);
  };
  const three = await stopped(3);
  await stopped(4);
  t.t.now += 1000;
  t.b.meanwhile = async () => {
    const key = await keyOf(BAO, 3);
    const o = t.b.objects.get(key);
    await t.b.put(key, o.bytes, { customMetadata: { ...o.customMetadata, last: iso(t.t.now) } });
  };
  await t.run();
  assert.equal((await t.meta(BAO, 2)).ended, three);
});

test('review: no copy is deleted while one its account set before it does not yet say it has ended, which would become its picture now', async () => {
  const s = setUp();
  await s.set(ADA, 1);
  // A save of 2 that stopped once its copy was written, and her
  // picture then taken off.
  const two = iso(s.t.now);
  await s.b.put(await keyOf(ADA, 2), Buffer.from(jpeg(2), 'base64'), { customMetadata: { at: two, last: two, known: 'clear' } });
  s.t.now += 1000;
  await s.b.put(await keyOf(ADA, 2), Buffer.from(jpeg(2), 'base64'), { customMetadata: { at: two, last: two, known: 'clear', ended: iso(s.t.now) } });
  // 1 cannot be written to say it has ended, by the run or anyone.
  const one = await keyOf(ADA, 1);
  const put = s.b.put.bind(s.b);
  s.b.put = async (key, bytes, o = {}) => (key === one && o.onlyIf ? null : put(key, bytes, o));
  s.t.now += PICTURE_KEPT_DAYS * DAY;
  const logs = [];
  assert.equal((await s.run([], { log: (l) => logs.push(l) })).deleted, 0);
  assert.ok(s.b.objects.has(await keyOf(ADA, 2)), '2 kept, past its year, so that 1 is not hers again');
  assert.deepEqual(logs.filter((l) => l.startsWith('pictures of')), [`pictures of ${ADA} left for the next run: ${one} written by another 3 times over`]);
  assert.equal(currentOf(await copiesOf(s.b, ADA)), null);
  // Once 1 says so: both go, a year after each ended.
  s.b.put = put;
  s.t.now += DAY;
  assert.equal((await s.run()).deleted, 2);
  assert.equal(s.b.objects.size, 0);
});

test("review: each account's copies are held to the order it set them in, whatever a save that stopped part way left, and an account deleted outside its turn from when it was; no profile is read", async () => {
  const s = setUp();
  const reads = [];
  const get = s.store.get.bind(s.store);
  s.store.get = async (pk, sk) => (sk === 'PROFILE' && reads.push(pk), get(pk, sk));
  await s.set(ADA, 1);
  // A save of 2 that stopped once its copy was written.
  const two = iso(s.t.now);
  await s.b.put(await keyOf(ADA, 2), Buffer.from(jpeg(2), 'base64'), { customMetadata: { at: two, last: two, known: 'clear' } });
  // Bao's picture taken off, in his turn.
  await s.set(BAO, 3);
  await s.set(BAO, null);
  const baoEnded = (await s.meta(BAO, 3)).ended;
  s.t.now += 1000;
  await s.run();
  assert.equal((await s.meta(ADA, 1)).ended, two, "1 no longer hers since 2 was set: hers now, the one she set last");
  assert.ok(!(await s.meta(ADA, 2)).ended);
  assert.equal((await s.meta(BAO, 3)).ended, baoEnded, 'his as his turn left it');
  assert.deepEqual(reads, [], 'no profile read');

  // Cy deleted outside his turn (`oh account delete`, which marks him
  // forgotten first): his picture no longer his from when he was.
  const t = setUp();
  const records = bucket(() => t.t.now);
  await t.set(CY, 3);
  t.t.now += 30 * DAY;
  // Others forgotten before him, so that his mark is on a later page.
  await records.put(`forgotten/${ADA}`, '{}');
  await records.put(`forgotten/${BAO}`, '{}');
  await records.put(`forgotten/${CY}`, JSON.stringify({ forgotten: 'that day' }));
  const deleted = t.t.now;
  t.t.now += DAY / 2;
  await t.run([], { records });
  assert.equal((await t.meta(CY, 3)).ended, iso(deleted));
  // A mark from before his picture was set says nothing of when it
  // stopped being his: from the run that finds it.
  const w = setUp();
  const marks = bucket(() => w.t.now);
  await marks.put(`forgotten/${CY}`, '{}');
  w.t.now += DAY;
  await w.set(CY, 3);
  w.t.now += DAY;
  await w.run([], { records: marks });
  assert.equal((await w.meta(CY, 3)).ended, iso(w.t.now));
  // Another account's mark says nothing of his, nor does none.
  const v = setUp();
  const others = bucket(() => v.t.now);
  await others.put(`forgotten/${ADA}`, '{}');
  await v.set(CY, 3);
  v.t.now += DAY;
  await v.run([], { records: others });
  await v.run();
  assert.ok(!(await v.meta(CY, 3)).ended);
});

test('review: a copy Arachnid Shield cannot be asked about, not decoding, is said to be, hidden, emailed as that, and not asked about again', async () => {
  const s = setUp({ ask: async () => 'off' });
  await s.set(ADA, 1);
  await s.set(BAO, 2);
  const ask = async (a) => (a.jpeg === jpeg(1) ? 'unreadable' : 'clear');
  const sent = [];
  assert.deepEqual(await s.run(sent, { ask }), { deleted: 0, asked: 2, sent: 2, more: 0 });
  assert.equal((await s.meta(ADA, 1)).known, 'unreadable');
  assert.equal((await s.meta(BAO, 2)).known, 'clear');
  assert.ok(!(await s.meta(ADA, 1)).ended, 'still the account\'s, hidden');
  const withheld = await withheldIn(s.store, s.t.now);
  assert.ok(withheld.has(await digestOf(1)));
  assert.ok(!withheld.has(await digestOf(2)));
  assert.match(sent[0].text, /hidden: it could not be decoded, so Arachnid Shield could not be asked about it/);
  assert.equal(sent[0].text.match(/could not be decoded/g).length, 1, 'only for that one');
  s.t.now += DAY;
  assert.equal((await s.run([], { ask })).asked, 0);
  assert.ok((await withheldIn(s.store, s.t.now)).has(await digestOf(1)), 'hidden still');
});

test("review: Arachnid Shield is asked again about each copy it has not cleared, for its account, whether or not the account still has it; a match is no longer theirs, from when it stopped being so, and never emailed", async () => {
  const s = setUp({ ask: async () => 'off' });
  await s.set(ADA, 1);
  await s.set(BAO, 1);
  await s.set(CY, 2);
  await s.set(CY, 3);
  await s.set(CY, 4);
  const asked = [];
  const answers = { [jpeg(1)]: 'match', [jpeg(2)]: 'match', [jpeg(3)]: 'clear', [jpeg(4)]: 'clear' };
  // As the object does on a match: the account's copy deleted as the
  // picture is withheld (known.mjs, the case's first step).
  const ask = async (a) => {
    asked.push(a);
    const said = answers[a.jpeg];
    if (said === 'match') s.b.objects.delete(`account/${a.account}/${await pictureDigest(a.jpeg)}.jpg`);
    return said;
  };
  const when = [(await s.meta(ADA, 1)).at, (await s.meta(BAO, 1)).at, (await s.meta(CY, 2)).at, (await s.meta(CY, 3)).at, (await s.meta(CY, 4)).at];
  const cyHad = [(await s.meta(CY, 2)).ended, (await s.meta(CY, 3)).ended];
  assert.ok(cyHad.every(Boolean), "2 and 3 are no longer Cy's");
  const sent = [];
  assert.deepEqual(await s.run(sent, { ask }), { deleted: 0, asked: 5, sent: 2, more: 0 });
  const order = (rows) => rows.map((r) => JSON.stringify(r)).sort();
  assert.deepEqual(
    order(asked.map((a) => [a.jpeg, a.account, a.key, a.shown, a.at])),
    order([
      [jpeg(1), ADA, null, true, when[0]],
      [jpeg(1), BAO, null, true, when[1]],
      [jpeg(2), CY, null, true, when[2]],
      [jpeg(3), CY, null, true, when[3]],
      [jpeg(4), CY, null, true, when[4]],
    ]),
    "each account's copy not cleared, each with when it set it, whether or not it has it now",
  );
  for (const n of [3, 4]) {
    const copy = s.b.objects.get(await keyOf(CY, n));
    assert.equal(copy.customMetadata.known, 'clear');
    assert.equal(copy.httpMetadata.contentType, 'image/jpeg');
    assert.deepEqual([...copy.bytes], [...Buffer.from(jpeg(n), 'base64')]);
  }
  assert.equal((await s.meta(CY, 3)).ended, cyHad[1], 'a cleared one is as it was');
  assert.ok(!(await s.meta(CY, 4)).ended);
  for (const n of [1, 2]) assert.ok(!sent[0].text.includes(await digestOf(n)), `the match ${n} never emailed`);
  assert.ok(sent[0].text.includes(await digestOf(3)) && sent[0].text.includes(await digestOf(4)));
  // Asked once: 3 and 4 are cleared, and 1 and 2 no longer copied.
  s.t.now += DAY;
  assert.equal((await s.run([], { ask })).asked, 0);

  // A match the object has not yet deleted is no longer theirs, and
  // one no longer theirs keeps since when, so that its year is not
  // begun again.
  // So is one Shield knows as harmful, and neither is emailed.
  for (const said of ['match', 'harmful']) {
    const m = setUp({ ask: async () => 'off' });
    await m.set(ADA, 5);
    await m.set(ADA, 6);
    const had = (await m.meta(ADA, 5)).ended;
    m.t.now += DAY;
    const mails = [];
    assert.deepEqual(await m.run(mails, { ask: async () => said }), { deleted: 0, asked: 2, sent: 0, more: 0 }, said);
    assert.equal((await m.meta(ADA, 5)).ended, had, said);
    assert.equal((await m.meta(ADA, 6)).ended, iso(m.t.now), said);
    assert.deepEqual(mails, [], said);
  }

  // Without its key, not answering, or out of reach: tried tomorrow.
  for (const said of ['off', 'failed', new Error('said 503')]) {
    const t = setUp({ ask: async () => 'off' });
    await t.set(ADA, 1);
    await t.set(BAO, 1);
    const tried = [];
    const r = await t.run([], { ask: async (a) => (tried.push(a.account), said instanceof Error ? Promise.reject(said) : said) });
    assert.deepEqual(tried, [ADA], String(said));
    assert.equal(r.asked, said instanceof Error ? 0 : 1);
    assert.equal((await t.meta(ADA, 1)).known, 'off');
    assert.ok(!(await t.meta(ADA, 1)).ended);
  }
});

test('review: the check asks the model its questions of the picture, and takes nothing short of an answer to each', async () => {
  const ai = fakeAi(() => harmless);
  assert.deepEqual(await checkPicture(ai, jpeg(1)), harmless);
  const [{ model, input }] = ai.calls;
  assert.equal(model, CHECK_MODEL);
  assert.equal(input.model, 'clef-flash');
  assert.deepEqual(input.images, [`data:image/jpeg;base64,${jpeg(1)}`]);
  assert.deepEqual(Object.keys(input.questions), ['sexual', 'gore', 'hate']);
  for (const q of Object.values(input.questions)) assert.ok(q.type === 'noul' && q.instructions.endsWith('?'));
  await assert.rejects(checkPicture(fakeAi(() => ({ sexual: 0.1, gore: 0.1 })), jpeg(1)), /no answer to hate/);
  await assert.rejects(checkPicture(fakeAi(() => ({ ...harmless, gore: 1.5 })), jpeg(1)), /no answer to gore/);
  await assert.rejects(checkPicture(fakeAi(() => ({ ...harmless, sexual: '0.1' })), jpeg(1)), /no answer to sexual/);
});

test("review: a hidden picture is hidden again while it is an account's, once its 30 days run out; one the operator allowed is not, nor one nobody has", async () => {
  const s = setUp({ ai: fakeAi(() => ({ ...harmless, sexual: 0.93 })) });
  await s.set(ADA, 1);
  await s.set(BAO, 2);
  await s.set(CY, 3);
  await s.set(CY, null);
  const [one, two] = [await digestOf(1), await digestOf(2)];
  await s.store.put(...PICTURES_ROW, allowing(await s.store.get(...PICTURES_ROW), two, s.t.now));
  await s.run();
  const start = s.t.now;
  s.t.now = start + WITHHELD_FOR_MS - DAY;
  await s.run();
  s.t.now = start + WITHHELD_FOR_MS + 1000;
  await s.run();
  assert.deepEqual([...(await withheldIn(s.store, s.t.now))], [one], "1 hidden again; 2 still allowed; 3, nobody's now, let be");
});

test('review: a check or a hiding that fails as a picture is set is told; the daily run hides it all the same', async () => {
  const ai = fakeAi((p) => (p === jpeg(1) ? new Error('model down') : p === jpeg(2) ? { ...harmless, gore: 0.9 } : harmless));
  const s = setUp({ ai });
  const put = s.store.put.bind(s.store);
  s.store.put = async (pk, sk, v, o) => {
    if (pk === PICTURES_ROW[0]) throw new Error('store down');
    return put(pk, sk, v, o);
  };
  await s.set(ADA, 1);
  await s.set(ADA, 2);
  await s.set(ADA, 3);
  assert.equal(await s.store.get(...PICTURES_ROW), null);
  s.store.put = put;
  const sent = [];
  await s.run(sent);
  const [one, two] = [await digestOf(1), await digestOf(2)];
  assert.deepEqual([...(await withheldIn(s.store, s.t.now))], [two]);
  const [mail] = sent;
  assert.equal(mail.subject, 'Open Hearts: 3 new pictures to look at, from 1 account, 1 hidden by the check');
  assert.match(mail.text, new RegExp(`${one}\\.jpg .*not checked: the check failed`));
  assert.match(mail.text, new RegExp(`${two}\\.jpg .*hidden by the check for violence or gore \\(0\\.90\\)`));
  assert.ok(mail.text.includes(`./oh picture allow ${two} --apply`));
  assert.ok(!mail.text.includes(`./oh picture allow ${one}`));
});

test('review: accounts with a picture hidden as nudity or sexual content come first, in the first email; one put back is marked so', async () => {
  // Ada 60 harmless; Bao 50, the last hidden as sexual; Cy 1, hidden as
  // sexual and allowed by the operator before the email.
  const s = setUp({ ai: fakeAi((p) => (p === jpeg(149) || p === jpeg(200) ? { ...harmless, sexual: 0.93 } : harmless)) });
  for (const [account, n0, count] of [[ADA, 0, 60], [BAO, 100, 50], [CY, 200, 1]]) {
    for (let n = n0; n < n0 + count; n++) await s.set(account, n);
  }
  const allowed = await digestOf(200);
  await s.store.put(...PICTURES_ROW, allowing(await s.store.get(...PICTURES_ROW), allowed, s.t.now));
  const sent = [];
  // Bao alone, though Ada set hers before, and Cy's is not urgent:
  // whole accounts in order, and Ada would pass a hundred.
  assert.deepEqual(await s.run(sent), { deleted: 0, asked: 0, sent: 50, more: 61 });
  const [mail] = sent;
  assert.equal(mail.subject, 'Urgent: Open Hearts: 50 new pictures to look at, from 1 account, 1 hidden by the check');
  assert.match(mail.text, /^The automatic check hid 1 picture as nudity or sexual content; the accounts that set them are first\. Look at them now\./);
  assert.match(mail.text, new RegExp(`${await digestOf(149)}\\.jpg .*hidden by the check for nudity or sexual content \\(0\\.93\\)`));
  assert.ok(mail.text.includes(`./oh picture allow ${await digestOf(149)} --apply`));
  assert.match(mail.html, /<b style="color:#b00020">The automatic check hid 1 picture/);
  assert.deepEqual([...(await withheldIn(s.store, s.t.now))], [await digestOf(149)], 'what the operator allowed stays shown');
  // The next day: Ada's and Cy's, nothing urgent, Cy's marked as put back.
  s.t.now += DAY;
  await s.run(sent);
  const next = sent[1];
  assert.equal(next.subject, 'Open Hearts: 61 new pictures to look at, from 2 accounts');
  assert.ok(!next.text.includes('automatic check hid') && !next.html.includes('#b00020'));
  assert.match(next.text, new RegExp(`${allowed}\\.jpg .*put back by you after the check hid it for nudity or sexual content \\(0\\.93\\)`));
  assert.ok(!next.text.includes(`./oh picture allow ${allowed}`));
});

test('review: what the operator allowed stays allowed while a copy of it is kept, and no longer once it is deleted', async () => {
  const s = setUp({ ai: fakeAi(() => ({ ...harmless, hate: 0.9 })) });
  await s.set(ADA, 1);
  const [one, two] = [await digestOf(1), await digestOf(2)];
  // 1, allowed, is replaced by 2, allowed too; the run every few weeks
  // keeps both allowed while both are kept.
  await s.store.put(...PICTURES_ROW, allowing(await s.store.get(...PICTURES_ROW), one, s.t.now));
  await s.set(ADA, 2);
  const replaced = s.t.now - 60 * 1000;
  await s.store.put(...PICTURES_ROW, allowing(await s.store.get(...PICTURES_ROW), two, s.t.now));
  for (let day = 25; day < PICTURE_KEPT_DAYS; day += 25) {
    s.t.now = replaced + day * DAY;
    await s.run();
  }
  const last = replaced + (PICTURE_KEPT_DAYS - 1) * DAY;
  s.t.now = last;
  await s.run();
  s.t.now = replaced + PICTURE_KEPT_DAYS * DAY;
  await s.run();
  assert.ok(!s.b.objects.has(await keyOf(ADA, 1)), "1's copy deleted");
  const row = await s.store.get(...PICTURES_ROW);
  assert.deepEqual(
    row.allowed.map((a) => [a.sha256, a.until]),
    [[one, last + WITHHELD_FOR_MS], [two, s.t.now + WITHHELD_FOR_MS]],
    "2's kept allowed from today; 1's left to run out",
  );
  assert.deepEqual([...(await withheldIn(s.store, s.t.now))], []);
});

test('review: with no email to send, what is kept is kept as long as promised all the same, and nobody is told', async () => {
  const s = setUp();
  await s.set(ADA, 1);
  await s.set(ADA, 2);
  s.t.now += PICTURE_KEPT_DAYS * DAY;
  assert.deepEqual(await reviewRun({ bucket: s.b, store: s.store, now: () => s.t.now }), { deleted: 1, asked: 0, sent: 0, more: 0 });
  assert.ok(!(await s.meta(ADA, 2)).told, 'not told: emailed once there is an email to send');
});

test('review: the email escapes what it shows', () => {
  const { html } = reviewEmail([{ account: '<b>', pictures: [{ digest: 'ab'.repeat(32), at: '"x"', current: false }] }]);
  assert.ok(html.includes('<code>&lt;b&gt;</code>') && !html.includes('<code><b></code>'));
  assert.ok(html.includes('&quot;x&quot;') && !html.includes('"x"'));
});
