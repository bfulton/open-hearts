// Builds the site into a directory, once in each language.
//
//   node site/build.mjs <out>
//
// public/ is copied as it is. Each template in pages/ is written once per
// language: English at the root, the others under /es/, /pt/, /de/ and
// /fr/; sitemap.xml lists every page so written, and robots.txt names
// it. A template's words are `{{page.key}}` placeholders filled from
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
//   {{price}}       what a year of live play costs on the web, written the
//                   language's way: config/openhearts.json's `price`
//   {{updated.terms}}, {{updated.privacy}}  the day the document's newest
//                   version in ledger.json was published, in the language
//   {{> name}}      pages/_name.html, filled in the same way
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
/// Where the site is. The service's emails and Stripe's checkout link
/// its pages here too (SITE, service/functions/settings.mjs).
export const origin = 'https://openhearts.game';
/// Where the app is (docs/explanation/service.md, "Where the app is"). A preview
/// serves its own instead, at /play/: its worker points these links
/// there (service/functions/app_host.mjs).
export const app = 'https://play.openhearts.game';

/// The apps' store listings, once they are live. Until then the site's
/// mentions of a store link to the store itself, and its badges do
/// nothing.
export const stores = { appStore: null, googlePlay: null };
const storeFronts = { appStore: 'https://www.apple.com/app-store/', googlePlay: 'https://play.google.com/store/apps' };
const storeLink = (store, name) => `<a href="${stores[store] ?? storeFronts[store]}">${name}</a>`;
const storeBadge = (url) => (url ? `href="${url}"` : 'aria-disabled="true"');

/// Each language, with how it writes US dollars and a day. Written out
/// rather than asked of Intl, whose answer moves with the ICU a Node
/// has: these are in the terms, whose every word is fingerprinted
/// (ledger.mjs).
export const languages = [
  {
    code: 'en', lang: 'en', locale: 'en_US', name: 'English',
    usd: (whole, cents) => `$${whole}.${cents}`,
    day: (d, m, y) => `${d} ${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][m]} ${y}`,
  },
  {
    code: 'es', lang: 'es', locale: 'es_ES', name: 'Español',
    usd: (whole, cents) => `${whole},${cents} US$`,
    day: (d, m, y) => `${d} de ${['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'][m]} de ${y}`,
  },
  {
    code: 'pt', lang: 'pt-BR', locale: 'pt_BR', name: 'Português',
    usd: (whole, cents) => `US$ ${whole},${cents}`,
    day: (d, m, y) => `${d} de ${['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'][m]} de ${y}`,
  },
  {
    code: 'de', lang: 'de', locale: 'de_DE', name: 'Deutsch',
    usd: (whole, cents) => `${whole},${cents} US$`,
    day: (d, m, y) => `${d}. ${['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'][m]} ${y}`,
  },
  {
    code: 'fr', lang: 'fr', locale: 'fr_FR', name: 'Français',
    usd: (whole, cents) => `${whole},${cents} $ US`,
    day: (d, m, y) => `${d === 1 ? '1er' : d} ${['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'][m]} ${y}`,
  },
];

/// The committed configuration (config/openhearts.json).
export const config = () => JSON.parse(readFileSync(join(here, '..', 'config', 'openhearts.json'), 'utf8'));

/// The published versions of the terms and the privacy policy (ledger.mjs).
export const ledger = () => JSON.parse(readFileSync(join(here, 'ledger.json'), 'utf8'));

/// [price] — {amount, currency}, the amount in cents — as [language]
/// writes it. Only US dollars: the terms sell in them, and another
/// currency would need its words in every language.
export function priceIn(language, price) {
  if (price?.currency !== 'usd' || !Number.isInteger(price.amount) || price.amount <= 0) {
    throw new Error(`config/openhearts.json: price must be {"amount": <cents>, "currency": "usd"}, not ${JSON.stringify(price)}`);
  }
  return language.usd(Math.floor(price.amount / 100), String(price.amount % 100).padStart(2, '0'));
}

/// [date] (YYYY-MM-DD) as [language] writes a day.
export function dayIn(language, date) {
  const [y, m, d] = date.split('-').map(Number);
  return language.day(d, m - 1, y);
}

export const strings = (code) => JSON.parse(readFileSync(join(here, 'strings', `${code}.json`), 'utf8'));

/// Every key a strings file has, as `page.key`.
export function keys(tree, prefix = '') {
  return Object.entries(tree).flatMap(([k, v]) =>
    typeof v === 'object' ? keys(v, `${prefix}${k}.`) : [`${prefix}${k}`]);
}

const lookup = (tree, key) => key.split('.').reduce((t, k) => t?.[k], tree);
const base = (code) => (code === 'en' ? '' : `/${code}`);
const pathOf = (page) => (page === 'index' ? '/' : `/${page}`);
/// A page's address in a language: its canonical there.
const urlOf = (page, code) => `${origin}${base(code)}${pathOf(page)}`;
/// Each copy of a page, as [hreflang, address]: one per language, then
/// the one for a reader of none of them.
const alternatesOf = (page) => [...languages.map((l) => [l.lang, urlOf(page, l.code)]), ['x-default', urlOf(page, 'en')]];
const partial = (name) => readFileSync(join(here, 'pages', `_${name}.html`), 'utf8');

/// One page in one language. [price] and [published] — the ledger's
/// documents — are the committed ones unless given.
export function render(page, language, words, { price = config().price, published = ledger() } = {}) {
  const path = pathOf(page);
  const newest = (doc) => published[doc].at(-1).date;
  const builtins = {
    code: language.code,
    lang: language.lang,
    locale: language.locale,
    base: base(language.code),
    url: urlOf(page, language.code),
    app,
    // The site's language is the app's: the app is at an origin of its
    // own now, and reads it from the address (app/lib/l10n/l10n.dart).
    play: `${app}/?lang=${language.code}`,
    alternates: alternatesOf(page).map(([hreflang, href]) => `<link rel="alternate" hreflang="${hreflang}" href="${href}">`).join('\n'),
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
    price: priceIn(language, price),
    'updated.terms': dayIn(language, newest('terms')),
    'updated.privacy': dayIn(language, newest('privacy')),
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
  // The site's own links, in every nav, mark the page they are on.
  const self = `<a href="${base(language.code)}${path}"`;
  html = html.replace(/<nav[^>]*>[\s\S]*?<\/nav>/g, (nav) => nav.replaceAll(self, `${self} aria-current="page"`));
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

/// sitemap.xml: every page in every language, by its canonical, each
/// with the copies its own head names, as a search engine takes them
/// from a sitemap.
export function sitemap() {
  const entry = (page, language) => [
    '  <url>',
    `    <loc>${urlOf(page, language.code)}</loc>`,
    ...alternatesOf(page).map(([hreflang, href]) => `    <xhtml:link rel="alternate" hreflang="${hreflang}" href="${href}"/>`),
    '  </url>',
  ];
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    ...pages().flatMap((page) => languages.flatMap((language) => entry(page, language))),
    '</urlset>',
    '',
  ].join('\n');
}

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
  writeFileSync(join(out, 'sitemap.xml'), sitemap());
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = process.argv[2];
  if (!out) throw new Error('usage: node site/build.mjs <out>');
  build(out);
}
