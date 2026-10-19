// Known images of child sexual abuse, kept from being shown at all.
// Each new picture an account puts out is asked about once, before the
// relay carries it, of Microsoft's PhotoDNA (service/functions/
// photodna.mjs), from one object in Cloudflare's "us" jurisdiction, so
// that every request PhotoDNA gets comes from the United States. A
// picture that matches is withheld, and everything that follows is done
// here, with nothing waiting on the operator
// (docs/how-to/handle-abuse-material.md):
//
//   1. the picture withheld wherever it was put out (pictures.mjs);
//   2. each account that put it out held (holds.mjs), a copy of the
//      picture and of every other it put out kept where only the
//      operator reaches them, and any public copy of it deleted;
//   3. each such account terminated, its web subscriptions ended in
//      Stripe with nothing refunded (an order the service carries out,
//      suspension.mjs);
//   4. a report filed to NCMEC's CyberTipline (ncmec.mjs), its number
//      written on the hold;
//   5. the operator emailed what was done, and anything still to do.
//
// Each step is written down as it is done, and the object's alarm tries
// the rest again until all are: Stripe or NCMEC not answering delays a
// step, and loses none. PhotoDNA not answering lets the picture through,
// so the game goes on, and asks again; a match found then is acted on
// as any other, and the copy shown meanwhile taken down with it.
//
// Off until the deployment has PhotoDNA's key (OH_PHOTODNA_KEY); a
// report is filed once it has NCMEC's credentials too, and until then
// the email says to file it by hand.

import { heldPictureKey, hold, keepHeldPictures } from '../functions/holds.mjs';
import { NcmecRefused, fileDetailsXml, fileReport, reportXml } from '../functions/ncmec.mjs';
import { photoDnaMatch } from '../functions/photodna.mjs';
import { PICTURES_ROW, WITHHELD_WHY, copyKey, pictureDigest, pictureIn, withheldOf, withholding } from '../functions/pictures.mjs';
import { isAccount, storeOf } from '../functions/rows.mjs';
import { orderOf } from '../functions/suspension.mjs';
import { accountsThatPutOut } from '../tool/find.mjs';
import { placeOrder } from '../tool/suspend.mjs';
import { alertKnownProblem, alertsOf } from '../functions/alerts.mjs';
import { lobbyKind } from './relay.mjs';

/// The one object every check goes through.
export const KNOWN_OBJECT = 'photodna';

/// How many pictures a relay object remembers PhotoDNA cleared, so
/// that it asks about each once while it is awake.
const remembered = 2000;

/// How long before a step that failed is tried again: a minute, then
/// doubling, to six hours at the most.
export const retryAfter = (tries) => Math.min(6 * 60 * 60 * 1000, 60 * 1000 * 2 ** Math.max(0, tries - 1));

const bytesOf = (base64) => Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));

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
/// account, key} -> 'clear', 'match', 'failed' (PhotoDNA did not answer)
/// or 'off'. Null where there is nothing to ask: no PhotoDNA key, or a
/// runtime that cannot keep the object in the United States.
export function knownAsker(env) {
  if (!env.KNOWN || !env.OH_PHOTODNA_KEY || typeof env.KNOWN.jurisdiction !== 'function') return null;
  const us = env.KNOWN.jurisdiction('us');
  const stub = us.get(us.idFromName(KNOWN_OBJECT));
  return async (asked) => {
    const res = await stub.fetch('https://known/check', { method: 'POST', body: JSON.stringify(asked) });
    if (!res.ok) throw new Error(`said ${res.status}`);
    return (await res.json()).said;
  };
}

/// What a relay object says of each picture published to it, and who
/// said it (relay.mjs, `screen`): WITHHELD_WHY for one PhotoDNA matched,
/// as for one the operator took down, so that nothing tells the device
/// why; otherwise null. A picture is asked about until PhotoDNA has
/// cleared it, then remembered as clear; [ask] failing lets it through,
/// to be asked about again, and is told to [failed].
export function knownScreen({ ask, log = null, failed = null }) {
  const clear = new Set();
  return async (event, who) => {
    if (event?.kind !== lobbyKind) return null;
    const jpeg = pictureIn(event.content);
    if (!jpeg) return null;
    const digest = await pictureDigest(jpeg);
    if (!digest || clear.has(digest)) return null;
    let said;
    try {
      said = await ask({ jpeg, account: isAccount(who?.account) ? who.account : null, key: who?.key ?? null });
    } catch (e) {
      const why = `a relay could not ask whether a picture is a known image: ${e?.message ?? e}`;
      log?.(why);
      failed?.(why);
      return null;
    }
    if (said === 'match') return WITHHELD_WHY;
    if (said === 'clear') {
      if (clear.size >= remembered) clear.clear();
      clear.add(digest);
    }
    return null;
  };
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
/// has not: {done: [line], todo: [line]}.
export function caseLines(c, { ncmec }) {
  const done = [];
  const todo = [];
  const step = (ok, did, failing) => (ok ? done.push(did) : todo.push(failing));
  const why = (s) => (c.failed?.[s] ? ` (${c.failed[s]}; tried again by itself)` : ' (tried again by itself)');
  step(c.done.hidden, 'withheld wherever it was put out', `withhold it${why('hidden')}`);
  if (c.account) {
    step(c.done.held, `held for a year at the least, with a copy of each picture it put out in the last 30 days at ${heldPictureKey(c.account, '')}... in open-hearts-records`, `hold it${why('held')}: ./oh account hold ${c.account} --apply`);
    step(c.done.ended, 'terminated, its web subscription ended in Stripe, nothing refunded', `terminate it${why('ended')}: ./oh account terminate ${c.account} --serious --apply`);
  }
  if (c.done.reported) {
    done.push(c.test ? `filed to NCMEC's test service only, report ${c.done.reported}: nothing went to NCMEC` : `reported to NCMEC's CyberTipline, report ${c.done.reported}`);
  }
  if (!c.done.reported || c.test) {
    const by = c.account ? `, then ./oh account hold ${c.account} --ref <number> --apply` : '';
    todo.push(ncmec && !c.test ? `report it to NCMEC${why('reported')}` : `report it to NCMEC yourself, at https://report.cybertip.org/ (docs/how-to/handle-abuse-material.md)${by}`);
  }
  return { done, todo, failed: Object.keys(c.failed ?? {}).length > 0 };
}

/// The email of a case: {subject, text}. It never holds the picture.
export function caseEmail(c, lines) {
  const who = c.account ? `account ${c.account}` : 'a device the relay did not know';
  const text = [
    `Microsoft's PhotoDNA matched a picture ${who} put out at ${c.at} against known images of child sexual abuse.`,
    c.shown ? 'It was shown to other players before the match was known; it is withheld now.' : 'It was withheld before any other player was shown it.',
    '',
    'Done:',
    ...lines.done.map((l) => `- ${l}`),
    ...(lines.todo.length ? ['', 'Not done yet:', ...lines.todo.map((l) => `- ${l}`)] : ['', 'Nothing needs you.']),
    '',
    `The picture's SHA-256 is ${c.digest}. Don't download it except to report it (docs/how-to/handle-abuse-material.md).`,
  ].join('\n');
  const subject = lines.failed ? ', and an automatic step failed' : lines.todo.length ? ' (something for you to do)' : '';
  return { subject: `Open Hearts: a known child abuse image was blocked${subject}`, text };
}

/// The object, where PhotoDNA is asked and every match acted on. Its
/// storage: `pic:<digest>`, what PhotoDNA said of a picture ({said:
/// 'clear' or 'match', at}); `retry:<digest>`, a picture PhotoDNA has
/// not answered for yet ({jpeg, accounts, keys, tries, next}); and
/// `case:<digest>:<account>`, a match being acted on ({digest, account,
/// key, name, jpeg, at, shown, done, failed, tries, told}), the picture
/// dropped from it once it is held and reported.
export class KnownPictures {
  constructor(state, env = {}, { fetchImpl = fetch, now = Date.now, log = (line) => console.log(line) } = {}) {
    this.state = state;
    this.storage = state.storage;
    this.env = env;
    // What this object reaches the world with: PhotoDNA, the service,
    // NCMEC. Not `fetch`, which is how the runtime reaches the object.
    this.http = fetchImpl;
    this.now = now;
    this.log = log;
  }

  get photoDna() {
    const { OH_PHOTODNA_KEY: key, OH_PHOTODNA_ENDPOINT: endpoint } = this.env;
    return key && endpoint ? { key, endpoint, fetchImpl: this.http } : null;
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
        return Response.json({ said: await this.check(asked) });
      } catch (e) {
        // Let through, as when PhotoDNA does not answer.
        await this.problem('error', e);
        return Response.json({ said: 'failed' });
      }
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

  /// What PhotoDNA says of the picture [jpeg] (base64) an [account]'s
  /// device [key] put out: 'clear', 'match', 'failed' or 'off'. Asked of
  /// PhotoDNA once; a match is acted on for each account that puts it
  /// out.
  async check({ jpeg, account = null, key = null }) {
    if (!this.photoDna) {
      if (this.env.OH_PHOTODNA_KEY) await this.problem('config', 'OH_PHOTODNA_KEY is set but photodna.endpoint in config/openhearts.json is not, so no picture is checked');
      return 'off';
    }
    const digest = await pictureDigest(jpeg);
    if (!digest) return 'off';
    const known = await this.storage.get(`pic:${digest}`);
    if (known?.said === 'clear') return 'clear';
    if (known?.said === 'match') {
      await this.open({ digest, jpeg, account, key, shown: false });
      return 'match';
    }
    let match;
    try {
      match = await photoDnaMatch(bytesOf(jpeg), this.photoDna);
    } catch (e) {
      await this.problem('photodna', `a picture was let through unchecked, to be asked about again: ${e.message}`);
      await this.notAnswered(digest, jpeg, account, key);
      return 'failed';
    }
    await this.decided(digest, match);
    if (match) {
      // A picture let through before, while PhotoDNA did not answer, was
      // shown: its accounts are acted on as the retry finds them.
      const waiting = await this.storage.get(`retry:${digest}`);
      if (waiting) await this.matchedLate(digest, waiting, account);
      await this.open({ digest, jpeg, account, key, shown: false });
    }
    return match ? 'match' : 'clear';
  }

  async decided(digest, match) {
    await this.storage.put(`pic:${digest}`, { said: match ? 'match' : 'clear', at: new Date(this.now()).toISOString() });
  }

  /// [digest] let through unchecked: asked about again, with each
  /// account that puts it out meanwhile noted.
  async notAnswered(digest, jpeg, account, key) {
    const was = await this.storage.get(`retry:${digest}`);
    const tries = (was?.tries ?? 0) + 1;
    const next = this.now() + retryAfter(tries);
    const seen = was?.seen ?? [];
    if (account && !seen.some((s) => s.account === account)) seen.push({ account, key });
    await this.storage.put(`retry:${digest}`, { jpeg, seen, tries, next });
    await this.wakeBy(next);
  }

  /// A picture PhotoDNA matched after it was let through: every account
  /// that put it out, as noted here and as the relay's copies note
  /// (review.mjs), acted on, and the picture's public copy taken down.
  /// [asking] is the account whose putting it out found the match, which
  /// is acted on as it asks; when nobody is known at all, the match is
  /// acted on without an account.
  async matchedLate(digest, waiting, asking = null) {
    const seen = [...waiting.seen];
    if (this.env.OH_PICTURES) {
      for (const account of await accountsThatPutOut(r2Objects(this.env.OH_PICTURES), digest)) {
        if (!seen.some((s) => s.account === account)) seen.push({ account, key: null });
      }
    }
    if (!seen.length && !asking) seen.push({ account: null, key: null });
    for (const { account, key } of seen) await this.open({ digest, jpeg: waiting.jpeg, account, key, shown: true });
    await this.storage.delete(`retry:${digest}`);
  }

  /// A case opened for [account]'s use of a matched picture, once.
  async open({ digest, jpeg, account, key, shown }) {
    const id = `case:${digest}:${account ?? 'none'}`;
    if (await this.storage.get(id)) return;
    const store = storeOf(this.env);
    // The name it played under, for the report, before anything here
    // changes the account.
    const name = account && store ? (await store.get(`ACCOUNT#${account}`, 'PROFILE'))?.name ?? null : null;
    await this.storage.put(id, { digest, account, key, name, jpeg, at: new Date(this.now()).toISOString(), shown, done: {}, failed: {}, tries: 0, told: '' });
    await this.wakeBy(this.now());
  }

  /// The alarm set for [at] at the latest.
  async wakeBy(at) {
    const set = await this.storage.getAlarm();
    if (set === null || set > at) await this.storage.setAlarm(at);
  }

  /// Everything still to do: pictures PhotoDNA has not answered for
  /// asked about again, and each open case's steps tried; the alarm set
  /// for whatever is left.
  async work() {
    let next = null;
    const later = (at) => (next = next === null ? at : Math.min(next, at));
    if (this.photoDna) {
      for (const [id, waiting] of await this.storage.list({ prefix: 'retry:' })) {
        if (waiting.next > this.now()) {
          later(waiting.next);
          continue;
        }
        const digest = id.slice('retry:'.length);
        let match;
        try {
          match = await photoDnaMatch(bytesOf(waiting.jpeg), this.photoDna);
        } catch (e) {
          await this.problem('photodna', `a picture let through earlier is still unchecked: ${e.message}`);
          const tries = waiting.tries + 1;
          await this.storage.put(id, { ...waiting, tries, next: this.now() + retryAfter(tries) });
          later(this.now() + retryAfter(tries));
          continue;
        }
        await this.decided(digest, match);
        if (match) await this.matchedLate(digest, waiting);
        else await this.storage.delete(id);
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
      // The copy made while it was let through, which an address
      // serves: the case keeps the picture until the hold has it.
      if (c.shown && env.OH_PICTURES) await env.OH_PICTURES.delete(copyKey(c.digest));
    });
    if (c.account) {
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
    if (ncmec) {
      await attempt('reported', async () => {
        const fileName = `${c.digest}.jpg`;
        const report = reportXml({
          at: c.at,
          reporter: ncmec.reporter,
          account: c.account,
          name: c.name,
          device: c.key,
          done: c.account ? 'The picture was withheld, and the account closed.' : 'The picture was withheld.',
        });
        const ref = await fileReport({
          endpoint: ncmec.endpoint,
          username: ncmec.username,
          password: ncmec.password,
          report,
          jpeg: bytesOf(c.jpeg),
          fileName,
          details: (reportId, fileId) => fileDetailsXml({ reportId, fileId, fileName, at: c.at, digest: c.digest, shown: c.shown }),
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
    // can file it (no credentials, or only the test service).
    const reported = !!c.done.reported && !c.test;
    c.closed = !!c.done.hidden && (!c.account || (!!c.done.held && !!c.done.ended)) && reported && (c.told === told || !canTell);
    // The picture is kept here only while a step still needs it.
    if (c.closed || (c.done.held && c.done.reported)) delete c.jpeg;
    const after = { ...c, retry };
    await this.storage.put(id, { ...c });
    return after;
  }
}

export { NcmecRefused };
