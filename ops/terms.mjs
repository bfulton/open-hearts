// `oh terms …`: the terms of use and the privacy policy as the ledger
// has them (site/ledger.json), as this checkout builds them, and as the
// site serves them; a change written into the ledger; the stores'
// notice recorded; and web subscribers told of a published change that
// matters to them, when the operator says so, never by a deploy
// (docs/how-to/change-the-terms.md). What a production deploy is held
// to is here too (termsProblems), for the gate (gate.mjs).
//
// Which version is live is read off the site itself: each document in
// every language, fingerprinted as the ledger fingerprints it. Nothing
// here prints an email address: subscriptions and counts only.

import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { Failed, Usage, root } from './env.mjs';
import { dayIn, languages, origin, render, stores, strings } from '../site/build.mjs';
import { DOCUMENTS, fingerprintOf, fingerprintOfTexts, formatLedger, ledgerProblems, rewritten, textOf, told, versionOf } from '../site/ledger.mjs';
import { NOTICE_DAYS, NOTICES_PER_ORDER, noticeMail } from '../service/functions/notices.mjs';
import { dayOf } from '../service/functions/rows.mjs';
import { placeOrder } from '../service/tool/suspend.mjs';

const DAY_MS = 86400000;

/// Where the ledger is: this checkout's, or a test's.
const ledgerFile = (ctx) => ctx.ledgerFile ?? join(root, 'site/ledger.json');

/// The ledger as this checkout has it.
export const readLedger = async (ctx) => JSON.parse(await readFile(ledgerFile(ctx), 'utf8'));

/// The ledger as main has it, or null when main has none.
async function mainLedger(ctx) {
  const { code, out } = await ctx.capture('git', ['show', 'origin/main:site/ledger.json']);
  return code === 0 ? JSON.parse(out) : null;
}

/// Whether either app is in its store (site/build.mjs, stores): then a
/// material change is told to the App Store and Google Play first.
const listed = () => !!(stores.appStore || stores.googlePlay);

function documentOf(name) {
  if (!DOCUMENTS.includes(name)) throw new Usage(`the document is one of ${DOCUMENTS.join(', ')}`);
  return name;
}

/// The line of a page as served that says when it was last updated.
const UPDATED = /<p class="updated">([\s\S]*?)<\/p>/;

/// Which entry of [ledger] each document is live at: what the site
/// serves, in every language, fingerprinted, and of the entries with
/// that text, the one whose day the page says it was last updated: an
/// entry may repeat the text of the one before it, to publish that text
/// on a later day, and no two versions of a day say the same
/// (ledgerProblems). {document: {index, entry} or {error}}.
export async function liveVersions(ctx, ledger) {
  const english = languages.find((l) => l.code === 'en');
  const words = strings('en');
  const found = {};
  for (const doc of DOCUMENTS) {
    const texts = {};
    let updated = null;
    for (const l of languages) {
      const url = `${origin}${l.code === 'en' ? '' : `/${l.code}`}/${doc}`;
      try {
        const res = await ctx.fetch(url, { headers: { 'cache-control': 'no-cache' } });
        if (res.status !== 200) throw new Error(`answered ${res.status}`);
        const html = await res.text();
        texts[l.code] = textOf(html);
        if (l === english) updated = UPDATED.exec(html)?.[1].trim() ?? null;
      } catch (e) {
        found[doc] = { error: `${url}: ${e?.message ?? e}` };
        break;
      }
    }
    if (found[doc]) continue;
    const fingerprint = fingerprintOfTexts(texts);
    const says = (e) => words[doc].header.updated.replace(`{{updated.${doc}}}`, dayIn(english, e.date));
    const same = ledger[doc].flatMap((e, i) => (e.fingerprint === fingerprint ? [i] : []));
    const index = same.find((i) => says(ledger[doc][i]) === updated) ?? same[0] ?? -1;
    found[doc] = index < 0 ? { error: `the site serves a version (${fingerprint.slice(0, 12)}…) that is no entry in site/ledger.json` } : { index, entry: ledger[doc][index] };
  }
  return found;
}

/// What stands in the way of publishing this checkout's terms and
/// privacy policy to production, and what it would publish:
/// {problems, publishing: [{document, entry}]}. The ledger has to be
/// whole and the text what its newest entry says; the newest version
/// to go live is dated today, which "Last updated" shows; and a
/// material change goes out only once the stores were told of it, while
/// the apps are in them. Subscribers are told of it after it is
/// published, by `oh terms notify`: the terms apply it to a subscription
/// only from a renewal well after that (notices.mjs, APPLIES_AFTER_DAYS).
export async function termsProblems(ctx, { now = ctx.now() } = {}) {
  const ledger = await readLedger(ctx);
  const problems = ledgerProblems(ledger).map((p) => `site/ledger.json: ${p}`);
  if (problems.length) return { problems, publishing: [] };
  for (const doc of DOCUMENTS) {
    if (fingerprintOf(doc) !== ledger[doc].at(-1).fingerprint) problems.push(`the ${doc} here are not what their newest entry in site/ledger.json says: ./oh terms record ${doc}`);
  }
  const price = (await ctx.config()).price;
  if (JSON.stringify(ledger.terms.at(-1).price) !== JSON.stringify(price)) problems.push('the terms\' newest entry states another price than config/openhearts.json');
  const live = await liveVersions(ctx, ledger);
  const today = dayOf(now);
  const yesterday = dayOf(now - DAY_MS);
  const publishing = [];
  for (const doc of DOCUMENTS) {
    if (live[doc].error) {
      problems.push(`which ${doc} are live cannot be told: ${live[doc].error}`);
      continue;
    }
    const newer = ledger[doc].slice(live[doc].index + 1);
    if (!newer.length) continue;
    const { date } = newer.at(-1);
    if (date !== today && date !== yesterday) {
      problems.push(`the ${doc} would go live today (${today}) saying they were last updated ${date}: date their newest entry today (./oh terms record ${doc} --date ${today})`);
    }
    for (const e of newer.filter(told)) {
      if (listed() && !e.storesNotified) problems.push(`the ${doc} of ${versionOf(e)} are a ${e.change} change: tell the App Store and Google Play first, and record the day (./oh terms notified ${doc})`);
    }
    publishing.push(...newer.map((entry) => ({ document: doc, entry })));
  }
  return { problems, publishing };
}

/// [entry] in a few words.
const said = (doc, e) => `${doc} ${versionOf(e)} (${e.change}${told(e) ? `; stores ${e.storesNotified ? `told ${e.storesNotified}` : 'not told'}` : ''})`;

export async function status(ctx) {
  const ledger = await readLedger(ctx);
  for (const p of ledgerProblems(ledger)) ctx.warn(`site/ledger.json: ${p}`);
  const live = await liveVersions(ctx, ledger);
  const store = ctx.env.CLOUDFLARE_API_TOKEN && ctx.env.CLOUDFLARE_ACCOUNT_ID ? await ctx.store() : null;
  for (const doc of DOCUMENTS) {
    const newest = ledger[doc].at(-1);
    ctx.log(doc);
    ctx.log(`  newest entry: ${said(doc, newest)}`);
    ctx.log(fingerprintOf(doc) === newest.fingerprint ? '  this checkout: as the newest entry says' : `  this checkout: changed since the newest entry; ./oh terms record ${doc}`);
    if (live[doc].error) {
      ctx.log(`  live: unknown; ${live[doc].error}`);
      continue;
    }
    ctx.log(`  live: ${versionOf(live[doc].entry)}`);
    for (const e of ledger[doc].slice(live[doc].index + 1)) ctx.log(`  to publish: ${said(doc, e)}`);
    for (const e of ledger[doc].slice(0, live[doc].index + 1).filter(told)) {
      const sent = store ? `${(await store.under(`NOTICE#${doc}@${versionOf(e)}`, 'SUB#')).length} web subscription(s) told` : 'notices sent: unknown without CLOUDFLARE_API_TOKEN';
      ctx.log(`  published: ${said(doc, e)}; ${sent}`);
    }
  }
}

/// The ledger's entry for a change to [document] that this checkout
/// makes: added, or, while this branch's own newest entry is not on main
/// yet, that entry brought up to date. One dated the day of the entry
/// before it is that day's next revision.
export async function record(ctx, { args, flags }) {
  const doc = documentOf(args.document);
  const ledger = await readLedger(ctx);
  const entries = ledger[doc];
  const newest = entries.at(-1);
  // The branch's own: neither on main nor where the ledger begins.
  const onMain = (await mainLedger(ctx))?.[doc]?.length ?? 0;
  const own = entries.length > Math.max(onMain, 1);
  const fingerprint = fingerprintOf(doc);
  const date = flags.date ?? dayOf(ctx.now());
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Usage('--date is a day, YYYY-MM-DD');
  const change = flags.change ?? (own ? newest.change : null);
  if (change !== null && !['minor', 'material', 'price'].includes(change)) throw new Usage('--change is minor, material or price');
  if (fingerprint === newest.fingerprint && !flags.change && !flags.date) return ctx.log(`the ${doc} are as their newest entry (${newest.date}) says: nothing to record`);
  if (!change) throw new Usage('say what kind of change this is: --change minor (no one\'s rights or duties change), material, or price');
  const before = own ? entries.at(-2) : newest;
  if (date < before.date) throw new Failed(`the entry would be dated ${date}, before the one it follows (${versionOf(before)}): --date`);
  const revision = date === before.date ? (before.revision ?? 1) + 1 : null;
  const price = doc === 'terms' ? (await ctx.config()).price : undefined;
  const entry = {
    date,
    ...(revision ? { revision } : {}),
    fingerprint,
    change,
    ...(price ? { price } : {}),
    storesNotified: own ? newest.storesNotified : null,
    summary: own ? newest.summary : Object.fromEntries(languages.map((l) => [l.code, ''])),
  };
  const next = { ...ledger, [doc]: [...(own ? entries.slice(0, -1) : entries), entry] };
  ctx.log(`${own ? 'would bring up to date' : 'would add'} the ${doc === 'terms' ? "terms'" : "privacy policy's"} entry of ${versionOf(entry)}${revision ? ` (the day's revision ${revision})` : ''}: ${change}, ${fingerprint.slice(0, 12)}…${price ? `, ${price.amount} ${price.currency}` : ''}`);
  const problems = ledgerProblems(next).filter((p) => !/ no summary in /.test(p));
  for (const p of problems) ctx.warn(p);
  if (!flags.apply) return ctx.log('nothing changed; --apply writes it');
  if (problems.length) throw new Failed('not written: put the problems above right first');
  await writeFile(ledgerFile(ctx), formatLedger(next));
  ctx.log('written to site/ledger.json');
  if (Object.values(entry.summary).some((s) => !s.trim())) ctx.log(`now write what changed, in each language, under "summary": a sentence or two, plain text; it is what subscribers are told`);
}

/// The day the App Store and Google Play were told of [document]'s
/// newest material change, recorded on its entry.
export async function notified(ctx, { args, flags }) {
  const doc = documentOf(args.document);
  const ledger = await readLedger(ctx);
  const index = ledger[doc].findLastIndex(told);
  const entry = ledger[doc][index];
  if (!entry) throw new Failed(`the ${doc} have no material or price change to have told the stores of`);
  if (entry.storesNotified) return ctx.log(`the stores were told of the ${doc} of ${versionOf(entry)} on ${entry.storesNotified} already`);
  const day = flags.on ?? dayOf(ctx.now());
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || day > dayOf(ctx.now())) throw new Usage('--on is the day they were told, YYYY-MM-DD, not later than today');
  const next = structuredClone(ledger);
  next[doc][index].storesNotified = day;
  if (rewritten(ledger, next).length) throw new Failed('that would rewrite the ledger');
  ctx.log(`would record that the App Store and Google Play were told of the ${doc} of ${versionOf(entry)} on ${day}`);
  if (!flags.apply) return ctx.log('nothing changed; --apply writes it');
  await writeFile(ledgerFile(ctx), formatLedger(next));
  ctx.log('written to site/ledger.json');
}

/// The web subscriptions Stripe has that a change published on [date]
/// is told to: active, on trial, or with a payment overdue, and begun
/// on or before that day, before the version they agreed to was
/// replaced. [{id, start}].
async function subscribersBefore(stripe, date) {
  const until = Date.parse(`${date}T00:00:00Z`) / 1000 + 86400;
  const found = [];
  let after = null;
  do {
    const page = await stripe.get(`/subscriptions?status=all&limit=100${after ? `&starting_after=${after}` : ''}`);
    for (const s of page.data ?? []) {
      if (['active', 'trialing', 'past_due'].includes(s.status) && s.start_date < until) found.push(s.id);
    }
    after = page.has_more ? page.data.at(-1)?.id : null;
  } while (after);
  return found;
}

/// Each document's newest published change that matters to
/// subscribers, of the last [NOTICE_DAYS] days, with the earlier ones of
/// those days that its summary says too, as the app shows only the
/// newest (notices.mjs, noticesOf); the web subscriptions it is told to,
/// and those of them not told yet, and the day the document as it now
/// reads was published: [{document, entry, covers, subscriptions, left,
/// day}]. Failed when which version is live cannot be told.
export async function untold(ctx, ledger = null) {
  ledger ??= await readLedger(ctx);
  const live = await liveVersions(ctx, ledger);
  const since = dayOf(ctx.now() - NOTICE_DAYS * DAY_MS);
  const due = [];
  for (const doc of DOCUMENTS) {
    if (live[doc].error) throw new Failed(`which ${doc} are live cannot be told: ${live[doc].error}`);
    const published = ledger[doc].slice(0, live[doc].index + 1).filter((e) => told(e) && e.date > since);
    if (published.length) due.push({ document: doc, entry: published.at(-1), covers: published.slice(0, -1), day: live[doc].entry.date });
  }
  if (!due.length) return [];
  const store = await ctx.store();
  const stripe = ctx.stripe();
  for (const d of due) {
    d.subscriptions = await subscribersBefore(stripe, d.entry.date);
    const done = new Set((await store.under(`NOTICE#${d.document}@${versionOf(d.entry)}`, 'SUB#')).map((sk) => sk.slice('SUB#'.length)));
    d.left = d.subscriptions.filter((id) => !done.has(id));
  }
  return due;
}

/// [due] in a few words: "the terms of 2026-10-23.2 (material), saying
/// what changed on 2026-10-19 too".
const changeSaid = ({ document, entry, covers }) => `the ${document} of ${versionOf(entry)} (${entry.change})${covers.length ? `, saying what changed on ${covers.map(versionOf).join(' and ')} too` : ''}`;

/// Every web subscriber told, by one email, of each published change
/// that matters to them in the last [NOTICE_DAYS] days that they were
/// not told of, once: the subscriptions are Stripe's, each order names a
/// few of them that are owed the same changes, and the service writes
/// to each (service/functions/notices.mjs). Without --apply it says what
/// it would send, and shows the email as it reads in English. The
/// operator runs it once a change is published, and again whenever a
/// notice did not go; a deploy never does, so that no deploy emails
/// anyone.
export async function notify(ctx, { flags }) {
  const due = await untold(ctx);
  if (!due.length) return ctx.log('no published change to tell subscribers of');
  for (const d of due) ctx.log(`${changeSaid(d)}: ${d.subscriptions.length} web subscription(s) to tell, ${d.subscriptions.length - d.left.length} told already`);
  // Each subscription is owed the changes it was not told of, and is
  // told of them in one email; an order names those owed the same.
  const owed = new Map();
  for (const d of due) {
    for (const id of d.left) owed.set(id, [...(owed.get(id) ?? []), d]);
  }
  const groups = new Map();
  for (const [id, changes] of owed) {
    const key = changes.map((c) => `${c.document}@${versionOf(c.entry)}`).join(' ');
    groups.set(key, { changes, subscriptions: [...(groups.get(key)?.subscriptions ?? []), id] });
  }
  if (!flags.apply) {
    for (const { changes, subscriptions } of groups.values()) {
      const { subject, text } = noticeMail('en', changes, { renews: 'YYYY-MM-DD' });
      ctx.log(`\nthe email to ${subscriptions.length} of them, as it reads in English (each in their own language, the renewal theirs):\n\nSubject: ${subject}\n\n${text}\n`);
    }
    return ctx.log('nothing sent; --apply sends it');
  }
  const store = await ctx.store();
  const config = await ctx.config();
  let failed = 0;
  for (const { changes, subscriptions } of groups.values()) {
    const named = changes.map((c) => ({ document: c.document, version: versionOf(c.entry), covers: c.covers.map(versionOf) }));
    for (let i = 0; i < subscriptions.length; i += NOTICES_PER_ORDER) {
      const batch = subscriptions.slice(i, i + NOTICES_PER_ORDER);
      const answer = await placeOrder(store, { act: 'notice', changes: named, subscriptions: batch, at: new Date(ctx.now()).toISOString() }, { origin: config.appOrigin, fetchImpl: ctx.fetch, ...(ctx.carryOptions ?? {}) });
      if (answer?.status !== 200) {
        failed += batch.length;
        ctx.warn(`the service said ${answer?.status ?? 'nothing'} to ${batch.length} of them: ${answer?.body?.error ?? ''}`);
        continue;
      }
      const b = answer.body;
      failed += b.failed;
      const unsent = Object.entries(b.unsent ?? {}).map(([why, n]) => `${n} ${why}`).join(', ');
      ctx.log(`  ${changes.map(changeSaid).join('; ')}: told ${b.told}, told already ${b.already}${unsent ? `, not told: ${unsent}` : ''}${b.failed ? `, not sent ${b.failed}` : ''}`);
    }
  }
  if (failed) throw new Failed(`${failed} notice(s) did not go: run ./oh terms notify --apply again`);
}

/// [html], a page as built, as plain text a person reads: its title,
/// its date, and its <main>, with headings set apart, list items
/// marked, and each link's address written after it.
export function plainTextOf(html) {
  const part = (pattern) => pattern.exec(html)?.[1] ?? '';
  const entities = (s) => s.replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
  // White space in HTML is a space; lines come from the tags.
  const flat = (s) => s.replace(/<!--[\s\S]*?-->/g, '').replace(/<svg\b[\s\S]*?<\/svg>/g, '').replace(/\s+/g, ' ');
  // A link within the page, or to an address or a number it shows, is
  // its words; any other, its words and where it goes.
  const link = (_, href, label) => {
    if (href.startsWith('#') || href.startsWith('mailto:') || href.startsWith('tel:')) return label;
    const url = href.startsWith('/') ? `${origin}${href}` : href;
    return label.replace(/<[^>]*>/g, '').trim() === url.replace(/^https?:\/\//, '') ? url : `${label} (${url})`;
  };
  const text = (s) =>
    entities(
      flat(s)
        .replace(/<\/b>\s*<span>/g, '</b>: <span>')
        .replace(/<a\b[^>]*?\bhref="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g, link)
        .replace(/<br\s*\/?>/g, '\n')
        .replace(/<h2\b[^>]*>/g, '\n\n\n')
        .replace(/<h3\b[^>]*>/g, '\n\n')
        .replace(/<li\b[^>]*>/g, '\n- ')
        .replace(/<\/?(p|ul|ol|address|section|h2|h3)\b[^>]*>/g, '\n')
        .replace(/<[^>]*>/g, ''),
    )
      .split('\n')
      .map((line) => line.replace(/ +/g, ' ').trim())
      .join('\n')
      .replace(/\n{3,}/g, '\n\n')
      .replace(/\n\n- /g, '\n- ');
  const title = entities(flat(part(/<h1[^>]*>([\s\S]*?)<\/h1>/)).replace(/<[^>]*>/g, '')).trim();
  return `${title}\n${text(part(/<p class="updated">([\s\S]*?)<\/p>/)).trim()}\n\n${text(part(/<main\b[^>]*>([\s\S]*)<\/main>/)).trim()}\n`;
}

/// The terms, in English, as plain text: what App Store Connect takes as
/// the app's licence agreement, which the terms are (their "If you got
/// the app from the App Store").
export async function eula(ctx) {
  const english = languages.find((l) => l.code === 'en');
  ctx.log(plainTextOf(render('terms', english, strings('en'))).trimEnd());
}
