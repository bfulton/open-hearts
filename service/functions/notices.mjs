// Subscribers told of a change to the terms or the privacy policy that
// matters to them: a material or price change in the ledger
// (site/ledger.mjs). Every device shows it at the front door for
// [NOTICE_DAYS] from the day it is published (config.mjs, the app's
// OperatorNotes), and each web subscriber is emailed it when the
// operator says so: never by a deploy. A change to the terms applies to
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
// when, under the subscription (`NOTICE#<document>@<date>|SUB#<id>`), for
// as long as the subscription's record is kept.

import { SITE } from './settings.mjs';
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

/// Where a subscription's notice of [document]'s [date] is kept.
export const noticeRow = (document, date, subscription) => [`NOTICE#${document}@${date}`, `SUB#${subscription}`];

const LANGUAGES = ['en', 'es', 'pt', 'de', 'fr'];
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

/// What a device is shown at the front door on [now], from [ledger]:
/// each document's newest change subscribers are told of, for the
/// [NOTICE_DAYS] days from the day it was published — [{document, date,
/// summary}], the summary in each language.
export function noticesOf(ledger, now = Date.now()) {
  const before = new Date(now - NOTICE_DAYS * DAY_MS).toISOString().slice(0, 10);
  const today = new Date(now).toISOString().slice(0, 10);
  const out = [];
  for (const document of ['terms', 'privacy']) {
    const entry = (ledger?.[document] ?? []).filter(told).at(-1);
    if (entry && entry.date > before && entry.date <= today) out.push({ document, date: entry.date, summary: entry.summary });
  }
  return out;
}

/// The ledger's entry for [document] of [date], if it is one subscribers
/// are told of; null otherwise.
export function toldEntry(ledger, document, date) {
  const entry = (ledger?.[document] ?? []).find((e) => e.date === date);
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
    terms: ['Changes to the Open Hearts terms of use', 'We have changed the Open Hearts terms of use, on {day}.', 'Read them in full: {url}', 'They apply to your subscription from its first renewal at least {days} days from today, except where they say a change applies sooner.{renews} If you do not want to go on under them, you can cancel before then, in the game: menu, Subscription, Manage subscription.'],
    privacy: ['Changes to the Open Hearts privacy policy', 'We have changed the Open Hearts privacy policy, on {day}.', 'Read it in full: {url}', ''],
    renews: ' For yours, that is the renewal on {day}.',
    why: 'You are getting this email because you subscribe to Open Hearts on the web.',
  },
  es: {
    terms: ['Cambios en las condiciones de uso de Open Hearts', 'Hemos cambiado las condiciones de uso de Open Hearts el {day}.', 'Léelas completas: {url}', 'Se aplican a tu suscripción desde su primera renovación al menos {days} días a partir de hoy, salvo cuando digan que un cambio se aplica antes.{renews} Si no quieres continuar con ellas, puedes cancelar antes, en el juego: menú, Suscripción, Gestionar suscripción.'],
    privacy: ['Cambios en la política de privacidad de Open Hearts', 'Hemos cambiado la política de privacidad de Open Hearts el {day}.', 'Léela completa: {url}', ''],
    renews: ' Para la tuya, es la renovación del {day}.',
    why: 'Recibes este correo porque estás suscrito a Open Hearts en la web.',
  },
  pt: {
    terms: ['Mudanças nos termos de uso do Open Hearts', 'Mudamos os termos de uso do Open Hearts em {day}.', 'Leia-os na íntegra: {url}', 'Eles se aplicam à sua assinatura a partir da primeira renovação que ocorra pelo menos {days} dias depois de hoje, exceto quando disserem que uma mudança se aplica antes.{renews} Se não quiser continuar com eles, você pode cancelar antes disso, no jogo: menu, Assinatura, Gerenciar assinatura.'],
    privacy: ['Mudanças na política de privacidade do Open Hearts', 'Mudamos a política de privacidade do Open Hearts em {day}.', 'Leia-a na íntegra: {url}', ''],
    renews: ' Para a sua, é a renovação de {day}.',
    why: 'Você está recebendo este e-mail porque assina o Open Hearts na web.',
  },
  de: {
    terms: ['Änderungen der Nutzungsbedingungen von Open Hearts', 'Wir haben die Nutzungsbedingungen von Open Hearts am {day} geändert.', 'Hier liest du sie vollständig: {url}', 'Sie gelten für dein Abo ab seiner ersten Verlängerung, die mindestens {days} Tage nach heute liegt, außer wo sie sagen, dass eine Änderung früher gilt.{renews} Wenn du unter ihnen nicht weitermachen willst, kannst du vorher kündigen, im Spiel: Menü, Abo, Abo verwalten.'],
    privacy: ['Änderungen der Datenschutzerklärung von Open Hearts', 'Wir haben die Datenschutzerklärung von Open Hearts am {day} geändert.', 'Hier liest du sie vollständig: {url}', ''],
    renews: ' Bei deinem ist das die Verlängerung am {day}.',
    why: 'Du bekommst diese E-Mail, weil du Open Hearts im Web abonniert hast.',
  },
  fr: {
    terms: ["Modifications des conditions d'utilisation d'Open Hearts", "Nous avons modifié les conditions d'utilisation d'Open Hearts le {day}.", 'Lisez-les en entier : {url}', "Elles s'appliquent à votre abonnement à partir de son premier renouvellement intervenant au moins {days} jours après aujourd'hui, sauf lorsqu'elles indiquent qu'un changement s'applique plus tôt.{renews} Si vous ne souhaitez pas continuer dans ces conditions, vous pouvez résilier avant, dans le jeu : menu, Abonnement, Gérer l'abonnement."],
    privacy: ["Modifications de la politique de confidentialité d'Open Hearts", "Nous avons modifié la politique de confidentialité d'Open Hearts le {day}.", 'Lisez-la en entier : {url}', ''],
    renews: " Pour le vôtre, c'est le renouvellement du {day}.",
    why: 'Vous recevez cet e-mail parce que vous êtes abonné à Open Hearts sur le web.',
  },
};

/// The words of [document]'s notice of [entry], in [lang], to a
/// subscription whose change applies at its renewal on [renews]
/// (YYYY-MM-DD, or null for one that does not renew): {subject, text}.
/// Days are written YYYY-MM-DD, which reads the same in every language.
export function noticeMail(lang, document, entry, { renews = null } = {}) {
  const w = WORDS[lang] ?? WORDS.en;
  const [subject, opening, read, applies] = w[document];
  const url = `${SITE}${lang === 'en' ? '' : `/${lang}`}/${document}`;
  const text = [
    opening.replace('{day}', entry.date),
    entry.summary[lang] ?? entry.summary.en,
    read.replace('{url}', url),
    applies.replace('{days}', String(APPLIES_AFTER_DAYS)).replace('{renews}', renews ? w.renews.replace('{day}', renews) : ''),
    w.why,
  ].filter(Boolean);
  return { subject, text: text.join('\n\n') };
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
async function subscriptionOf(id, secret, fetchImpl) {
  const res = await fetchImpl(`https://api.stripe.com/v1/subscriptions/${encodeURIComponent(id)}?expand[]=customer`, {
    headers: { authorization: `Bearer ${secret}` },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`stripe said ${res.status}`);
  return res.json();
}

/// A notice order carried out ([order], as the tool wrote it): each
/// subscription it names told by email, once. {status, body}: how many
/// were told, had been told already, or could not be told and why; a
/// subscription that could not be told for want of an address or a
/// subscription is noted, so it is not asked about again, and one whose
/// mail did not go is not, so the next order tries it again.
export async function carryOutNotice(order, store, env, { fetchImpl = fetch, send = (mail) => viaRelay(env, mail), now = Date.now() } = {}) {
  if (!(now - Date.parse(order.at) < ORDER_KEPT_S * 1000)) return { status: 410, body: { error: 'that order has run out' } };
  const entry = toldEntry(env.OH_LEDGER, order.document, order.date);
  if (!entry) return { status: 400, body: { error: 'no change subscribers are told of, by that document and day' } };
  const subs = order.subscriptions;
  if (!Array.isArray(subs) || !subs.length || subs.length > NOTICES_PER_ORDER || !subs.every((s) => typeof s === 'string' && /^sub_[A-Za-z0-9]{1,64}$/.test(s))) {
    return { status: 400, body: { error: `1 to ${NOTICES_PER_ORDER} web subscriptions` } };
  }
  const secret = env.OH_STRIPE_SECRET;
  if (!secret) return { status: 503, body: { error: 'service not configured: OH_STRIPE_SECRET' } };
  const said = { told: 0, already: 0, unsent: {}, failed: 0 };
  const note = async (id, row) => store.put(...noticeRow(order.document, order.date, id), { at: new Date(now).toISOString(), ...row });
  for (const id of subs) {
    if (await store.get(...noticeRow(order.document, order.date, id))) {
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
      await note(id, { unsent: why });
      continue;
    }
    const lang = languageOf(sub);
    const end = sub.items?.data?.[0]?.current_period_end;
    const renews = !sub.cancel_at_period_end && end ? applyingRenewal(end, sub.billing_cycle_anchor, now) : null;
    const mail = noticeMail(lang, order.document, entry, { renews });
    if (!(await send({ to: email, ...mail }))) {
      said.failed++;
      continue;
    }
    said.told++;
    await note(id, { lang });
  }
  return { status: 200, body: { act: 'notice', document: order.document, date: order.date, ...said } };
}
