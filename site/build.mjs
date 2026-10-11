// Builds the site into a directory, once in each language.
//
//   node site/build.mjs <out>
//
// public/ is copied as it is. Each template in pages/ is written once per
// language: English at the root, the others under /es/, /pt/, /de/ and
// /fr/. A template's words are `{{page.key}}` placeholders filled from
// strings/<lang>.json; every language must have every key English has,
// and no other. A string may use the placeholders below as well.
//
//   {{code}}        the page's language, as its path has it: en, es
//   {{lang}}        the page's language, for <html lang>
//   {{locale}}      the same, for og:locale
//   {{base}}        '' in English, '/es' in Spanish: the start of a link
//   {{url}}         the page's own address
//   {{app}}         where the app is: https://play.openhearts.game
//   {{play}}        the app, in the page's language: {{app}}/?lang=es
//   {{alternates}}  <link rel="alternate"> for each language's copy
//   {{langs}}       a link to each language's copy, the page's own marked
//   {{langName}}    the page's language, by its own name
//   {{appStore}}, {{googlePlay}}  the store, linked to the listing once it is live
//   {{appStoreBadge}}, {{googlePlayBadge}}  a badge's link, or inactive
//   {{storesSoon}}  home.soon, said under the badges while either is inactive
//   {{> name}}      pages/_name.html, filled in the same way
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const origin = 'https://openhearts.game';
/// Where the app is (docs/06-service.md, "Where the app is"). A preview
/// serves its own instead, at /play/: its worker points these links
/// there (service/functions/worker.mjs).
export const app = 'https://play.openhearts.game';

/// The apps' store listings, once they are live. Until then the site's
/// mentions of a store link to the store itself, and its badges do
/// nothing.
export const stores = { appStore: null, googlePlay: null };
const storeFronts = { appStore: 'https://www.apple.com/app-store/', googlePlay: 'https://play.google.com/store/apps' };
const storeLink = (store, name) => `<a href="${stores[store] ?? storeFronts[store]}">${name}</a>`;
const storeBadge = (url) => (url ? `href="${url}"` : 'aria-disabled="true"');

export const languages = [
  { code: 'en', lang: 'en', locale: 'en_US', name: 'English' },
  { code: 'es', lang: 'es', locale: 'es_ES', name: 'Español' },
  { code: 'pt', lang: 'pt-BR', locale: 'pt_BR', name: 'Português' },
  { code: 'de', lang: 'de', locale: 'de_DE', name: 'Deutsch' },
  { code: 'fr', lang: 'fr', locale: 'fr_FR', name: 'Français' },
];

export const strings = (code) => JSON.parse(readFileSync(join(here, 'strings', `${code}.json`), 'utf8'));

/// Every key a strings file has, as `page.key`.
export function keys(tree, prefix = '') {
  return Object.entries(tree).flatMap(([k, v]) =>
    typeof v === 'object' ? keys(v, `${prefix}${k}.`) : [`${prefix}${k}`]);
}

const lookup = (tree, key) => key.split('.').reduce((t, k) => t?.[k], tree);
const base = (code) => (code === 'en' ? '' : `/${code}`);
const pathOf = (page) => (page === 'index' ? '/' : `/${page}`);
const partial = (name) => readFileSync(join(here, 'pages', `_${name}.html`), 'utf8');

/// One page in one language.
export function render(page, language, words) {
  const path = pathOf(page);
  const builtins = {
    code: language.code,
    lang: language.lang,
    locale: language.locale,
    base: base(language.code),
    url: `${origin}${base(language.code)}${path}`,
    app,
    // The site's language is the app's: the app is at an origin of its
    // own now, and reads it from the address (app/lib/l10n/l10n.dart).
    play: `${app}/?lang=${language.code}`,
    alternates: [
      ...languages.map((l) => `<link rel="alternate" hreflang="${l.lang}" href="${origin}${base(l.code)}${path}">`),
      `<link rel="alternate" hreflang="x-default" href="${origin}${path}">`,
    ].join('\n'),
    langs: languages
      .map((l) => `<li><a href="${base(l.code)}${path}" hreflang="${l.lang}" lang="${l.lang}"` +
        `${l.code === language.code ? ' aria-current="true"' : ''}>${l.name}</a></li>`)
      .join('\n'),
    langName: language.name,
    appStore: storeLink('appStore', 'App Store'),
    googlePlay: storeLink('googlePlay', 'Google Play'),
    appStoreBadge: storeBadge(stores.appStore),
    googlePlayBadge: storeBadge(stores.googlePlay),
    storesSoon: stores.appStore && stores.googlePlay ? '' : `<p class="soon">${lookup(words, 'home.soon')}</p>`,
  };
  const fill = (text, depth = 0) => {
    if (depth > 4) throw new Error(`${page}: placeholders nested too deep`);
    return text.replace(/\{\{\s*(>\s*)?([\w.]+)\s*\}\}/g, (_, include, key) => {
      if (include) return fill(partial(key), depth + 1);
      if (key in builtins) return builtins[key];
      const value = lookup(words, key);
      if (typeof value !== 'string') throw new Error(`${language.code}: no string ${key} (${page})`);
      return fill(value, depth + 1);
    });
  };
  let html = fill(readFileSync(join(here, 'pages', `${page}.html`), 'utf8'));
  // The site's own links mark the page they are on.
  html = html.replace(
    new RegExp(`(<nav[^>]*>[\\s\\S]*?<a href="${base(language.code)}${path}")`),
    '$1 aria-current="page"',
  );
  // Each link to a stylesheet, script or picture carries its file's
  // fingerprint, so a changed one is fetched at once by a browser that
  // kept the last.
  html = html.replace(/(href|src|srcset)="\/([\w/-]+\.(?:css|js|png))/g, (_, attr, file) => {
    const hash = createHash('sha256').update(readFileSync(join(here, 'public', file))).digest('hex').slice(0, 10);
    return `${attr}="/${file}?v=${hash}`;
  });
  return html;
}

export const pages = () =>
  readdirSync(join(here, 'pages'))
    .filter((f) => f.endsWith('.html') && !f.startsWith('_'))
    .map((f) => f.slice(0, -'.html'.length));

/// What is wrong with a language's strings, against English's: a key
/// missing or extra, or a string whose markup — tags, links and
/// placeholders — is not English's, in any order. The note that a page
/// is a translation is the one string English leaves empty.
export function problems(code) {
  const english = strings('en');
  const words = strings(code);
  const want = keys(english);
  const have = keys(words);
  const found = [
    ...want.filter((k) => !have.includes(k)).map((k) => `${code}: missing ${k}`),
    ...have.filter((k) => !want.includes(k)).map((k) => `${code}: extra ${k}`),
  ];
  const markup = (text) => (text.match(/<[^>]+>|\{\{[^}]+\}\}/g) ?? []).sort().join(' ');
  for (const k of want.filter((k) => have.includes(k) && k !== 'common.translationNote')) {
    if (markup(lookup(words, k)) !== markup(lookup(english, k))) found.push(`${code}: markup differs in ${k}`);
  }
  return found;
}

export function build(out) {
  const wrong = languages.flatMap((l) => problems(l.code));
  if (wrong.length) throw new Error(wrong.join('\n'));
  cpSync(join(here, 'public'), out, { recursive: true });
  for (const language of languages) {
    const words = strings(language.code);
    const dir = join(out, base(language.code));
    mkdirSync(dir, { recursive: true });
    for (const page of pages()) writeFileSync(join(dir, `${page}.html`), render(page, language, words));
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = process.argv[2];
  if (!out) throw new Error('usage: node site/build.mjs <out>');
  build(out);
}
