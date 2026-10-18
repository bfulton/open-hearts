// The pictures subscribers put out, kept for the operator to look at
// (review.mjs): each new one copied once, from an account, and kept
// while it is put out; and the day's email of the new ones, with the
// command that takes each down, oldest first and a hundred at a time.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PICTURES_ORIGIN, REVIEW_KEPT_DAYS, REVIEW_MOST, REVIEW_ROW, pictureKeeper, reviewEmail, reviewRun } from './review.mjs';
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

test('review: a picture from an account is copied once, with whose it is and when; nothing else is', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const keep = pictureKeeper({ bucket: b, now: () => t });
  assert.equal(await keep(picture(1), { account: ADA }), true);
  const digest = await pictureDigest(jpeg(1));
  const kept = b.objects.get(`review/${digest}.jpg`);
  assert.deepEqual(kept.customMetadata, { account: ADA, at: new Date(t).toISOString() });
  assert.equal(kept.httpMetadata.contentType, 'image/jpeg');
  assert.deepEqual([...kept.bytes], [0xff, 0xd8, 0xff, 0xe0, 1]);
  // Again, from this object — which remembers it, and asks the bucket
  // nothing — or a fresh one: not new.
  const heads = b.heads;
  assert.equal(await keep(picture(1), { account: ADA }), false);
  assert.equal(b.heads, heads, 'remembered, not asked again');
  assert.equal(await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: BAO }), false);
  assert.equal(b.objects.get(`review/${digest}.jpg`).customMetadata.account, ADA, 'the first to put it out');
  // Not a picture, not the lobby kind, nobody's account (a backup juror),
  // or no bucket: nothing.
  assert.equal(await keep({ kind: lobbyKind, content: '{"kind":"start"}' }, { account: ADA }), false);
  assert.equal(await keep(picture(2, 24245), { account: ADA }), false);
  assert.equal(await keep(picture(3), { account: null }), false);
  assert.equal(await keep(picture(4), null), false);
  assert.equal(await pictureKeeper({ bucket: null })(picture(5), { account: ADA }), false);
  assert.equal(b.objects.size, 1);
});

test('review: a picture still put out is written again now and then, with what it first said, so it is kept from its last use', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  const first = new Date(t).toISOString();
  const key = `review/${await pictureDigest(jpeg(1))}.jpg`;
  t += 3 * DAY;
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: BAO });
  assert.equal(b.objects.get(key).uploaded, Date.UTC(2026, 9, 18), 'lately written: left alone');
  t += 5 * DAY;
  assert.equal(await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: BAO }), false, 'not new');
  assert.equal(b.objects.get(key).uploaded, t, 'written again');
  assert.deepEqual(b.objects.get(key).customMetadata, { account: ADA, at: first });
});

test('review: the day\'s email has each new picture, whose it is, and the command that takes it down', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const store = memoryStore();
  // Ada's is her profile's picture; Bao's profile has another.
  await store.put(`ACCOUNT#${ADA}`, 'PROFILE', { name: 'Ada', picture: jpeg(1) });
  await store.put(`ACCOUNT#${BAO}`, 'PROFILE', { name: 'Bao', picture: jpeg(9) });
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  t += 60 * 1000;
  await pictureKeeper({ bucket: b, now: () => t })(picture(2), { account: BAO });
  t += 60 * 1000;
  const sent = [];
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: 2, more: 0 });
  assert.equal(sent.length, 1);
  const [mail] = sent;
  assert.equal(mail.subject, 'Open Hearts: 2 new pictures to look at');
  const ada = `${PICTURES_ORIGIN}/review/${await pictureDigest(jpeg(1))}.jpg`;
  const bao = `${PICTURES_ORIGIN}/review/${await pictureDigest(jpeg(2))}.jpg`;
  assert.ok(mail.text.indexOf(ada) < mail.text.indexOf(bao), 'oldest first');
  assert.match(mail.text, new RegExp(`${ada}\\n  account ${ADA}, its profile picture, first put out [^\\n]+\\n  \\./oh account remove ${ADA} picture --apply`));
  assert.match(mail.text, new RegExp(`${bao}\\n  account ${BAO}, not its profile picture now, first put out [^\\n]+\\n  \\./oh account suspend ${BAO} --apply`));
  assert.ok(mail.html.includes(`<img src="${ada}"`) && mail.html.includes(`<img src="${bao}"`));
  assert.match(mail.text, /handle-abuse-material\.md/);
  // Told once: the next day, nothing new, no email.
  t += DAY;
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: 0, more: 0 });
  assert.equal(sent.length, 1);
  assert.ok((await store.get(...REVIEW_ROW)).through);
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

test('review: a hundred at a time, the rest the next day', async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const store = memoryStore();
  for (let n = 0; n < REVIEW_MOST + 3; n++) {
    await pictureKeeper({ bucket: b, now: () => t })(picture(n), { account: ADA });
    t += 1000;
  }
  const sent = [];
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: REVIEW_MOST, more: 3 });
  assert.match(sent[0].text, /3 more will come in the next email\./);
  t += DAY;
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 0, sent: 3, more: 0 });
  assert.equal(sent[1].subject, 'Open Hearts: 3 new pictures to look at');
});

test(`review: a copy nobody has put out for ${REVIEW_KEPT_DAYS} days is deleted, and not emailed`, async () => {
  let t = Date.UTC(2026, 9, 18);
  const b = bucket(() => t);
  const store = memoryStore();
  await pictureKeeper({ bucket: b, now: () => t })(picture(1), { account: ADA });
  await reviewRun({ bucket: b, store, send: async () => {}, now: () => t });
  t += (REVIEW_KEPT_DAYS - 1) * DAY;
  await pictureKeeper({ bucket: b, now: () => t })(picture(2), { account: ADA });
  t += 2 * DAY;
  const sent = [];
  assert.deepEqual(await reviewRun({ bucket: b, store, send: async (m) => sent.push(m), now: () => t }), { deleted: 1, sent: 1, more: 0 });
  assert.equal(b.objects.size, 1);
  assert.ok(!sent[0].text.includes(await pictureDigest(jpeg(1))));
});

test('review: the email escapes what it shows', () => {
  const { html } = reviewEmail([{ digest: 'ab'.repeat(32), account: '<b>', at: '"x"', current: false }]);
  assert.ok(!html.includes('<b>') && html.includes('&lt;b&gt;') && html.includes('&quot;x&quot;'));
});
