// Subscribers told of a change to the terms or the privacy policy that
// matters to them: a material or price change in the ledger
// (site/ledger.mjs). Every device shows it at the front door for
// [NOTICE_DAYS] from the day it is published (config.mjs, the app's
// OperatorNotes), and each web subscriber is emailed it, in one email
// with any other change they were not told of, when the operator says
// so: never by a deploy. A change to the terms applies to
// a subscription only from its first renewal [APPLIES_AFTER_DAYS] after
// its subscriber was told, so an email sent a day late is a change
// applied a renewal late, never one applied untold.
//
// The ledger is the one the site was built with, bundled with these
// handlers (OH_LEDGER: deploy.sh, entry.mjs), so what is told is what is
// published. The operator's command (`oh terms notify`, ops/terms.mjs)
// names the subscriptions, a few to an order, as `oh account` names an
// account (suspension.mjs): whoever can write an order can write the
// store. Each subscriber's address is asked of Stripe here, and goes no
// further than the mail; what is kept is that the notice was sent, and
// when, under the subscription (`NOTICE#<document>@<version>|SUB#<id>`),
// for as long as the subscription's record is kept.

import { SITE } from './settings.mjs';
import { askStripe } from './stripe.mjs';
import { ORDER_KEPT_S } from './suspension.mjs';

/// How long a device shows a change at the front door, in days.
export const NOTICE_DAYS = 60;

/// How long after a subscriber is told of a change to the terms it can
/// first apply to their subscription, in days: from the first renewal
/// at least this long after, as the terms' "Changes to these terms"
/// says (notices.test.mjs holds the two together).
export const APPLIES_AFTER_DAYS = 30;

/// How many subscriptions one order may name: each is a question to
/// Stripe and a mail, and an order is one request's worth of them.
export const NOTICES_PER_ORDER = 10;

/// The Household object the mail goes through: one of its own, so no
/// account's turn waits on it (alerts.mjs does the same).
export const NOTICES_OBJECT = 'operator-notices';

/// Where a subscription's notice of [document]'s [version] (versionOf)
/// is kept.
export const noticeRow = (document, version, subscription) => [`NOTICE#${document}@${version}`, `SUB#${subscription}`];

/// Which version a ledger entry is: its day, and the day's revision
/// after its first (2026-10-23, 2026-10-23.2), as the ledger names it
/// (site/ledger.mjs, versionOf).
export const versionOf = (entry) => (entry.revision ? `${entry.date}.${entry.revision}` : entry.date);

const LANGUAGES = ['en', 'es', 'pt', 'de', 'fr'];

/// The documents a change is told of, in the order an email names them.
const DOCUMENTS = ['terms', 'privacy'];
const DAY_MS = 86400000;

/// The renewal that a change to the terms, told on [now], first applies
/// at, for a yearly subscription whose year ends at [end] and is billed
/// on the day of [anchor] (Stripe's seconds both): the first renewal at
/// least [APPLIES_AFTER_DAYS] after [now], YYYY-MM-DD. Stripe renews a
/// year on the anchor's day, or on its month's last day where it has
/// none, as a 29 February does in most years.
export function applyingRenewal(end, anchor, now) {
  if (end * 1000 >= now + APPLIES_AFTER_DAYS * DAY_MS) return new Date(end * 1000).toISOString().slice(0, 10);
  const year = new Date(end * 1000).getUTCFullYear() + 1;
  const on = new Date((anchor ?? end) * 1000);
  const last = new Date(Date.UTC(year, on.getUTCMonth() + 1, 0)).getUTCDate();
  return new Date(Date.UTC(year, on.getUTCMonth(), Math.min(on.getUTCDate(), last))).toISOString().slice(0, 10);
}

/// Whether [entry] is a change subscribers are told of.
const told = (entry) => entry?.change === 'material' || entry?.change === 'price';

/// Every change in [ledger] subscribers are told of, as [document,
/// version]: each one a subscription can have a note of ([noticeRow]),
/// which goes with its account (deletion.mjs, forgetAccount).
export const toldVersions = (ledger) => DOCUMENTS.flatMap((document) => (ledger?.[document] ?? []).filter(told).map((entry) => [document, versionOf(entry)]));

/// What a device is shown at the front door on [now], from [ledger]:
/// each document's newest change subscribers are told of, for the
/// [NOTICE_DAYS] days from the day it was published — [{document, date,
/// revision?, summary}], the revision only after the day's first
/// version, and the summary in each language.
export function noticesOf(ledger, now = Date.now()) {
  const before = new Date(now - NOTICE_DAYS * DAY_MS).toISOString().slice(0, 10);
  const today = new Date(now).toISOString().slice(0, 10);
  const out = [];
  for (const document of DOCUMENTS) {
    const entry = (ledger?.[document] ?? []).filter(told).at(-1);
    if (entry && entry.date > before && entry.date <= today) out.push({ document, date: entry.date, ...(entry.revision ? { revision: entry.revision } : {}), summary: entry.summary });
  }
  return out;
}

/// The ledger's entry for [document] of [version] (versionOf), if it is
/// one subscribers are told of; null otherwise.
export function toldEntry(ledger, document, version) {
  const entry = (ledger?.[document] ?? []).find((e) => versionOf(e) === version);
  return told(entry) ? entry : null;
}

/// The language a subscriber is written to in: the one they bought in,
/// as the checkout marked the subscription (stripe.mjs), or the one
/// Stripe has for them, or English.
export function languageOf(subscription) {
  const marked = subscription?.metadata?.lang;
  if (LANGUAGES.includes(marked)) return marked;
  const preferred = String(subscription?.customer?.preferred_locales?.[0] ?? '').slice(0, 2).toLowerCase();
  return LANGUAGES.includes(preferred) ? preferred : 'en';
}

const WORDS = {
  en: {
    subject: { terms: 'Changes to the Open Hearts terms of use', privacy: 'Changes to the Open Hearts privacy policy', both: 'Changes to the Open Hearts terms of use and privacy policy' },
    opening: { terms: 'We have changed the Open Hearts terms of use, on {day}.', privacy: 'We have changed the Open Hearts privacy policy, on {day}.', both: 'We have changed the Open Hearts terms of use and privacy policy, on {day}.' },
    and: 'and',
    name: { terms: 'Terms of use', privacy: 'Privacy policy' },
    read: { terms: 'Read them in full: {url}', privacy: 'Read it in full: {url}' },
    applies: 'The new terms apply to your subscription from its first renewal at least {days} days from today, except where they say a change applies sooner.{renews} If you do not want to go on under them, you can cancel before then, in the game: menu, Subscription, Manage subscription.',
    renews: ' For yours, that is the renewal on {day}.',
    why: 'You are getting this email because you subscribe to Open Hearts on the web.',
  },
  es: {
    subject: { terms: 'Cambios en las condiciones de uso de Open Hearts', privacy: 'Cambios en la política de privacidad de Open Hearts', both: 'Cambios en las condiciones de uso y la política de privacidad de Open Hearts' },
    opening: { terms: 'Hemos cambiado las condiciones de uso de Open Hearts el {day}.', privacy: 'Hemos cambiado la política de privacidad de Open Hearts el {day}.', both: 'Hemos cambiado las condiciones de uso y la política de privacidad de Open Hearts el {day}.' },
    and: 'y',
    name: { terms: 'Condiciones de uso', privacy: 'Política de privacidad' },
    read: { terms: 'Léelas completas: {url}', privacy: 'Léela completa: {url}' },
    applies: 'Las nuevas condiciones se aplican a tu suscripción desde su primera renovación al menos {days} días a partir de hoy, salvo cuando digan que un cambio se aplica antes.{renews} Si no quieres continuar con ellas, puedes cancelar antes, en el juego: menú, Suscripción, Gestionar suscripción.',
    renews: ' Para la tuya, es la renovación del {day}.',
    why: 'Recibes este correo porque estás suscrito a Open Hearts en la web.',
  },
  pt: {
    subject: { terms: 'Mudanças nos termos de uso do Open Hearts', privacy: 'Mudanças na política de privacidade do Open Hearts', both: 'Mudanças nos termos de uso e na política de privacidade do Open Hearts' },
    opening: { terms: 'Mudamos os termos de uso do Open Hearts em {day}.', privacy: 'Mudamos a política de privacidade do Open Hearts em {day}.', both: 'Mudamos os termos de uso e a política de privacidade do Open Hearts em {day}.' },
    and: 'e',
    name: { terms: 'Termos de uso', privacy: 'Política de privacidade' },
    read: { terms: 'Leia-os na íntegra: {url}', privacy: 'Leia-a na íntegra: {url}' },
    applies: 'Os novos termos se aplicam à sua assinatura a partir da primeira renovação que ocorra pelo menos {days} dias depois de hoje, exceto quando disserem que uma mudança se aplica antes.{renews} Se não quiser continuar com eles, você pode cancelar antes disso, no jogo: menu, Assinatura, Gerenciar assinatura.',
    renews: ' Para a sua, é a renovação de {day}.',
    why: 'Você está recebendo este e-mail porque assina o Open Hearts na web.',
  },
  de: {
    subject: { terms: 'Änderungen der Nutzungsbedingungen von Open Hearts', privacy: 'Änderungen der Datenschutzerklärung von Open Hearts', both: 'Änderungen der Nutzungsbedingungen und der Datenschutzerklärung von Open Hearts' },
    opening: { terms: 'Wir haben die Nutzungsbedingungen von Open Hearts am {day} geändert.', privacy: 'Wir haben die Datenschutzerklärung von Open Hearts am {day} geändert.', both: 'Wir haben die Nutzungsbedingungen und die Datenschutzerklärung von Open Hearts am {day} geändert.' },
    and: 'und',
    name: { terms: 'Nutzungsbedingungen', privacy: 'Datenschutzerklärung' },
    read: { terms: 'Hier liest du sie vollständig: {url}', privacy: 'Hier liest du sie vollständig: {url}' },
    applies: 'Die neuen Nutzungsbedingungen gelten für dein Abo ab seiner ersten Verlängerung, die mindestens {days} Tage nach heute liegt, außer wo sie sagen, dass eine Änderung früher gilt.{renews} Wenn du unter ihnen nicht weitermachen willst, kannst du vorher kündigen, im Spiel: Menü, Abo, Abo verwalten.',
    renews: ' Bei deinem ist das die Verlängerung am {day}.',
    why: 'Du bekommst diese E-Mail, weil du Open Hearts im Web abonniert hast.',
  },
  fr: {
    subject: { terms: "Modifications des conditions d'utilisation d'Open Hearts", privacy: "Modifications de la politique de confidentialité d'Open Hearts", both: "Modifications des conditions d'utilisation et de la politique de confidentialité d'Open Hearts" },
    opening: { terms: "Nous avons modifié les conditions d'utilisation d'Open Hearts le {day}.", privacy: "Nous avons modifié la politique de confidentialité d'Open Hearts le {day}.", both: "Nous avons modifié les conditions d'utilisation et la politique de confidentialité d'Open Hearts le {day}." },
    and: 'et',
    name: { terms: "Conditions d'utilisation", privacy: 'Politique de confidentialité' },
    read: { terms: 'Lisez-les en entier : {url}', privacy: 'Lisez-la en entier : {url}' },
    applies: "Les nouvelles conditions s'appliquent à votre abonnement à partir de son premier renouvellement intervenant au moins {days} jours après aujourd'hui, sauf lorsqu'elles indiquent qu'un changement s'applique plus tôt.{renews} Si vous ne souhaitez pas continuer dans ces conditions, vous pouvez résilier avant, dans le jeu : menu, Abonnement, Gérer l'abonnement.",
    renews: " Pour le vôtre, c'est le renouvellement du {day}.",
    why: 'Vous recevez cet e-mail parce que vous êtes abonné à Open Hearts sur le web.',
  },
};

/// The one email that tells a subscriber of [changes] ({document, entry,
/// day} each: a document's newest change they were not told of, and the
/// day the document as it now reads was published, which its page says
/// it was last updated, the entry's own unless given), in [lang],
/// to a subscription whose change to the terms applies at its renewal
/// on [renews] (YYYY-MM-DD, or null for one that does not renew):
/// {subject, text}. Days are written YYYY-MM-DD, which reads the same in
/// every language.
export function noticeMail(lang, changes, { renews = null } = {}) {
  const w = WORDS[lang] ?? WORDS.en;
  const ordered = DOCUMENTS.flatMap((d) => changes.filter((c) => c.document === d));
  const kind = ordered.length > 1 ? 'both' : ordered[0].document;
  const days = [...new Set(ordered.map((c) => c.day ?? c.entry.date))].sort();
  const text = [
    w.opening[kind].replace('{day}', days.join(` ${w.and} `)),
    ...ordered.map(({ document, entry }) => `${w.name[document]}: ${entry.summary[lang] ?? entry.summary.en}\n${w.read[document].replace('{url}', `${SITE}${lang === 'en' ? '' : `/${lang}`}/${document}`)}`),
    ...(ordered.some((c) => c.document === 'terms') ? [w.applies.replace('{days}', String(APPLIES_AFTER_DAYS)).replace('{renews}', renews ? w.renews.replace('{day}', renews) : '')] : []),
    w.why,
  ];
  return { subject: w.subject[kind], text: text.join('\n\n') };
}

/// The object's side: [op]'s mail sent, where the relay binds EMAIL and
/// says who it is from (OH_MAIL_FROM). {status, body}.
export async function sendNotice(op, env) {
  if (typeof op.to !== 'string' || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(op.to) || typeof op.subject !== 'string' || typeof op.text !== 'string') {
    return { status: 400, body: { error: 'not a notice' } };
  }
  const from = env.OH_MAIL_FROM;
  if (!env.EMAIL || typeof from !== 'string' || !from.includes('@')) return { status: 503, body: { error: 'no mail here' } };
  try {
    await env.EMAIL.send({ to: op.to, from: { email: from, name: 'Open Hearts' }, subject: op.subject.slice(0, 200), text: op.text.slice(0, 8000) });
  } catch (e) {
    return { status: 502, body: { error: `not sent: ${e?.code ?? ''}` } };
  }
  return { status: 200, body: { sent: true } };
}

/// [mail] sent through the relay's object, where the project binds one:
/// whether it went.
async function viaRelay(env, mail) {
  if (!env.HOUSEHOLD) return false;
  try {
    const stub = env.HOUSEHOLD.get(env.HOUSEHOLD.idFromName(NOTICES_OBJECT));
    const answer = await stub.fetch('https://household/', { method: 'POST', body: JSON.stringify({ op: 'notice', ...mail }) });
    return (await answer.json())?.status === 200;
  } catch {
    return false;
  }
}

/// The subscription [id] as Stripe has it, with its customer: null for
/// none. Throws when Stripe does not say.
const subscriptionOf = (id, secret, fetchImpl) => askStripe(secret, `/subscriptions/${encodeURIComponent(id)}?expand[]=customer`, { missingIsNull: true, fetchImpl });

/// The changes a notice order names, each a document's newest change
/// with the earlier ones its summary says too ({document, version,
/// covers: [version]}), checked against [ledger], the one this deploy
/// published:
/// [{document, entry, covers, day}], [day] the day of the document's
/// newest entry, which its page says it was last updated; or null for
/// anything else.
function changesOf(ledger, changes) {
  if (!Array.isArray(changes) || !changes.length || changes.length > DOCUMENTS.length) return null;
  const out = [];
  for (const c of changes) {
    if (!DOCUMENTS.includes(c?.document) || out.some((o) => o.document === c.document)) return null;
    const entries = ledger?.[c.document] ?? [];
    const index = (version) => entries.indexOf(toldEntry(ledger, c.document, version));
    const at = index(c.version);
    const covers = c.covers ?? [];
    if (at < 0 || !Array.isArray(covers) || !covers.map(index).every((i) => i >= 0 && i < at)) return null;
    out.push({ document: c.document, entry: entries[at], covers, day: entries.at(-1).date });
  }
  return out;
}

/// A notice order carried out ([order], as the tool wrote it): each
/// subscription it names told by one email of each change it names that
/// it was not told of, once. {status, body}: how many were told, had
/// been told already, or could not be told and why; a subscription that
/// could not be told for want of an address or a subscription is noted,
/// so it is not asked about again, and one whose mail did not go is not,
/// so the next order tries it again. A change is noted as told under its
/// own version and under each earlier one it covers, which a subscription
/// already told of keeps the day it was told.
export async function carryOutNotice(order, store, env, { fetchImpl = fetch, send = (mail) => viaRelay(env, mail), now = Date.now() } = {}) {
  if (!(now - Date.parse(order.at) < ORDER_KEPT_S * 1000)) return { status: 410, body: { error: 'that order has run out' } };
  const changes = changesOf(env.OH_LEDGER, order.changes);
  if (!changes) return { status: 400, body: { error: 'no change subscribers are told of, by those documents and versions' } };
  const subs = order.subscriptions;
  if (!Array.isArray(subs) || !subs.length || subs.length > NOTICES_PER_ORDER || !subs.every((s) => typeof s === 'string' && /^sub_[A-Za-z0-9]{1,64}$/.test(s))) {
    return { status: 400, body: { error: `1 to ${NOTICES_PER_ORDER} web subscriptions` } };
  }
  const secret = env.OH_STRIPE_SECRET;
  if (!secret) return { status: 503, body: { error: 'service not configured: OH_STRIPE_SECRET' } };
  const said = { told: 0, already: 0, unsent: {}, failed: 0 };
  const note = async (id, told, row) => {
    for (const { document, entry, covers } of told) {
      await store.put(...noticeRow(document, versionOf(entry), id), { at: new Date(now).toISOString(), ...row });
      for (const version of covers) {
        if (!(await store.get(...noticeRow(document, version, id)))) await store.put(...noticeRow(document, version, id), { at: new Date(now).toISOString(), ...row, by: versionOf(entry) });
      }
    }
  };
  for (const id of subs) {
    const untold = [];
    for (const c of changes) if (!(await store.get(...noticeRow(c.document, versionOf(c.entry), id)))) untold.push(c);
    if (!untold.length) {
      said.already++;
      continue;
    }
    let sub;
    try {
      sub = await subscriptionOf(id, secret, fetchImpl);
    } catch {
      said.failed++;
      continue;
    }
    const email = sub?.customer?.email;
    const why = !sub ? 'no such subscription' : typeof email !== 'string' || !email.includes('@') ? 'no address' : null;
    if (why) {
      said.unsent[why] = (said.unsent[why] ?? 0) + 1;
      await note(id, untold, { unsent: why });
      continue;
    }
    const lang = languageOf(sub);
    const end = sub.items?.data?.[0]?.current_period_end;
    const renews = !sub.cancel_at_period_end && end ? applyingRenewal(end, sub.billing_cycle_anchor, now) : null;
    const mail = noticeMail(lang, untold, { renews });
    if (!(await send({ to: email, ...mail }))) {
      said.failed++;
      continue;
    }
    said.told++;
    await note(id, untold, { lang });
  }
  return { status: 200, body: { act: 'notice', changes: changes.map((c) => ({ document: c.document, version: versionOf(c.entry) })), ...said } };
}
