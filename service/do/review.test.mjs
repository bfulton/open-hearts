// The pictures subscribers put out, kept for the operator to look at
// (review.mjs): each copied once, and each account's use of it noted,
// both kept while it is put out; and the day's email, account by
// account, of every picture each put out since the last — the ones it
// has since replaced too — with the commands that take them down.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PICTURES_ORIGIN, REVIEW_KEPT_DAYS, REVIEW_MOST, pictureKeeper, reviewEmail, reviewRun } from './review.mjs';
import { lobbyKind } from './relay.mjs';
import { r2 } from '../../infra/cloudflare.mjs';
import { pictureDigest } from '../functions/pictures.mjs';
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
