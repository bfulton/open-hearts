// The pictures subscribers put out, kept for the operator to look at
// (review.mjs): each copied once, and each account's use of it noted,
// both kept while it is put out; each looked at by a model as it is
// copied, and hidden if it should be; and the day's email, account by
// account, of every picture each put out since the last — the ones it
// has since replaced too — with what the check made of each, and the
// commands that take them down or put them back.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CHECK_MODEL, PICTURES_ORIGIN, REVIEW_KEPT_DAYS, REVIEW_MOST, checkPicture, hidePictures, pictureKeeper, reviewEmail, reviewRun } from './review.mjs';
import { lobbyKind } from './relay.mjs';
import { r2 } from '../../infra/cloudflare.mjs';
import { PICTURES_ROW, WITHHELD_FOR_MS, allowing, pictureDigest, withheldOf } from '../functions/pictures.mjs';
import { memoryStore } from '../functions/rows.mjs';

const DAY = 24 * 60 * 60 * 1000;
const ADA = '0a'.repeat(16);
const BAO = '0b'.repeat(16);

/// A JPEG's base64, different for each [n]: the bytes are not looked at.
const jpeg = (n) => Buffer.from([0xff, 0xd8, 0xff, 0xe0, n]).toString('base64');
const picture = (n, kind = lobbyKind) => ({ kind, content: JSON.stringify({ kind: 'picture', jpeg: jpeg(n) }) });

/// An R2 bucket in memory, with a clock for when each object was
/// written.
function bucket(clock) {
  const objects = new Map();
  return {
    objects,
    heads: 0,
    async head(key) {
      this.heads++;
      const o = objects.get(key);
      return o ? { uploaded: new Date(o.uploaded), customMetadata: { ...o.customMetadata } } : null;
    },
    async put(key, bytes, { customMetadata, httpMetadata }) {
      objects.set(key, { bytes, customMetadata: { ...customMetadata }, httpMetadata, uploaded: clock() });
    },
    async list({ prefix, cursor }) {
      const all = [...objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const from = cursor ? Number(cursor) : 0;
      const page = all.slice(from, from + 2);
      const more = from + 2 < all.length;
      return {
        objects: page.map((key) => ({ key, uploaded: new Date(objects.get(key).uploaded), customMetadata: { ...objects.get(key).customMetadata } })),
        truncated: more,
        ...(more ? { cursor: String(from + 2) } : {}),
      };
    },
    async delete(keys) {
      for (const k of [keys].flat()) objects.delete(k);
    },
  };
}

test('review: the copies are served where the bucket\'s custom domain is', () => {
  const pictures = r2.find((b) => b.name === 'open-hearts-pictures');
  assert.deepEqual(pictures.customDomains, [new URL(PICTURES_ORIGIN).host]);
  assert.equal(pictures.publicDevUrl, false);
});

const copyOf = async (n) => `review/${await pictureDigest(jpeg(n))}.jpg`;
const useOf = async (account, n) => `seen/${account}/${await pictureDigest(jpeg(n))}`;
const urlOf = async (n) => `${PICTURES_ORIGIN}/${await copyOf(n)}`;

test('review: a picture is copied once, and each account\'s use of it noted once; nothing else is', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const keep = pictureKeeper({ bucket: b, now: () => t });
  assert.equal(await keep(picture(1), { account: ADA }), true);
  const copy = b.objects.get(await copyOf(1));
  assert.deepEqual(copy.customMetadata, { at: new Date(t).toISOString() });
  assert.equal(copy.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...copy.bytes], [0xff, 0xd8, 0xff, 0xe0, 1]);
  assert.deepEqual(b.objects.get(await useOf(ADA, 1)).customMetadata, { at: new Date(t).toISOString() });
  // Again from Ada, from this object — which remembers, and asks the
  // bucket nothing — or a fresh one: not new.
  const heads = b.heads;
  assert.equal(await keep(picture(1), { account: ADA }), false);
  assert.equal(b.heads, heads, 'remembered, not asked again');
  assert.equal(await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA }), false);
  // The same picture from Bao is Bao's use: noted too, the copy kept as it was.
  t += 1000;
  assert.equal(await keep(picture(1), { account: BAO }), true);
  assert.deepEqual(b.objects.get(await useOf(BAO, 1)).customMetadata, { at: new Date(t).toISOString() });
  assert.equal(b.objects.get(await copyOf(1)).customMetadata.at, new Date(Date.UTC(2026, 9, 18)).toISOString());
  // Not a picture, not the lobby kind, nobody's account (a backup juror),
  // or no bucket: nothing.
  const before = b.objects.size;
  assert.equal(await keep({ kind: lobbyKind, content: '{"kind":"start"}' }, { account: ADA }), false);
  assert.equal(await keep(picture(2, 24245), { account: ADA }), false);
  assert.equal(await keep(picture(3), { account: null }), false);
  assert.equal(await keep(picture(4), null), false);
  assert.equal(await pictureKeeper({ bucket: null })(picture(5), { account: ADA }), false);
  assert.equal(b.objects.size, before);
});

test('review: what is still put out is written again now and then, with what it first said, so it is kept from its last use', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  const first = { at: new Date(t).toISOString() };
  t += 3 * DAY;
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  assert.equal(b.objects.get(await copyOf(1)).uploaded, Date.UTC(2026, 9, 18), 'lately written: left alone');
  t += 5 * DAY;
  assert.equal(await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA }), false, 'not new');
  for (const key of [await copyOf(1), await useOf(ADA, 1)]) {
    assert.equal(b.objects.get(key).uploaded, t, `${key} written again`);
    assert.deepEqual(b.objects.get(key).customMetadata, first);
  }
});

test('review: a picture swapped back before the email is in it — every picture each account put out, account by account', async () => {
  let t = Date.UTC(2026, 9, 18, 9);
  const b = bucket(() => t);
  const store = memoryStore();
  const run = (sent) => reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t });
  const put = async (n, account) => {
    await pictureKeeper({ bucket: b, now: () => t })(picture(n), { account });
    t += 60 * 1000;
  };
  // Day one: Ada's picture is 1, and the operator is told of it.
  await put(1, ADA);
  await store.put(`ACCOUNT#${ADA}`, 'PROFILE', { name: 'Ada', picture: jpeg(1) });
  await run([]);
  // Day two: Ada puts out 2, then 3, then 1 again, which is her
  // profile's by the email; Bao puts out 3 as well, and it is his.
  t += DAY;
  await put(2, ADA);
  await put(3, ADA);
  await put(3, BAO);
  await put(1, ADA);
  await store.put(`ACCOUNT#${BAO}`, 'PROFILE', { name: 'Bao', picture: jpeg(3) });
  const sent = [];
  assert.deepEqual(await run(sent), { deleted: 0, sent: 3, more: 0 });
  const [mail] = sent;
  assert.equal(mail.subject, 'Open Hearts: 3 new pictures to look at, from 2 accounts');
  // Ada first, with both she put out, in order, neither her profile's
  // now, and no take-off command: suspension. Then Bao's, his profile's.
  const ada = mail.text.indexOf(`Account ${ADA}: 2 pictures`);
  const bao = mail.text.indexOf(`Account ${BAO}: 1 picture`);
  assert.ok(ada > 0 && bao > ada, 'account by account, oldest first');
  const adaPart = mail.text.slice(ada, bao);
  assert.ok(adaPart.indexOf(await urlOf(2)) < adaPart.indexOf(await urlOf(3)), 'in the order she put them out');
  assert.match(adaPart, /no longer its profile picture/);
  assert.ok(!adaPart.includes(await urlOf(1)), 'what she was told of before is not news');
  assert.ok(!adaPart.includes('account remove'));
  assert.ok(adaPart.includes(`./oh account suspend ${ADA} --apply`));
  const baoPart = mail.text.slice(bao);
  assert.ok(baoPart.includes(await urlOf(3)) && baoPart.includes('its profile picture now'));
  assert.ok(baoPart.includes(`./oh account remove ${BAO} picture --apply`));
  assert.ok(mail.html.includes(`<img src="${await urlOf(2)}"`) && mail.html.includes(`<img src="${await urlOf(3)}"`));
  assert.match(mail.text, /handle-abuse-material\.md/);
  // Told once: the next day, nothing new, no email.
  t += DAY;
  const again = [];
  assert.deepEqual(await run(again), { deleted: 0, sent: 0, more: 0 });
  assert.equal(again.length, 0);
});

test('review: an email that does not go is sent again the next day', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const store = memoryStore();
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  await assert.rejects(reviewRun({ bucket: b, store, send: async () => { throw new Error('no mail today'); }, now: () => t }));
  const sent = [];
  t += DAY;
  assert.equal((await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t })).sent, 1);
});

test('review: whole accounts, up to a hundred pictures; the rest the next day, and one account is never split', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const store = memoryStore();
  const CY = '0c'.repeat(16);
  // Ada 60, Bao 50, Cy 3: Ada alone fits; Bao would pass a hundred.
  for (const [account, n0, count] of [[ADA, 0, 60], [BAO, 100, 50], [CY, 200, 3]]) {
    for (let n = n0; n < n0 + count; n++) {
      await pictureKeeper({ bucket: b, now: () => t })(picture(n), { account });
      t += 1000;
    }
  }
  const sent = [];
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: 60, more: 53 });
  assert.match(sent[0].text, /53 more will come in the next email\./);
  t += DAY;
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: 53, more: 0 });
  // And an account of more than a hundred goes whole, on its own.
  for (let n = 300; n < 300 + REVIEW_MOST + 5; n++) await pictureKeeper({ bucket: b, now: () => t })(picture(n), { account: CY });
  t += DAY;
  assert.equal((await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t })).sent, REVIEW_MOST + 5);
});

test(`review: copies and notes nobody has put out for ${REVIEW_KEPT_DAYS} days are deleted, and not emailed`, async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const store = memoryStore();
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  await reviewRun({ bucket: b, store, send: async () => {}, now: () => t });
  t += (REVIEW_KEPT_DAYS - 1) * DAY;
  await pictureKeeper({ bucket: b, now: () => t })(picture(2), { account: ADA });
  t += 2 * DAY;
  const sent = [];
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 2, sent: 1, more: 0 });
  assert.deepEqual([...b.objects.keys()].sort(), [await copyOf(2), await useOf(ADA, 2)].sort());
  assert.ok(!sent[0].text.includes(await pictureDigest(jpeg(1))));
});

test('review: the email escapes what it shows', () => {
  const { html } = reviewEmail([{ account: '<b>', pictures: [{ digest: 'ab'.repeat(32), at: '"x"', current: false }] }]);
  assert.ok(html.includes('<code>&lt;b&gt;</code>') && !html.includes('<code><b></code>'));
  assert.ok(html.includes('&quot;x&quot;') && !html.includes('"x"'));
});

/// Workers AI's binding, answering each picture (its base64) as
/// [answer] says: {sexual, gore, hate}, or an Error to throw.
function fakeAi(answer) {
  const calls = [];
  return {
    calls,
    async run(model, input) {
      calls.push({ model, input });
      const said = answer(input.images[0].slice('data:image/jpeg;base64,'.length));
      if (said instanceof Error) throw said;
      return { model: 'clef-flash', answers: Object.fromEntries(Object.entries(said).map(([id, p]) => [id, { type: 'noul', noul: p }])) };
    },
  };
}

const harmless = { sexual: 0.01, gore: 0.01, hate: 0.01 };
const digestOf = (n) => pictureDigest(jpeg(n));
const withheldIn = async (store, t) => withheldOf(await store.get(...PICTURES_ROW), t);

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

test('review: a picture the check takes for nudity, gore or a hate symbol is hidden as it is copied, and checked once', async () => {
  const t = Date.UTC(2026, 9, 19);
  const b = bucket(() => t);
  const store = memoryStore();
  const scores = { [jpeg(1)]: harmless, [jpeg(2)]: { ...harmless, hate: 0.94 }, [jpeg(3)]: { ...harmless, sexual: 0.5 }, [jpeg(4)]: { ...harmless, gore: 0.49 } };
  const ai = fakeAi((p) => scores[p]);
  const keep = pictureKeeper({ bucket: b, ai, hide: (d) => hidePictures(store, [d], t), now: () => t });
  for (const n of [1, 2, 3, 4]) assert.equal(await keep(picture(n), { account: ADA }), true);
  assert.deepEqual(b.objects.get(await copyOf(1)).customMetadata, { at: new Date(t).toISOString(), check: 'sexual=0.010 gore=0.010 hate=0.010' });
  assert.equal(b.objects.get(await copyOf(2)).customMetadata.check, 'sexual=0.010 gore=0.010 hate=0.940');
  assert.deepEqual([...(await withheldIn(store, t))].sort(), [await digestOf(2), await digestOf(3)].sort(), '0.5 hides; 0.49 does not');
  // The same pictures from Bao: copied already, so not checked again.
  for (const n of [1, 2]) await keep(picture(n), { account: BAO });
  assert.equal(ai.calls.length, 4);
  // No model bound: copied, and nothing said of it.
  await pictureKeeper({ bucket: b, now: () => t })(picture(5), { account: ADA });
  assert.deepEqual(b.objects.get(await copyOf(5)).customMetadata, { at: new Date(t).toISOString() });
});

test('review: a hidden picture is hidden again whenever it comes back, its 30 days run out; one the operator allowed is not', async () => {
  let t = Date.UTC(2026, 9, 19);
  const b = bucket(() => t);
  const store = memoryStore();
  const ai = fakeAi(() => ({ ...harmless, sexual: 0.93 }));
  const keep = pictureKeeper({ bucket: b, ai, hide: (d) => hidePictures(store, [d], t), now: () => t });
  await keep(picture(1), { account: ADA });
  await keep(picture(2), { account: ADA });
  const [one, two] = [await digestOf(1), await digestOf(2)];
  assert.deepEqual([...(await withheldIn(store, t))], [one, two]);
  // Not done with until the relay withholds it: put out again before
  // the relay has the list, it is looked at again.
  const heads = b.heads;
  await keep(picture(1), { account: ADA });
  assert.ok(b.heads > heads, 'looked at again');
  // The operator allows 2, and a daily run on day 29 keeps it allowed,
  // its copy being kept. Then the 30 days run out, and 1 comes back,
  // from this object, which a withheld picture never reached.
  await store.put(...PICTURES_ROW, allowing(await store.get(...PICTURES_ROW), two, t));
  const start = t;
  t += 29 * DAY;
  await reviewRun({ bucket: b, store, send: async () => {}, now: () => t });
  t = start + WITHHELD_FOR_MS + 1000;
  assert.deepEqual([...(await withheldIn(store, t))], []);
  await keep(picture(1), { account: ADA });
  await keep(picture(2), { account: ADA });
  assert.deepEqual([...(await withheldIn(store, t))], [one], 'hidden again, from what the copy says; 2 still allowed');
  assert.equal(ai.calls.length, 2, 'not checked again');
  // Allowed, it is done with: put out again, nothing is asked.
  const after = b.heads;
  await keep(picture(2), { account: ADA });
  assert.equal(b.heads, after);
});

test('review: a check or a hiding that fails is logged and the picture kept; the daily run hides it all the same', async () => {
  const t = Date.UTC(2026, 9, 19);
  const b = bucket(() => t);
  const store = memoryStore();
  const logs = [];
  const ai = fakeAi((p) => (p === jpeg(1) ? new Error('model down') : p === jpeg(2) ? { ...harmless, gore: 0.9 } : harmless));
  const keep = pictureKeeper({ bucket: b, ai, hide: async () => { throw new Error('store down'); }, log: (l) => logs.push(l), now: () => t });
  assert.equal(await keep(picture(1), { account: ADA }), true);
  assert.equal(b.objects.get(await copyOf(1)).customMetadata.check, 'failed');
  assert.equal(await keep(picture(2), { account: ADA }), true);
  assert.deepEqual(logs, ['picture not checked: Error: model down', 'picture not hidden: Error: store down']);
  assert.equal(await store.get(...PICTURES_ROW), null);
  // A copy that cannot be written is not remembered: tried again.
  const put = b.put;
  b.put = async () => { throw new Error('bucket down'); };
  await assert.rejects(keep(picture(3), { account: ADA }), /bucket down/);
  b.put = put;
  assert.equal(await keep(picture(3), { account: ADA }), true);

  const sent = [];
  await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t });
  const [one, two] = [await digestOf(1), await digestOf(2)];
  assert.deepEqual([...(await withheldIn(store, t))], [two]);
  const [mail] = sent;
  assert.equal(mail.subject, 'Open Hearts: 3 new pictures to look at, from 1 account, 1 hidden by the check');
  assert.match(mail.text, new RegExp(`${one}\\.jpg .*not checked: the check failed`));
  assert.match(mail.text, new RegExp(`${two}\\.jpg .*hidden by the check for violence or gore \\(0\\.90\\)`));
  assert.ok(mail.text.includes(`./oh picture allow ${two} --apply`));
  assert.ok(!mail.text.includes(`./oh picture allow ${one}`));
});

test('review: accounts with a picture hidden as nudity or sexual content come first, in the first email; one put back is marked so', async () => {
  let t = Date.UTC(2026, 9, 19);
  const b = bucket(() => t);
  const store = memoryStore();
  const CY = '0c'.repeat(16);
  // Ada 60 harmless; Bao 50, the last hidden as sexual; Cy 1, hidden as
  // sexual and allowed by the operator before the email.
  const ai = fakeAi((p) => (p === jpeg(149) || p === jpeg(200) ? { ...harmless, sexual: 0.93 } : harmless));
  const keep = pictureKeeper({ bucket: b, ai, hide: (d) => hidePictures(store, [d], t), now: () => t });
  for (const [account, n0, count] of [[ADA, 0, 60], [BAO, 100, 50], [CY, 200, 1]]) {
    for (let n = n0; n < n0 + count; n++) {
      await keep(picture(n), { account });
      t += 1000;
    }
  }
  const allowed = await digestOf(200);
  await store.put(...PICTURES_ROW, allowing(await store.get(...PICTURES_ROW), allowed, t));
  const sent = [];
  // Bao alone, though Ada put hers out before, and Cy's is not urgent:
  // whole accounts in order, and Ada would pass a hundred.
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: 50, more: 61 });
  const [mail] = sent;
  assert.equal(mail.subject, 'Urgent: Open Hearts: 50 new pictures to look at, from 1 account, 1 hidden by the check');
  assert.match(mail.text, /^The automatic check hid 1 picture as nudity or sexual content; the accounts that put them out are first\. Look at them now\./);
  assert.match(mail.text, new RegExp(`${await digestOf(149)}\\.jpg .*hidden by the check for nudity or sexual content \\(0\\.93\\)`));
  assert.ok(mail.text.includes(`./oh picture allow ${await digestOf(149)} --apply`));
  assert.match(mail.html, /<b style="color:#b00020">The automatic check hid 1 picture/);
  assert.deepEqual([...(await withheldIn(store, t))], [await digestOf(149)], 'what the operator allowed stays shown');
  // The next day: Ada's and Cy's, nothing urgent, Cy's marked as put back.
  t += DAY;
  await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t });
  const next = sent[1];
  assert.equal(next.subject, 'Open Hearts: 61 new pictures to look at, from 2 accounts');
  assert.ok(!next.text.includes('automatic check hid') && !next.html.includes('#b00020'));
  assert.match(next.text, new RegExp(`${allowed}\\.jpg .*put back by you after the check hid it for nudity or sexual content \\(0\\.93\\)`));
  assert.ok(!next.text.includes(`./oh picture allow ${allowed}`));
});

test('review: what the operator allowed stays allowed while its copy is kept, and no longer once it is deleted', async () => {
  let t = Date.UTC(2026, 9, 19);
  const b = bucket(() => t);
  const store = memoryStore();
  const ai = fakeAi(() => ({ ...harmless, hate: 0.9 }));
  const keep = pictureKeeper({ bucket: b, ai, hide: (d) => hidePictures(store, [d], t), now: () => t });
  await keep(picture(1), { account: ADA });
  const [one, two] = [await digestOf(1), await digestOf(2)];
  // 1, allowed on day 5, is not put out again; 2 is put out on day 29,
  // and allowed too.
  const start = t;
  t += 5 * DAY;
  await store.put(...PICTURES_ROW, allowing(await store.get(...PICTURES_ROW), one, t));
  t = start + 29 * DAY;
  await keep(picture(2), { account: ADA });
  await store.put(...PICTURES_ROW, allowing(await store.get(...PICTURES_ROW), two, t));
  t = start + 31 * DAY;
  await reviewRun({ bucket: b, store, send: async () => {}, now: () => t });
  assert.ok(!b.objects.has(await copyOf(1)), "1's copy deleted");
  const row = await store.get(...PICTURES_ROW);
  assert.deepEqual(
    row.allowed.map((a) => [a.sha256, a.until]),
    [[one, start + 5 * DAY + WITHHELD_FOR_MS], [two, t + WITHHELD_FOR_MS]],
    "2's kept allowed from today; 1's left to run out",
  );
});
