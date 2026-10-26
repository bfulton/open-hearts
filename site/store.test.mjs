import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { languages, origin, pages } from './build.mjs';

// The words of the App Store and Google Play listings (store.json), held
// to what each store takes: App Store Connect's limits and rules
// (developer.apple.com/help/app-store-connect, "Platform version
// information" and "App information"), and Play Console's ("Create and
// set up your app").
const listing = JSON.parse(readFileSync(new URL('./store.json', import.meta.url), 'utf8'));

/// A field's words: a line, the lines of a list, or every entry's.
const text = (field) => (Array.isArray(field) ? field.join('\n') : typeof field === 'object' ? Object.values(field).map(text).join('\n') : field);
const length = (field) => [...text(field)].length;
const fields = (store) => languages.map((l) => [l.code, listing[l.code][store]]);

test('a listing in each of the site\'s languages, in both stores', () => {
  for (const { code } of languages) {
    assert.ok(listing[code]?.apple && listing[code]?.google, code);
    assert.ok(listing.stores.apple[code]?.length && listing.stores.google[code]?.length, `${code}: the stores' locales`);
  }
});

test('every field within its store\'s limit', () => {
  const limits = {
    apple: { name: 30, subtitle: 30, promotionalText: 170, description: 4000 },
    google: { title: 30, shortDescription: 80, fullDescription: 4000 },
  };
  for (const [store, limit] of Object.entries(limits)) {
    for (const [code, words] of fields(store)) {
      for (const [field, most] of Object.entries(limit)) {
        assert.ok(length(words[field]) > 0, `${code} ${store} ${field}: empty`);
        assert.ok(length(words[field]) <= most, `${code} ${store} ${field}: ${length(words[field])} of ${most}`);
      }
    }
  }
  // A name of two characters at least.
  for (const [code, words] of fields('apple')) assert.ok(length(words.name) >= 2, code);
});

test('Google Play\'s alt text for each picture: every screenshot the pictures script takes, and the feature graphic', () => {
  // The screenshots are e2e/store_shots.mjs's, by name.
  const shots = [...readFileSync(new URL('../e2e/store_shots.mjs', import.meta.url), 'utf8').matchAll(/^ {4}name: '(\w+)',$/gm)].map((m) => m[1]);
  assert.ok(shots.length >= 2, 'the screenshots, read from e2e/store_shots.mjs');
  for (const [code, { alt }] of fields('google')) {
    assert.deepEqual(Object.keys(alt ?? {}).sort(), [...shots, 'feature'].sort(), code);
    for (const [picture, words] of Object.entries(alt)) {
      assert.ok(length(words) > 0 && length(words) <= 140, `${code} ${picture}: ${length(words)} of 140`);
    }
  }
});

test('the App Store\'s keywords: 100 bytes at most, each more than two characters, none of the name\'s words', () => {
  for (const [code, { keywords, name }] of fields('apple')) {
    assert.ok(Buffer.byteLength(keywords) <= 100, `${code}: ${Buffer.byteLength(keywords)} bytes`);
    const named = name.toLowerCase().split(/\s+/);
    for (const keyword of keywords.split(',')) {
      assert.equal(keyword, keyword.trim(), `${code}: "${keyword}" padded`);
      assert.ok([...keyword].length > 2, `${code}: "${keyword}"`);
      for (const word of keyword.toLowerCase().split(/\s+/)) assert.ok(!named.includes(word), `${code}: "${keyword}" repeats the name`);
    }
  }
});

test('the App Store\'s words name no other platform', () => {
  // App Review Guideline 2.3.10.
  for (const [code, words] of fields('apple')) {
    for (const [field, value] of Object.entries(words)) assert.doesNotMatch(text(value), /android|google|play store/i, `${code} ${field}`);
  }
});

test('plain text, as both stores show it', () => {
  for (const store of ['apple', 'google']) {
    for (const [code, words] of fields(store)) {
      for (const [field, value] of Object.entries(words)) assert.doesNotMatch(text(value), /<\/?[a-z]/i, `${code} ${store} ${field}`);
    }
  }
});

/// A page's address in a language, as the site gives it for its own
/// (its canonical): written out here, so that it is checked, not only
/// agreed on.
const address = (page, code) => `${origin}${code === 'en' ? '' : `/${code}`}/${page === 'index' ? '' : page}`;

test('every link is to a page the site builds, by its own address, in the listing\'s language', () => {
  for (const store of ['apple', 'google']) {
    for (const [code, words] of fields(store)) {
      const built = new Set(pages().map((page) => address(page, code)));
      const links = Object.values(words).flatMap((v) => text(v).match(/https?:\/\/\S+/g) ?? []);
      assert.ok(links.length, `${code} ${store}: no links`);
      for (const link of links) assert.ok(built.has(link), `${code} ${store}: ${link} is no page of the site's in this language`);
    }
  }
});

test('the App Store\'s support, marketing and privacy policy links: those pages, in the listing\'s language', () => {
  for (const [code, words] of fields('apple')) {
    assert.equal(words.supportUrl, address('support', code), code);
    assert.equal(words.marketingUrl, address('index', code), code);
    assert.equal(words.privacyUrl, address('privacy', code), code);
  }
});

test('the details both stores share: the site\'s home and privacy policy, and a copyright as the App Store asks it', () => {
  assert.equal(listing.contact.website, address('index', 'en'));
  assert.equal(listing.contact.privacy, address('privacy', 'en'));
  assert.match(listing.contact.email, /^[^@\s]+@openhearts\.game$/);
  // The year the rights were had, then their holder, and no URL
  // (App Store Connect, "Copyright").
  assert.match(listing.copyright, /^\d{4} [^\s/:][^/:]*$/);
});
