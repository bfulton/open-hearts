// The pictures accounts set, kept for the operator to look at
// (review.mjs, profile_pictures.mjs): the day's run keeps each for a
// year after it stops being its account's and no longer, squares the
// notes with the profiles, asks PhotoDNA again about what it has not
// cleared, keeps hidden what the check found should be, and emails the
// operator, account by account, every picture each set since the last —
// the ones it has since replaced too — with what the check made of each,
// and the commands that take them down or put them back.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CHECK_MODEL, PICTURES_ORIGIN, PICTURE_KEPT_DAYS, REVIEW_MOST, checkPicture, reviewEmail, reviewRun } from './review.mjs';
import { accountPictures } from './profile_pictures.mjs';
import { ADA, BAO, CY, DAY, bucket, fakeAi, harmless, jpeg } from './pictures.fixtures.mjs';
import { r2 } from '../../infra/cloudflare.mjs';
import { HOLD_DAYS } from '../functions/holds.mjs';
import { PICTURES_ROW, WITHHELD_FOR_MS, allowing, pictureDigest, withheldOf } from '../functions/pictures.mjs';
import { memoryStore } from '../functions/rows.mjs';

const copyOf = async (n) => `review/${await pictureDigest(jpeg(n))}.jpg`;
const noteOf = async (account, n) => `account/${account}/${await pictureDigest(jpeg(n))}`;
const urlOf = async (n) => `${PICTURES_ORIGIN}/${await copyOf(n)}`;
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
    const was = await store.get(`ACCOUNT#${account}`, 'PROFILE');
    const picture = await pictures.set({ account, picture: n === null ? null : jpeg(n), prev: was?.picture ?? null });
    await store.put(`ACCOUNT#${account}`, 'PROFILE', { name: account.slice(0, 4), picture });
    t.now += 60 * 1000;
  };
  const run = (sent = [], more = {}) => reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t.now, ...more });
  return { t, b, store, set, run };
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
  assert.ok(adaPart.indexOf(await urlOf(2)) < adaPart.indexOf(await urlOf(3)), 'in the order she set them');
  assert.match(adaPart, /no longer its profile picture/);
  assert.ok(!adaPart.includes(await urlOf(1)), 'what she was told of before is not news');
  assert.ok(!adaPart.includes('account remove'));
  assert.ok(adaPart.includes(`./oh account suspend ${ADA} --apply`));
  const baoPart = mail.text.slice(bao);
  assert.ok(baoPart.includes(await urlOf(3)) && baoPart.includes('its profile picture now'));
  assert.ok(baoPart.includes(`./oh account remove ${BAO} picture --apply`));
  assert.ok(mail.html.includes(`<img src="${await urlOf(2)}"`) && mail.html.includes(`<img src="${await urlOf(3)}"`));
  assert.match(mail.text, /handle-abuse-material\.md/);
  assert.match(mail.text, /Every picture each account set since the last email/);
  // Told once, and the note says so without forgetting the rest.
  const note = s.b.objects.get(await noteOf(ADA, 2)).customMetadata;
  assert.deepEqual(Object.keys(note).sort(), ['at', 'replaced', 'told']);
  assert.equal(note.told, iso(s.t.now));
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

test("review: a picture is kept a year after it stops being its account's, and no longer; its copy goes with the last note that names it, but never as it is being made", async () => {
  const s = setUp();
  const start = s.t.now;
  await s.set(ADA, 1);
  await s.set(BAO, 1);
  s.t.now = start + DAY;
  await s.set(ADA, 2);
  const replaced = s.t.now - 60 * 1000;
  // A copy with no note yet, as the account's turn writes it a moment
  // before the note.
  await s.b.put(await copyOf(9), new Uint8Array([1]), { customMetadata: { at: iso(s.t.now) } });
  await s.run();
  assert.ok(s.b.objects.has(await copyOf(9)), 'being made: left alone');

  s.t.now = replaced + (PICTURE_KEPT_DAYS - 1) * DAY;
  assert.equal((await s.run()).deleted, 1, 'the copy with no note, settled');
  assert.ok(s.b.objects.has(await noteOf(ADA, 1)), 'a day short of a year: kept');
  s.t.now = replaced + PICTURE_KEPT_DAYS * DAY;
  assert.equal((await s.run()).deleted, 1);
  assert.ok(!s.b.objects.has(await noteOf(ADA, 1)), 'a year: gone');
  assert.ok(s.b.objects.has(await copyOf(1)), "Bao's still: the copy kept");
  assert.ok(s.b.objects.has(await noteOf(ADA, 2)) && s.b.objects.has(await noteOf(BAO, 1)), 'what is theirs now is kept for as long as it is');

  // Bao deleted: his picture is no longer his from the next run, and a
  // year on it goes, and its copy with it.
  await s.store.del(`ACCOUNT#${BAO}`, 'PROFILE');
  await s.run();
  const gone = s.t.now;
  assert.equal(s.b.objects.get(await noteOf(BAO, 1)).customMetadata.replaced, iso(gone));
  s.t.now = gone + PICTURE_KEPT_DAYS * DAY;
  assert.equal((await s.run()).deleted, 2);
  assert.deepEqual([...s.b.objects.keys()].sort(), [await copyOf(2), await noteOf(ADA, 2)].sort());
});

test("review: a note is squared with its account's profile once it has settled, and only ever made to say the picture is no longer the account's", async () => {
  const s = setUp();
  await s.set(ADA, 1);
  await s.set(BAO, 2);
  // Ada's profile gone, Bao's picture taken off it, by whatever did it.
  await s.store.del(`ACCOUNT#${ADA}`, 'PROFILE');
  await s.store.put(`ACCOUNT#${BAO}`, 'PROFILE', { name: 'Bao', picture: null });
  await s.run();
  assert.ok(!s.b.objects.get(await noteOf(ADA, 1)).customMetadata.replaced, 'written within the day: left alone');
  s.t.now += DAY;
  await s.run();
  assert.equal(s.b.objects.get(await noteOf(ADA, 1)).customMetadata.replaced, iso(s.t.now));
  assert.equal(s.b.objects.get(await noteOf(BAO, 2)).customMetadata.replaced, iso(s.t.now));
  // Bao's profile with 2 again, though nothing set it: still not his,
  // since only his turn makes a picture his, as it checks it.
  await s.store.put(`ACCOUNT#${BAO}`, 'PROFILE', { name: 'Bao', picture: jpeg(2) });
  s.t.now += DAY;
  await s.run();
  assert.ok(s.b.objects.get(await noteOf(BAO, 2)).customMetadata.replaced);
});

test('review: PhotoDNA is asked again about each picture an account has now that it has not cleared, for each account; a match is no longer theirs, and never emailed', async () => {
  const s = setUp({ ask: async () => 'off' });
  await s.set(ADA, 1);
  await s.set(BAO, 1);
  await s.set(CY, 2);
  await s.set(CY, 3);
  const asked = [];
  const answers = { [jpeg(1)]: 'match', [jpeg(3)]: 'clear' };
  const ask = async (a) => (asked.push(a), answers[a.jpeg]);
  const at = async (account, n) => s.b.objects.get(await noteOf(account, n)).customMetadata.at;
  const when = [await at(ADA, 1), await at(BAO, 1), await at(CY, 3)];
  const sent = [];
  assert.deepEqual(await s.run(sent, { ask }), { deleted: 0, asked: 3, sent: 2, more: 0 });
  const order = (rows) => rows.map((r) => JSON.stringify(r)).sort();
  assert.deepEqual(
    order(asked.map((a) => [a.jpeg, a.account, a.key, a.shown, a.at])),
    order([
      [jpeg(1), ADA, null, true, when[0]],
      [jpeg(1), BAO, null, true, when[1]],
      [jpeg(3), CY, null, true, when[2]],
    ]),
    "each account with the match, each with when it set it; 2, no longer anybody's, not asked",
  );
  for (const account of [ADA, BAO]) assert.equal(s.b.objects.get(await noteOf(account, 1)).customMetadata.replaced, iso(s.t.now));
  const three = s.b.objects.get(await copyOf(3));
  assert.equal(three.customMetadata.known, 'clear');
  assert.equal(three.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...three.bytes], [...Buffer.from(jpeg(3), 'base64')]);
  assert.ok(!sent[0].text.includes(await digestOf(1)), 'the match never emailed');
  assert.ok(sent[0].text.includes(await digestOf(2)) && sent[0].text.includes(await digestOf(3)));
  // Asked once: 3 is cleared, and 1 nobody's.
  s.t.now += DAY;
  assert.equal((await s.run([], { ask })).asked, 0);

  // Without its key, not answering, or out of reach: tried tomorrow.
  for (const said of ['off', 'failed', new Error('said 503')]) {
    const t = setUp({ ask: async () => 'off' });
    await t.set(ADA, 1);
    await t.set(BAO, 1);
    const tried = [];
    const r = await t.run([], { ask: async (a) => (tried.push(a.account), said instanceof Error ? Promise.reject(said) : said) });
    assert.deepEqual(tried, [ADA], String(said));
    assert.equal(r.asked, said instanceof Error ? 0 : 1);
    assert.equal(t.b.objects.get(await copyOf(1)).customMetadata.known, 'off');
    assert.ok(!t.b.objects.get(await noteOf(ADA, 1)).customMetadata.replaced);
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

test('review: what the operator allowed stays allowed while its copy is kept, and no longer once it is deleted', async () => {
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
  assert.ok(!s.b.objects.has(await copyOf(1)), "1's copy deleted");
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
  assert.deepEqual(await reviewRun({ bucket: s.b, store: s.store, now: () => s.t.now }), { deleted: 2, asked: 0, sent: 0, more: 0 });
  assert.ok(!s.b.objects.get(await noteOf(ADA, 2)).customMetadata.told, 'not told: emailed once there is an email to send');
});

test('review: the email escapes what it shows', () => {
  const { html } = reviewEmail([{ account: '<b>', pictures: [{ digest: 'ab'.repeat(32), at: '"x"', current: false }] }]);
  assert.ok(html.includes('<code>&lt;b&gt;</code>') && !html.includes('<code><b></code>'));
  assert.ok(html.includes('&quot;x&quot;') && !html.includes('"x"'));
});
