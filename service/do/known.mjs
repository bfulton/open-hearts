// Known images of child sexual abuse, kept from being shown at all.
// Each picture an account sets is asked about as it is set, before
// anyone is shown it (profile_pictures.mjs), of the checker in use
// (checkers.mjs): the Canadian Centre for Child Protection's Arachnid
// Shield, or Microsoft's PhotoDNA in its place. It is asked through one
// object kept in Cloudflare's "us" jurisdiction, under the US law that
// has a match reported and what is kept of it kept. A checker is asked
// about each picture once, and is sent its hash, never the picture. A
// picture that cannot be decoded or hashed, so that nothing can be
// asked about it, is never the account's either; nor is one Shield
// knows as a harmful or abusive image of a child that is not one of
// sexual abuse, and the operator is emailed each account that sets one.
// A picture that a checker matches with a known image of sexual abuse
// is never the account's, and everything that follows is done here,
// with nothing waiting on the operator
// (docs/how-to/handle-abuse-material.md):
//
//   1. the picture withheld wherever it turns up (pictures.mjs);
//   2. each account that set it held (holds.mjs), a copy of the picture
//      and of every other it set kept where only the operator reaches
//      them, and the account's own copy of it, which an address serves
//      for the daily email, deleted;
//   3. each such account terminated, its web subscriptions ended in
//      Stripe with nothing refunded (an order the service carries out,
//      suspension.mjs);
//   4. a report filed to NCMEC's CyberTipline (ncmec.mjs), its number
//      written on the hold;
//   5. the operator emailed what was done, and anything still to do.
//
// Each step is written down as it is done, and the object's alarm tries
// the rest again until all are: Stripe or NCMEC not answering delays a
// step, and loses none. The checker not answering lets the picture be
// set, so the game goes on, and is asked again; a match found then is
// acted on as any other, and the picture taken down with it.
//
// Off until the deployment has the credentials of the checker in use
// (checkers.mjs);
// a report is filed once it has NCMEC's credentials too, and until then
// the email says to file it by hand.

import { heldPictureKey, hold, keepHeldPictures } from '../functions/holds.mjs';
import { bodyOf } from '../functions/http.mjs';
import { NcmecRefused, fileDetailsXml, fileReport, reportXml } from '../functions/ncmec.mjs';
import { pictureHash } from './arachnid.mjs';
import { CHECKERS, SHIELD, anyChecker, checkerIn, checkersOf, listed, verdictOf } from './checkers.mjs';
import { Unreadable } from './jpeg.mjs';
import { PICTURES_ROW, deleteCopy, pictureDigest, pictureKey, withheldOf, withholding } from '../functions/pictures.mjs';
import { isAccount, storeOf } from '../functions/rows.mjs';
import { orderOf } from '../functions/suspension.mjs';
import { accountsWith } from '../tool/find.mjs';
import { placeOrder } from '../tool/suspend.mjs';
import { alertKnownProblem, alertsOf } from '../functions/alerts.mjs';

/// The one object every check goes through.
export const KNOWN_OBJECT = 'known';

/// A picture the operator found and reports (`oh picture report`),
/// written where only the operator's tool writes, and named to the relay
/// by its id: {digest, accounts, how}. Kept long enough for KV to show
/// it to the relay and for the tool to ask again, and what the object
/// answered kept as long.
export const reportRow = (id) => [`KNOWN#${id}`, 'META'];
export const REPORT_KEPT_S = 10 * 60;
const isReportId = (id) => typeof id === 'string' && /^[0-9a-f]{32}$/.test(id);

/// At most this much of how the operator came to know is kept and
/// reported.
export const HOW_MOST = 300;

/// How long before a step that failed is tried again: a minute, then
/// doubling, to six hours at the most.
export const retryAfter = (tries) => Math.min(6 * 60 * 60 * 1000, 60 * 1000 * 2 ** Math.max(0, tries - 1));

const bytesOf = (base64) => Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));

/// Who said a picture the operator reported is a match, as its row
/// keeps what was said of it (KnownPictures, `pic:`).
const OPERATOR = 'operator';

/// What each checker said of a picture, and when, as its row keeps it:
/// {by: {id: said}, at: {id: ISO}}. A row from before rows named their
/// checkers is Arachnid Shield's, the only one there was.
const answersOf = (row) => (row?.by ? { by: { ...row.by }, at: { ...row.at } } : row?.said ? { by: { [SHIELD]: row.said }, at: { [SHIELD]: row.at } } : { by: {}, at: {} });

/// Who in [by] said [said] of a picture: checkers, and the operator.
const saying = (by, said) => Object.keys(by).filter((id) => by[id] === said);

/// The receipt for what is said of a picture, [answers] its row as
/// answersOf reads it and [said] what that comes to: who said it, and
/// when, as {knownBy, knownAt}. It is kept with the picture's copy
/// (profile_pictures.mjs) and its case.
const receiptOf = ({ by, at }, said) => {
  const who = Object.keys(by).find((id) => by[id] === said);
  return who ? { knownBy: who, knownAt: at[who] ?? null } : {};
};

/// The checkers a case says matched it, or knew it as harmful: none
/// when only the operator's report of the picture did, and Arachnid
/// Shield for a case from before cases named them.
const checkersIn = (c) => (c.by?.length ? c.by : [SHIELD]).filter((id) => id !== OPERATOR);

/// An R2 binding as keepHeldPictures reaches a bucket (holds.mjs).
export const r2Objects = (bucket) => ({
  async list(prefix) {
    const keys = [];
    let cursor;
    do {
      const page = await bucket.list({ prefix, cursor });
      for (const o of page.objects) keys.push(o.key);
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
    return keys;
  },
  async read(key) {
    const o = await bucket.get(key);
    return o ? new Uint8Array(await o.arrayBuffer()) : null;
  },
  async write(key, bytes, type) {
    await bucket.put(key, bytes, { httpMetadata: { contentType: type } });
  },
});

/// How a relay object asks the one object about a picture: {jpeg,
/// account, key} -> {said, knownBy, knownAt}, [said] 'clear', 'match',
/// 'harmful' (Shield knows it as a harmful or abusive image of a child),
/// 'failed' (the checker did not answer), 'unreadable' (it cannot be
/// decoded or hashed) or 'off', and, for what a checker said, which one
/// said it and when (KnownPictures, check), null otherwise. Null where
/// there is nothing to ask: no checker's credentials, or a runtime that
/// cannot keep the object in the United States.
export function knownAsker(env) {
  if (!env.KNOWN || !anyChecker(env) || typeof env.KNOWN.jurisdiction !== 'function') return null;
  const us = env.KNOWN.jurisdiction('us');
  const stub = us.get(us.idFromName(KNOWN_OBJECT));
  return async (asked) => {
    const res = await stub.fetch('https://known/check', { method: 'POST', body: JSON.stringify(asked) });
    if (!res.ok) throw new Error(`said ${res.status}`);
    const { said, knownBy = null, knownAt = null } = await res.json();
    return { said, knownBy, knownAt };
  };
}

/// The relay worker's `POST /known`, from the operator's tool (`oh
/// picture report`): [request] names a report the tool wrote in the
/// store, which is the operator's word. It is read here, so that only a
/// report the operator made reaches the one object every picture is
/// checked through, and passed to it.
export async function knownReport(request, env) {
  const id = (await bodyOf(request, 256))?.report;
  if (!isReportId(id)) return Response.json({ error: 'a report, 32 hex' }, { status: 400 });
  const store = storeOf(env);
  if (!store || typeof env.KNOWN?.jurisdiction !== 'function') return Response.json({ error: 'not configured: KNOWN or the store' }, { status: 503 });
  const asked = await store.get(...reportRow(id));
  // Not yet shown here, or never written: the tool asks again for a
  // while.
  if (!asked) return Response.json({ error: 'no such report' }, { status: 404 });
  const us = env.KNOWN.jurisdiction('us');
  return us.get(us.idFromName(KNOWN_OBJECT)).fetch('https://known/report', { method: 'POST', body: JSON.stringify({ ...asked, id }) });
}

/// NCMEC's credentials and who the report names as reporting it, off
/// env (deployment.mjs, `ncmec`), or null when a report cannot be filed.
export function ncmecOf(env) {
  const { OH_NCMEC_ENDPOINT: endpoint, OH_NCMEC_USERNAME: username, OH_NCMEC_PASSWORD: password, OH_NCMEC_EMAIL: email } = env;
  if (!endpoint || !username || !password || !email) return null;
  return {
    endpoint,
    username,
    password,
    reporter: { firstName: env.OH_NCMEC_FIRST_NAME ?? null, lastName: env.OH_NCMEC_LAST_NAME ?? null, email },
    // NCMEC's test service, where a report goes nowhere.
    test: new URL(endpoint).host.startsWith('exttest.'),
  };
}

/// What a match's case has done, in the operator's words, and what it
/// has not: {done: [line], todo: [line]}. A harmful one's is only
/// withheld.
export function caseLines(c, { ncmec }) {
  const done = [];
  const todo = [];
  const step = (ok, did, failing) => (ok ? done.push(did) : todo.push(failing));
  const why = (s) => (c.failed?.[s] ? ` (${c.failed[s]}; tried again by itself)` : ' (tried again by itself)');
  const failed = () => Object.keys(c.failed ?? {}).length > 0;
  step(c.done.hidden, 'withheld wherever it turns up', `withhold it${why('hidden')}`);
  if (c.harmful) return { done, todo, failed: failed() };
  if (c.account) {
    step(c.done.held, `held for a year at the least, with a copy of each picture it set at ${heldPictureKey(c.account, '')}... in open-hearts-records`, `hold it${why('held')}: ./oh account hold ${c.account} --apply`);
    step(c.done.ended, 'terminated, its web subscription ended in Stripe, nothing refunded', `terminate it${why('ended')}: ./oh account terminate ${c.account} --serious --apply`);
  }
  if (c.done.reported) {
    done.push(c.test ? `filed to NCMEC's test service only, report ${c.done.reported}: nothing went to NCMEC` : `reported to NCMEC's CyberTipline, report ${c.done.reported}`);
  }
  if (!c.done.reported || c.test) {
    const by = c.account ? `, then ./oh account hold ${c.account} --ref <number> --apply` : '';
    todo.push(ncmec && !c.test ? `report it to NCMEC${why('reported')}` : `report it to NCMEC yourself, at https://report.cybertip.org/ (docs/how-to/handle-abuse-material.md)${by}`);
  }
  return { done, todo, failed: failed() };
}

/// The email of a case: {subject, text}. It never holds the picture.
export function caseEmail(c, lines) {
  const who = c.account ? `account ${c.account}` : 'a device the relay did not know';
  const failing = lines.failed ? ', and an automatic step failed' : '';
  const by = listed(checkersIn(c).map((id) => CHECKERS[id]?.name ?? id));
  if (c.harmful) {
    const text = [
      `${by} knows a picture ${who} set at ${c.at} as harmful or abusive material of a child. It is not known child sexual abuse material, so nothing else is done by itself: the account is not held, terminated or reported.`,
      c.shown ? `It was shown to other players before ${by} had said; it is withheld now.` : 'It was refused as it was set, before any other player was shown it.',
      '',
      'Done:',
      ...lines.done.map((l) => `- ${l}`),
      ...(lines.todo.length ? ['', 'Not done yet:', ...lines.todo.map((l) => `- ${l}`)] : []),
      ...(c.account ? ['', `If the account should not go on: ./oh account suspend ${c.account} --apply (docs/how-to/suspend-an-account.md).`] : []),
      '',
      `The picture's SHA-256 is ${c.digest}. No copy of it is kept.`,
    ].join('\n');
    return { subject: `Open Hearts: a picture was refused as harmful or abusive material of a child${failing}`, text };
  }
  const text = [
    c.viewed
      ? `You reported a picture ${who} set as child sexual abuse material${c.how ? ` (${c.how})` : ''}, at ${c.at}.`
      : by
        ? `${by} matched a picture ${who} set at ${c.at} against known images of child sexual abuse.`
        : `A picture ${who} set at ${c.at} is one you reported before as child sexual abuse material.`,
    c.viewed ? 'It had been shown to other players; it is withheld now.' : c.shown ? 'It was shown to other players before the match was known; it is withheld now.' : 'It was withheld before any other player was shown it.',
    '',
    'Done:',
    ...lines.done.map((l) => `- ${l}`),
    ...(lines.todo.length ? ['', 'Not done yet:', ...lines.todo.map((l) => `- ${l}`)] : ['', 'Nothing needs you.']),
    '',
    `The picture's SHA-256 is ${c.digest}. Don't download it except to report it (docs/how-to/handle-abuse-material.md).`,
  ].join('\n');
  const subject = failing || (lines.todo.length ? ' (something for you to do)' : '');
  return { subject: `Open Hearts: ${c.viewed ? 'a picture you reported was taken down' : 'a known child abuse image was blocked'}${subject}`, text };
}

/// The object, where the checker in use is asked and every match acted
/// on. Its storage: `pic:<digest>`, what each checker said of a picture
/// and when ({by: {id: said}, at: {id: ISO}}, each 'clear', 'match',
/// 'harmful' or 'unreadable', and `operator: 'match'` for a picture the
/// operator reported); `retry:<digest>`, a picture the checker has not
/// answered for yet ({jpeg, seen: [{account, key}], tries, next, at},
/// `at` when it was first let through); `case:<digest>:<account>`, a
/// match being acted on ({digest, account, key, name, jpeg, by,
/// knownAt, at, shown, done, failed, tries, told}, [by] who matched it
/// and [knownAt] when), the picture dropped from it once it is held and
/// reported, or [harmful], a picture Shield knows as harmful, only
/// withheld and told of; and `report:<id>`, what a report the operator
/// made was answered ({at, body}).
export class KnownPictures {
  constructor(state, env = {}, { hasher = pictureHash, edgeHasher = null, fetchImpl = fetch, now = Date.now, log = (line) => console.log(line) } = {}) {
    this.state = state;
    this.storage = state.storage;
    this.env = env;
    // What makes a picture's PDQ hash for Shield (arachnid.mjs), and its
    // Edge Hashes for PhotoDNA (photodna.mjs, jpegHasher), with the
    // module the relay was deployed with, if it was (photodna_off.mjs).
    this.hasher = hasher;
    this.edgeHasher = edgeHasher;
    // What this object reaches the world with: the checkers, the
    // service, NCMEC. Not `fetch`, which is how the runtime reaches the
    // object.
    this.http = fetchImpl;
    this.now = now;
    this.log = log;
  }

  /// The checker in use, once it checks pictures, and what it lacks
  /// (checkers.mjs, checkersOf): {on, missing}.
  async checkers() {
    return checkersOf(this.env, { checker: await checkerIn(this.env), fetchImpl: this.http, pdq: this.hasher, edgeHasher: this.edgeHasher, log: this.log });
  }

  /// [what] failed, with [error]: the operator emailed, once in a while
  /// (alerts.mjs, alertKnownProblem), and the log told.
  async problem(what, error) {
    const text = `${error?.message ?? error}`;
    this.log(`known pictures: ${what}: ${text}`);
    await alertKnownProblem(this.env, storeOf(this.env), { what, error: text, now: this.now() });
  }

  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (request.method === 'POST' && path === '/check') {
      const asked = await request.json().catch(() => null);
      if (typeof asked?.jpeg !== 'string') return Response.json({ said: 'off' });
      try {
        return Response.json(await this.check(asked));
      } catch (e) {
        // Let through, as when a checker does not answer.
        await this.problem('error', e);
        return Response.json({ said: 'failed' });
      }
    }
    // The operator's tool, through the relay worker (knownReport): a
    // picture they found, reported (`oh picture report`).
    if (request.method === 'POST' && path === '/report') {
      const { status, body } = await this.reported(await request.json().catch(() => null));
      return Response.json(body, { status });
    }
    // The relay's daily schedule: anything left to do, such as a report
    // waiting on NCMEC's credentials, tried again.
    if (request.method === 'POST' && path === '/wake') {
      await this.alarm();
      return Response.json({ ok: true });
    }
    return new Response('not here\n', { status: 404 });
  }

  async alarm() {
    try {
      await this.work();
    } catch (e) {
      await this.problem('error', e);
      await this.wakeBy(this.now() + retryAfter(4));
    }
  }

  /// What is said of the picture [jpeg] (base64) an [account] set, from
  /// its device [key] (null for the daily run's asking again): {said,
  /// knownBy, knownAt}. [said] is 'clear', 'match', 'harmful',
  /// 'unreadable' (it cannot be decoded or hashed, so it cannot be asked
  /// about), 'failed' (the checker in use did not answer) or 'off' (no
  /// checker checks pictures); for any but the last two, [knownBy] is
  /// the checker that said it and [knownAt] when (receiptOf). A picture
  /// is asked about once: what either checker said of it stands, whichever
  /// is in use now (checkers.mjs, verdictOf), and the one in use is asked
  /// only while nothing is said. A match, or a harmful one, is acted on
  /// for each account that sets it, [shown] when others may have seen
  /// it, as when it was set before the checker had said, [at] (ISO)
  /// then.
  async check({ jpeg, account = null, key = null, shown = false, at = null }) {
    const { on, missing } = await this.checkers();
    for (const m of missing) await this.problem('config', m);
    if (!on.length) return { said: 'off' };
    const digest = await pictureDigest(jpeg);
    if (!digest) return { said: 'off' };
    const { said, answers, failures } = await this.consult(digest, jpeg, on);
    for (const f of failures) await this.problem(f.id, `a picture was let through unchecked, to be asked about again: ${f.message}`);
    const receipt = said ? receiptOf(answers, said) : {};
    if (said === 'match' || said === 'harmful') {
      // A picture let through before, while the checker did not answer,
      // was shown: its accounts are acted on as the retry finds them.
      const waiting = await this.storage.get(`retry:${digest}`);
      if (waiting) await this.matchedLate(digest, waiting, { asking: account, said, answers, receipt });
      await this.open({ digest, jpeg, account, key, shown, at, harmful: said === 'harmful', by: saying(answers.by, said), knownAt: receipt.knownAt });
    }
    // Asked again until something is said of it.
    if (said === null) await this.notAnswered(digest, jpeg, account, key, at);
    else await this.storage.delete(`retry:${digest}`);
    return { said: said ?? 'failed', ...receipt };
  }

  /// What is said of the picture [jpeg] (base64), [digest]: what either
  /// checker said of it before, or else what the checkers [on] (the one
  /// in use) say now: {said, answers, failures}. [said] is what it comes
  /// to (checkers.mjs, verdictOf), null while nothing is; [answers] what
  /// each said, and when (answersOf); and [failures] each in [on] that
  /// did not answer, {id, message}. What each answers is kept, so that
  /// it is asked once.
  async consult(digest, jpeg, on) {
    const answers = answersOf(await this.storage.get(`pic:${digest}`));
    const { by, at } = answers;
    const ids = on.map((c) => c.id);
    const failures = [];
    const asking = verdictOf(by, ids) === null ? on.filter((c) => !Object.hasOwn(by, c.id)) : [];
    if (asking.length) {
      const bytes = bytesOf(jpeg);
      const said = await Promise.all(
        asking.map(async (c) => {
          try {
            return [c.id, await c.ask(bytes, digest)];
          } catch (e) {
            if (e instanceof Unreadable) return [c.id, 'unreadable'];
            failures.push({ id: c.id, message: e?.message ?? `${e}` });
            return null;
          }
        }),
      );
      const answered = said.filter(Boolean);
      for (const [id, s] of answered) {
        by[id] = s;
        at[id] = new Date(this.now()).toISOString();
      }
      if (answered.length) await this.storage.put(`pic:${digest}`, { by, at });
    }
    return { said: verdictOf(by, ids), answers, failures };
  }

  /// The report the operator's tool wrote ([asked], its row and [id],
  /// reportRow), acted on as a match is: for each account that set the
  /// picture, as each has a copy of it and as the operator named, a
  /// case that says the operator looked at it; and the picture known from
  /// then on, so that whoever sets it again is acted on too. Asked
  /// again, as the tool does when an answer is lost, it is answered as
  /// before, and nothing done twice. {status, body}.
  async reported(asked) {
    const id = asked?.id;
    if (!isReportId(id)) return { status: 400, body: { error: 'a report, 32 hex' } };
    const answered = await this.storage.get(`report:${id}`);
    if (answered) return { status: 200, body: answered.body };
    const digest = asked.digest;
    const named = (Array.isArray(asked.accounts) ? asked.accounts : []).filter(isAccount);
    if (typeof digest !== 'string' || !/^[0-9a-f]{64}$/.test(digest)) return { status: 400, body: { error: 'a picture, its SHA-256' } };
    const jpeg = await this.copyOf(digest, named);
    if (!jpeg) return { status: 404, body: { error: 'no copy of that picture is kept: report it by hand' } };
    const accounts = [...named];
    if (this.env.OH_PICTURES) {
      for (const a of await accountsWith(r2Objects(this.env.OH_PICTURES), digest)) if (!accounts.includes(a)) accounts.push(a);
    }
    const how = typeof asked.how === 'string' && asked.how.trim() ? asked.how.trim().slice(0, HOW_MOST) : null;
    const { by, at } = answersOf(await this.storage.get(`pic:${digest}`));
    const knownAt = new Date(this.now()).toISOString();
    await this.storage.put(`pic:${digest}`, { by: { ...by, [OPERATOR]: 'match' }, at: { ...at, [OPERATOR]: knownAt } });
    await this.storage.delete(`retry:${digest}`);
    for (const account of accounts.length ? accounts : [null]) await this.open({ digest, jpeg, account, key: null, shown: true, viewed: true, how, by: [OPERATOR], knownAt });
    const body = { reported: digest, accounts };
    const now = this.now();
    for (const [old, { at }] of await this.storage.list({ prefix: 'report:' })) if (now - at >= REPORT_KEPT_S * 1000) await this.storage.delete(old);
    await this.storage.put(`report:${id}`, { at: now, body });
    return { status: 200, body };
  }

  /// The picture [digest], base64, from wherever a copy is kept: an
  /// account's copy, one of [accounts]' first, then a hold's copy for one
  /// of them, or a picture taken off one of their profiles
  /// (suspension.mjs, HELD). Null for none.
  async copyOf(digest, accounts) {
    const env = this.env;
    const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
    const read = async (bucket, key) => (bucket ? await r2Objects(bucket).read(key) : null);
    const others = env.OH_PICTURES ? await accountsWith(r2Objects(env.OH_PICTURES), digest) : [];
    for (const account of new Set([...accounts, ...others])) {
      const copy = await read(env.OH_PICTURES, pictureKey(account, digest));
      if (copy) return b64(copy);
    }
    const store = storeOf(env);
    for (const account of accounts) {
      const held = await read(env.OH_RECORDS, heldPictureKey(account, digest));
      if (held) return b64(held);
      const taken = (await store?.get(`ACCOUNT#${account}`, 'HELD'))?.picture;
      if (taken && (await pictureDigest(taken)) === digest) return taken;
    }
    return null;
  }

  /// [digest] let through unchecked: asked about again, with each
  /// account that sets it meanwhile noted.
  async notAnswered(digest, jpeg, account, key, at = null) {
    const was = await this.storage.get(`retry:${digest}`);
    const tries = (was?.tries ?? 0) + 1;
    const next = this.now() + retryAfter(tries);
    const seen = was?.seen ?? [];
    if (account && !seen.some((s) => s.account === account)) seen.push({ account, key });
    // When it was first let through: the time its report gives.
    const first = was?.at ?? at ?? new Date(this.now()).toISOString();
    await this.storage.put(`retry:${digest}`, { jpeg, seen, tries, next, at: first });
    await this.wakeBy(next);
  }

  /// A picture a checker matched after it was let through, or knows as
  /// harmful ([said]; [answers] and [receipt] say who said it, and
  /// when): every account that set it, as noted here and as each has a
  /// copy of it (profile_pictures.mjs), acted on, and each copy taken
  /// down. [asking] is the account whose setting it found the match,
  /// which is acted on as it asks; when nobody is known at all, the
  /// match is acted on without an account.
  async matchedLate(digest, waiting, { asking = null, said, answers, receipt }) {
    const seen = [...waiting.seen];
    if (this.env.OH_PICTURES) {
      for (const account of await accountsWith(r2Objects(this.env.OH_PICTURES), digest)) {
        if (!seen.some((s) => s.account === account)) seen.push({ account, key: null });
      }
    }
    if (!seen.length && !asking) seen.push({ account: null, key: null });
    for (const { account, key } of seen) {
      await this.open({ digest, jpeg: waiting.jpeg, account, key, shown: true, at: waiting.at ?? null, harmful: said === 'harmful', by: saying(answers.by, said), knownAt: receipt.knownAt });
    }
  }

  /// A case opened for [account]'s use of a matched picture, once, set
  /// at [at] (ISO; now, unless it is known to be earlier), [by] who said
  /// it — the checkers, or the operator — and [knownAt] when: [viewed]
  /// when the operator found it and looked at it, saying [how];
  /// [harmful] for one Shield knows as harmful, which is withheld and
  /// told of, and whose picture is not kept here. A harmful one's case is
  /// opened again as a match's, as when the operator reports the picture.
  async open({ digest, jpeg, account, key, shown, at = null, viewed = false, how = null, harmful = false, by = [], knownAt = null }) {
    const id = `case:${digest}:${account ?? 'none'}`;
    const was = await this.storage.get(id);
    if (was && (harmful || !was.harmful)) return;
    const store = storeOf(this.env);
    // The name it played under, for the report, before anything here
    // changes the account.
    const name = account && store ? (await store.get(`ACCOUNT#${account}`, 'PROFILE'))?.name ?? null : null;
    const when = typeof at === 'string' && Date.parse(at) <= this.now() ? at : new Date(this.now()).toISOString();
    await this.storage.put(id, { digest, account, key, name, ...(harmful ? { harmful } : { jpeg }), by, knownAt, at: when, shown, ...(viewed ? { viewed, how } : {}), done: {}, failed: {}, tries: 0, told: '' });
    await this.wakeBy(this.now());
  }

  /// The alarm set for [at] at the latest.
  async wakeBy(at) {
    const set = await this.storage.getAlarm();
    if (set === null || set > at) await this.storage.setAlarm(at);
  }

  /// Everything still to do: pictures the checker in use has not
  /// answered for asked about again, and each open case's steps tried;
  /// the alarm set for whatever is left.
  async work() {
    let next = null;
    const later = (at) => (next = next === null ? at : Math.min(next, at));
    const { on } = await this.checkers();
    for (const [id, waiting] of on.length ? await this.storage.list({ prefix: 'retry:' }) : []) {
      if (waiting.next > this.now()) {
        later(waiting.next);
        continue;
      }
      const digest = id.slice('retry:'.length);
      const { said, answers, failures } = await this.consult(digest, waiting.jpeg, on);
      for (const f of failures) await this.problem(f.id, `a picture let through earlier is still unchecked: ${f.message}`);
      if (said === 'match' || said === 'harmful') await this.matchedLate(digest, waiting, { said, answers, receipt: receiptOf(answers, said) });
      if (said === null) {
        const tries = waiting.tries + 1;
        await this.storage.put(id, { ...waiting, tries, next: this.now() + retryAfter(tries) });
        later(this.now() + retryAfter(tries));
      } else {
        await this.storage.delete(id);
      }
    }
    for (const [id, c] of await this.storage.list({ prefix: 'case:' })) {
      if (c.closed) continue;
      const after = await this.act(id, c);
      if (!after.closed && after.retry) later(this.now() + retryAfter(after.tries));
    }
    if (next !== null) await this.wakeBy(next);
  }

  /// The case [c]'s steps not yet done, tried in turn, and the operator
  /// told when what is done changes. Resolves the case as written:
  /// `closed` once there is nothing left, `retry` while a step failed.
  async act(id, c) {
    const env = this.env;
    const store = storeOf(env);
    const now = this.now();
    const ncmec = ncmecOf(env);
    const failed = {};
    const attempt = async (step, run) => {
      if (c.done[step]) return;
      try {
        c.done[step] = (await run()) ?? true;
      } catch (e) {
        failed[step] = e?.message ?? `${e}`;
      }
    };
    await attempt('hidden', async () => {
      if (!store) throw new Error('no store');
      const row = await store.get(...PICTURES_ROW);
      if (!withheldOf(row, now).has(c.digest)) await store.put(...PICTURES_ROW, withholding(row, c.digest, now));
      // The account's copy, kept if it was ever let through, which an
      // address serves: the case keeps the picture until the hold has it.
      // No picture it set before becomes its picture now as it goes.
      if (c.account && env.OH_PICTURES) await deleteCopy(env.OH_PICTURES, c.account, c.digest);
    });
    if (c.account && !c.harmful) {
      await attempt('held', async () => {
        if (!store || !env.OH_RECORDS) throw new Error('no store or OH_RECORDS');
        await hold(store, c.account, { now });
        await env.OH_RECORDS.put(heldPictureKey(c.account, c.digest), bytesOf(c.jpeg), { httpMetadata: { contentType: 'image/jpeg' } });
        if (env.OH_PICTURES) await keepHeldPictures(r2Objects(env.OH_PICTURES), r2Objects(env.OH_RECORDS), c.account);
      });
      await attempt('ended', async () => {
        if (!store || !env.OH_APP_ORIGIN) throw new Error('no store or app origin');
        const order = { ...orderOf(c.account, 'terminate', { now }), endWeb: true };
        const r = await placeOrder(store, order, { origin: env.OH_APP_ORIGIN, fetchImpl: this.http, tries: 1 });
        // An account that is no longer there has nothing to end.
        if (r?.status === 404 && r.body?.error === 'no such account') return 'no such account';
        if (r?.status !== 200) throw new Error(`the service said ${r?.status ?? 'nothing'}${r?.body?.error ? `: ${r.body.error}` : ''}`);
      });
    }
    if (ncmec && !c.harmful) {
      await attempt('reported', async () => {
        const fileName = `${c.digest}.jpg`;
        const report = reportXml({
          at: c.at,
          reporter: ncmec.reporter,
          account: c.account,
          name: c.name,
          device: c.key,
          found: c.viewed
            ? `Found by the operator, who looked at it${c.how ? `: ${c.how}` : ''}.`
            : checkersIn(c).length
              ? `Matched ${listed(checkersIn(c).map((id) => CHECKERS[id]?.found ?? `by ${id}`))} as it was set as a profile picture.`
              : 'Matched by its SHA-256 with a picture the operator had looked at and reported before, as it was set as a profile picture.',
          done: c.account ? 'The picture was withheld, and the account closed.' : 'The picture was withheld.',
        });
        const ref = await fileReport({
          endpoint: ncmec.endpoint,
          username: ncmec.username,
          password: ncmec.password,
          report,
          jpeg: bytesOf(c.jpeg),
          fileName,
          details: (reportId, fileId) => fileDetailsXml({ reportId, fileId, fileName, at: c.at, digest: c.digest, shown: c.shown, viewed: !!c.viewed }),
          fetchImpl: this.http,
        });
        c.test = ncmec.test;
        if (c.account && store && !ncmec.test) await hold(store, c.account, { ref, now });
        return ref;
      });
    }
    c.failed = failed;
    const retry = Object.keys(failed).length > 0;
    if (retry) c.tries += 1;
    const lines = caseLines(c, { ncmec });
    const told = JSON.stringify(lines);
    const alerts = alertsOf(env);
    const canTell = !!(alerts && env.EMAIL);
    if (told !== c.told && canTell) {
      try {
        await env.EMAIL.send({ to: alerts.to, from: { email: env.OH_MAIL_FROM, name: 'Open Hearts' }, ...caseEmail(c, lines) });
        c.told = told;
      } catch (e) {
        // Nothing to email it with: the log is all there is.
        this.log(`a match's email not sent: ${e?.message ?? e}`);
      }
    }
    // Done when every step is: the report too, unless only the operator
    // can file it (no credentials, or only the test service). A harmful
    // picture's only step is withholding it.
    const reported = c.harmful || (!!c.done.reported && !c.test);
    c.closed = !!c.done.hidden && (c.harmful || !c.account || (!!c.done.held && !!c.done.ended)) && reported && (c.told === told || !canTell);
    // The picture is kept here only while a step still needs it.
    if (c.closed || (c.done.held && c.done.reported)) delete c.jpeg;
    const after = { ...c, retry };
    await this.storage.put(id, { ...c });
    return after;
  }
}

export { NcmecRefused };
