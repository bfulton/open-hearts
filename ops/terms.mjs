// `oh terms …`: the terms of use and the privacy policy as the ledger
// has them (site/ledger.json), as this checkout builds them, and as the
// site serves them; a change written into the ledger; the stores'
// notice recorded; and web subscribers told of a change that matters to
// them (docs/how-to/change-the-terms.md). What a production deploy is
// held to is here too (termsProblems), for the gate (gate.mjs).
//
// Which version is live is read off the site itself: each document in
// every language, fingerprinted as the ledger fingerprints it. Nothing
// here prints an email address: subscriptions and counts only.

import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { Failed, Usage, root } from './env.mjs';
import { languages, origin, stores } from '../site/build.mjs';
import { DOCUMENTS, fingerprintOf, fingerprintOfTexts, formatLedger, ledgerProblems, rewritten, textOf, told } from '../site/ledger.mjs';
import { NOTICE_DAYS, NOTICES_PER_ORDER } from '../service/functions/notices.mjs';
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

/// Which entry of [ledger] each document is live at: what the site
/// serves, in every language, fingerprinted. {document: {index, entry}
/// or {error}}.
export async function liveVersions(ctx, ledger) {
  const found = {};
  for (const doc of DOCUMENTS) {
    const texts = {};
    for (const l of languages) {
      const url = `${origin}${l.code === 'en' ? '' : `/${l.code}`}/${doc}`;
      try {
        const res = await ctx.fetch(url, { headers: { 'cache-control': 'no-cache' } });
        if (res.status !== 200) throw new Error(`answered ${res.status}`);
        texts[l.code] = textOf(await res.text());
      } catch (e) {
        found[doc] = { error: `${url}: ${e?.message ?? e}` };
        break;
      }
    }
    if (found[doc]) continue;
    const fingerprint = fingerprintOfTexts(texts);
    const index = ledger[doc].findIndex((e) => e.fingerprint === fingerprint);
    found[doc] = index < 0 ? { error: `the site serves a version (${fingerprint.slice(0, 12)}…) that is no entry in site/ledger.json` } : { index, entry: ledger[doc][index] };
  }
  return found;
}

/// What stands in the way of publishing this checkout's terms and
/// privacy policy to production, and what it would publish:
/// {problems, publishing: [{document, entry}]}. The ledger has to be
/// whole and the text what its newest entry says; the newest version
/// to go live is dated today, which "Last updated" shows; a material
/// change goes out only once the stores were told of it, while the apps
/// are in them; and one subscribers are told of only where the deploy
/// can tell them (STRIPE_API_KEY).
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
      if (listed() && !e.storesNotified) problems.push(`the ${doc} of ${e.date} are a ${e.change} change: tell the App Store and Google Play first, and record the day (./oh terms notified ${doc})`);
      if (!ctx.env.STRIPE_API_KEY) problems.push(`the ${doc} of ${e.date} are a ${e.change} change, which the deploy emails web subscribers: it needs STRIPE_API_KEY`);
    }
    publishing.push(...newer.map((entry) => ({ document: doc, entry })));
  }
  return { problems, publishing };
}

/// [entry] in a few words.
const said = (doc, e) => `${doc} ${e.date} (${e.change}${told(e) ? `; stores ${e.storesNotified ? `told ${e.storesNotified}` : 'not told'}` : ''})`;

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
    ctx.log(`  live: ${live[doc].entry.date}`);
    for (const e of ledger[doc].slice(live[doc].index + 1)) ctx.log(`  to publish: ${said(doc, e)}`);
    for (const e of ledger[doc].slice(0, live[doc].index + 1).filter(told)) {
      const sent = store ? `${(await store.under(`NOTICE#${doc}@${e.date}`, 'SUB#')).length} web subscription(s) told` : 'notices sent: unknown without CLOUDFLARE_API_TOKEN';
      ctx.log(`  published: ${said(doc, e)}; ${sent}`);
    }
  }
}

/// The ledger's entry for a change to [document] that this checkout
/// makes: added, or, while this branch's own newest entry is not on main
/// yet, that entry brought up to date.
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
  if (!(date > before.date)) throw new Failed(`the entry would be dated ${date}, not after the one before it (${before.date}): --date`);
  const price = doc === 'terms' ? (await ctx.config()).price : undefined;
  const entry = {
    date,
    fingerprint,
    change,
    ...(price ? { price } : {}),
    storesNotified: own ? newest.storesNotified : null,
    summary: own ? newest.summary : Object.fromEntries(languages.map((l) => [l.code, ''])),
  };
  const next = { ...ledger, [doc]: [...(own ? entries.slice(0, -1) : entries), entry] };
  ctx.log(`${own ? 'would bring up to date' : 'would add'} the ${doc}' entry of ${date}: ${change}, ${fingerprint.slice(0, 12)}…${price ? `, ${price.amount} ${price.currency}` : ''}`);
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
  const entry = ledger[doc].filter(told).at(-1);
  if (!entry) throw new Failed(`the ${doc} have no material or price change to have told the stores of`);
  if (entry.storesNotified) return ctx.log(`the stores were told of the ${doc} of ${entry.date} on ${entry.storesNotified} already`);
  const day = flags.on ?? dayOf(ctx.now());
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || day > dayOf(ctx.now())) throw new Usage('--on is the day they were told, YYYY-MM-DD, not later than today');
  const next = structuredClone(ledger);
  next[doc].find((e) => e.date === entry.date).storesNotified = day;
  if (rewritten(ledger, next).length) throw new Failed('that would rewrite the ledger');
  ctx.log(`would record that the App Store and Google Play were told of the ${doc} of ${entry.date} on ${day}`);
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

/// Which entries are live, once the site serves the newest of each
/// document — what a deploy just published, which can take a moment to
/// be what every request is answered with — asked [tries] times, [wait]
/// apart; Failed if it never does.
async function servingNewest(ctx, ledger) {
  const { tries = 12, wait = 10000 } = ctx.carryOptions ?? {};
  let live = null;
  for (let i = 0; i < tries; i++) {
    if (i) await new Promise((r) => setTimeout(r, wait));
    live = await liveVersions(ctx, ledger);
    if (DOCUMENTS.every((doc) => live[doc].index === ledger[doc].length - 1)) return live;
  }
  const behind = DOCUMENTS.filter((doc) => live[doc].index !== ledger[doc].length - 1).map((doc) => `${doc}: ${live[doc].error ?? `serves ${live[doc].entry.date}`}`);
  throw new Failed(`the site does not serve what was just published (${behind.join('; ')})`);
}

/// Every web subscriber told, by email, of each published change that
/// matters to them in the last [NOTICE_DAYS] days, once: the
/// subscriptions are Stripe's, each order names a few of them, and the
/// service writes to each (service/functions/notices.mjs). Run by
/// deploy.sh after it publishes to production, and again whenever a
/// notice did not go.
export async function notify(ctx, { flags }) {
  const ledger = await readLedger(ctx);
  const live = flags['after-deploy'] ? await servingNewest(ctx, ledger) : await liveVersions(ctx, ledger);
  const since = dayOf(ctx.now() - NOTICE_DAYS * DAY_MS);
  const due = [];
  for (const doc of DOCUMENTS) {
    if (live[doc].error) throw new Failed(`which ${doc} are live cannot be told: ${live[doc].error}`);
    for (const e of ledger[doc].slice(0, live[doc].index + 1)) if (told(e) && e.date > since) due.push({ doc, entry: e });
  }
  if (!due.length) return ctx.log('no published change to tell subscribers of');
  const store = await ctx.store();
  const stripe = ctx.stripe();
  const config = await ctx.config();
  let failed = 0;
  for (const { doc, entry } of due) {
    const subs = await subscribersBefore(stripe, entry.date);
    const done = new Set((await store.under(`NOTICE#${doc}@${entry.date}`, 'SUB#')).map((sk) => sk.slice('SUB#'.length)));
    const left = subs.filter((id) => !done.has(id));
    ctx.log(`the ${doc} of ${entry.date} (${entry.change}): ${subs.length} web subscription(s) to tell, ${subs.length - left.length} told already`);
    if (!flags.apply || !left.length) continue;
    for (let i = 0; i < left.length; i += NOTICES_PER_ORDER) {
      const batch = left.slice(i, i + NOTICES_PER_ORDER);
      const answer = await placeOrder(store, { act: 'notice', document: doc, date: entry.date, subscriptions: batch, at: new Date(ctx.now()).toISOString() }, { origin: config.appOrigin, fetchImpl: ctx.fetch, ...(ctx.carryOptions ?? {}) });
      if (answer?.status !== 200) {
        failed += batch.length;
        ctx.warn(`the service said ${answer?.status ?? 'nothing'} to ${batch.length} of them: ${answer?.body?.error ?? ''}`);
        continue;
      }
      const b = answer.body;
      failed += b.failed;
      const unsent = Object.entries(b.unsent ?? {}).map(([why, n]) => `${n} ${why}`).join(', ');
      ctx.log(`  told ${b.told}, told already ${b.already}${unsent ? `, not told: ${unsent}` : ''}${b.failed ? `, not sent ${b.failed}` : ''}`);
    }
  }
  if (!flags.apply) return ctx.log('nothing sent; --apply sends it');
  if (failed) throw new Failed(`${failed} notice(s) did not go: run ./oh terms notify --apply again`);
}
