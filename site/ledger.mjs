// The published versions of the terms of use and the privacy policy
// (ledger.json): one entry for each version, oldest first, so that no
// change to either reaches the site without being written down, and a
// change that matters to subscribers is told to them
// (docs/how-to/change-the-terms.md).
//
// An entry is {date, fingerprint, change, summary, storesNotified} and,
// for the terms, the price they state, and for a version published on
// the day of the one before, its revision:
//
//   date            the day it was published, YYYY-MM-DD: the page's
//                   "Last updated" is filled from the newest entry
//   revision        which of its day's versions it is, from 2 for the
//                   second: absent on a day's first (versionOf)
//   fingerprint     what the text says in every language (fingerprintOf)
//   change          what kind of change it is from the entry before:
//                   first, the ledger's first entry; minor, wording that
//                   changes nobody's rights or duties; material, one that
//                   does, told to every subscriber; price, a new price,
//                   told as a material change is
//   summary         what changed, a sentence or two in each language: the
//                   notice a subscriber is sent and shown, plain text
//   storesNotified  the day the App Store and Google Play were told of a
//                   material change, or null
//   price           {amount, currency}: what the terms say a year costs
//                   on the web (config/openhearts.json)
//
// ledger.test.mjs holds the text to the newest entry and the entries to
// what main has; the deploy holds the site to them (ops/gate.mjs).
import { createHash } from 'node:crypto';

import { languages, render, strings } from './build.mjs';

/// The documents, by their page.
export const DOCUMENTS = Object.freeze(['terms', 'privacy']);

/// The kinds of change an entry may be.
export const CHANGES = Object.freeze(['first', 'minor', 'material', 'price']);

/// The longest a summary may be: what the app's front door shows
/// (app/lib/net/remote_config.dart, Saying).
export const SUMMARY_MOST = 280;

/// [ledger] as ledger.json is written.
export const formatLedger = (ledger) => `${JSON.stringify(ledger, null, 2)}\n`;

/// Whether an entry's change is told to every subscriber.
export const told = (entry) => entry.change === 'material' || entry.change === 'price';

/// Which version [entry] is, as notices, their records and the tool name
/// it: its day, and the day's revision after its first: 2026-10-23,
/// 2026-10-23.2. The service names it as this does
/// (service/functions/notices.mjs, versionOf).
export const versionOf = (entry) => (entry.revision ? `${entry.date}.${entry.revision}` : entry.date);

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const isDay = (s) => typeof s === 'string' && DAY.test(s) && new Date(`${s}T00:00:00Z`).toISOString().startsWith(s);

/// What a reader of [html], a page as built or as served, is held to:
/// the words of its <main>, with where each of its links goes, and
/// nothing of how it looks — no tags, icons or comments, and every run
/// of white space as one space.
export function textOf(html) {
  const main = /<main\b[^>]*>([\s\S]*)<\/main>/.exec(html)?.[1];
  if (main === undefined) throw new Error('no <main> on the page');
  return main
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<svg\b[\s\S]*?<\/svg>/g, ' ')
    .replace(/<a\b[^>]*?\bhref="([^"]*)"[^>]*>/g, ' [$1] ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/// The fingerprint of a document from its text in each language
/// ([texts], by language code): sha256, hex.
export function fingerprintOfTexts(texts) {
  return createHash('sha256').update(JSON.stringify(languages.map((l) => [l.code, texts[l.code]]))).digest('hex');
}

/// [document] as this checkout builds it, in each language, by code.
export function textsOf(document, options = {}) {
  return Object.fromEntries(languages.map((l) => [l.code, textOf(render(document, l, strings(l.code), options))]));
}

/// The fingerprint of [document] as this checkout builds it.
export const fingerprintOf = (document, options = {}) => fingerprintOfTexts(textsOf(document, options));

/// What is wrong with [ledger]'s shape, each as a line: every document
/// with a first entry, dated in order, each entry whole. A version
/// published on the day of the one before is that day's next revision,
/// and says something none of its day's versions before it says: the
/// site's text and its "Last updated" day tell which is live
/// (ops/terms.mjs, liveVersions).
export function ledgerProblems(ledger) {
  const found = [];
  const keys = Object.keys(ledger ?? {});
  for (const k of keys.filter((k) => !DOCUMENTS.includes(k))) found.push(`ledger: no such document as ${k}`);
  for (const doc of DOCUMENTS) {
    const entries = ledger?.[doc];
    if (!Array.isArray(entries) || !entries.length) {
      found.push(`${doc}: no entries`);
      continue;
    }
    entries.forEach((e, i) => {
      const at = `${doc} ${e?.date ? versionOf(e) : `#${i}`}`;
      const revised = Object.hasOwn(e ?? {}, 'revision');
      const want = ['change', 'date', 'fingerprint', ...(doc === 'terms' ? ['price'] : []), ...(revised ? ['revision'] : []), 'storesNotified', 'summary'];
      const have = Object.keys(e ?? {}).sort();
      if (have.join() !== want.join()) found.push(`${at}: has ${have.join(', ')}; wants ${want.join(', ')}`);
      const before = entries[i - 1];
      if (!isDay(e?.date)) found.push(`${at}: date is not a day (YYYY-MM-DD)`);
      else if (before && e.date < before.date) found.push(`${at}: not after the entry before (${versionOf(before)})`);
      else if (before?.date === e.date) {
        const next = (before.revision ?? 1) + 1;
        if (e.revision !== next) found.push(`${at}: published the day of the entry before (${versionOf(before)}), so its revision is ${next}`);
        if (entries.slice(0, i).some((b) => b.date === e.date && b.fingerprint === e.fingerprint)) found.push(`${at}: says what a version of its day before it says`);
      } else if (revised) found.push(`${at}: the first version of its day has no revision`);
      if (!/^[0-9a-f]{64}$/.test(e?.fingerprint ?? '')) found.push(`${at}: fingerprint is not 64 hex`);
      if (!CHANGES.includes(e?.change)) found.push(`${at}: change is one of ${CHANGES.join(', ')}`);
      else if ((i === 0) !== (e.change === 'first')) found.push(`${at}: only the first entry, and always, is change "first"`);
      if (e?.storesNotified !== null && !isDay(e?.storesNotified)) found.push(`${at}: storesNotified is a day or null`);
      for (const l of languages) {
        const said = e?.summary?.[l.code];
        if (typeof said !== 'string' || !said.trim()) found.push(`${at}: no summary in ${l.code}`);
        else if (/[<>]|\{\{/.test(said)) found.push(`${at}: the ${l.code} summary is plain text, no markup`);
        else if (said.trim().length > SUMMARY_MOST) found.push(`${at}: the ${l.code} summary is ${said.trim().length} characters; the app shows ${SUMMARY_MOST}`);
      }
      for (const k of Object.keys(e?.summary ?? {}).filter((k) => !languages.some((l) => l.code === k))) found.push(`${at}: a summary in ${k}, which the site is not in`);
      if (doc !== 'terms') return;
      const p = e?.price;
      if (!(Number.isInteger(p?.amount) && p.amount > 0 && /^[a-z]{3}$/.test(p?.currency ?? '') && Object.keys(p).length === 2)) {
        found.push(`${at}: price is {"amount": <cents>, "currency": "usd"}`);
      } else if (i > 0) {
        const before = entries[i - 1].price;
        const moved = before?.amount !== p.amount || before?.currency !== p.currency;
        if (moved && e.change !== 'price') found.push(`${at}: the price changed, so the change is "price"`);
        if (!moved && e.change === 'price') found.push(`${at}: change "price", but the price is the one before`);
      }
    });
  }
  return found;
}

/// What [now] has done to [before], the ledger as main has it, that a
/// ledger may not: an entry taken away or changed. An entry may only be
/// added, and an entry's storesNotified filled in once.
export function rewritten(before, now) {
  const found = [];
  for (const doc of DOCUMENTS) {
    (before?.[doc] ?? []).forEach((was, i) => {
      const is = now?.[doc]?.[i];
      if (!is) return found.push(`${doc} ${versionOf(was)}: taken out`);
      const filled = was.storesNotified === null ? { ...is, storesNotified: null } : is;
      if (JSON.stringify(filled) !== JSON.stringify(was)) found.push(`${doc} ${versionOf(was)}: changed`);
    });
  }
  return found;
}
