// The operator told, by email, while there are few enough subscribers
// to hear about one at a time (config/openhearts.json, `alerts`): each
// subscription as it is bought, and each subscriber coming online,
// which is a device on a subscription asking for its licence, as the
// app does when it opens. Each is written down for a while under its
// subscription, so a webhook delivered twice, or an app opened twice in
// an hour, is told once.
//
// The mail goes from the relay worker, which holds the EMAIL binding (a
// Pages project cannot bind one), through an object of the Household
// class with a name of its own, so no household's queue waits on it.
// What it says is which store, a few characters of the subscription and
// the device, and dates: nobody's email or name.

/// The Household object the mail goes through.
export const ALERTS_OBJECT = 'operator-alerts';

/// Where alerts may go: the service's own domain, which forwards. The
/// object takes the address from its caller, and is no relay for mail
/// to anybody else.
const ours = (to) => typeof to === 'string' && /^[^@\s]+@openhearts\.game$/.test(to);

/// How long a subscription's subscribe alert is remembered: longer than
/// Stripe goes on redelivering a webhook.
const SUBSCRIBED_DAYS = 30;

/// What `alerts` in the config says, off env (deployment.mjs): null
/// when nobody is to be told.
export function alertsOf(env) {
  const to = env.OH_ALERTS_TO;
  if (!ours(to)) return null;
  const minutes = Number(env.OH_ALERT_QUIET_MINUTES);
  return {
    to,
    subscribed: env.OH_ALERT_SUBSCRIBED === 'on',
    online: env.OH_ALERT_ONLINE === 'on',
    quietMinutes: Number.isFinite(minutes) && minutes >= 1 ? minutes : 60,
    notOnline: (env.OH_ALERT_NOT_ONLINE ?? '').split(',').filter((h) => /^[0-9a-f]{16}$/.test(h)),
  };
}

const short = (s) => String(s ?? '').slice(0, 8);

/// How the config names a subscription without saying it, the repository
/// being public: the first 16 hex of the SHA-256 of its id.
export async function hashOf(subscription) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(subscription));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 16);
}

/// Sends [subject] and [text] to the alerts address, through the
/// relay's object where the project binds one. Never throws: an alert
/// is never why a licence or a webhook fails.
async function tell(env, alerts, subject, text) {
  try {
    if (!env.HOUSEHOLD) return false;
    const stub = env.HOUSEHOLD.get(env.HOUSEHOLD.idFromName(ALERTS_OBJECT));
    const answer = await stub.fetch('https://household/', {
      method: 'POST',
      body: JSON.stringify({ op: 'alert', to: alerts.to, subject, text }),
    });
    return (await answer.json())?.status === 200;
  } catch {
    return false;
  }
}

/// Whether [kind] for [subscription] is news: not told within [ttl]
/// seconds. Written as it is read, so the next ask in that time is not.
async function fresh(store, kind, subscription, ttl) {
  if ((await store.get(`ALERT#${kind}`, subscription)) !== null) return false;
  await store.put(`ALERT#${kind}`, subscription, { at: Date.now() }, { ttl });
  return true;
}

/// A subscription just bought, from [source] (stripe, apple, google).
export async function alertSubscribed(env, store, { subscription, source, key = null, now = Date.now() }) {
  const alerts = alertsOf(env);
  if (!alerts?.subscribed || !store || !subscription) return false;
  if (!(await fresh(store, 'subscribed', subscription, SUBSCRIBED_DAYS * 86400))) return false;
  const meta = await store.get(`SUB#${subscription}`, 'META');
  return tell(env, alerts, 'Open Hearts: a new subscription', [
    `A new ${source} subscription, ${short(subscription)}…, at ${new Date(now).toISOString()}.`,
    key ? `Bought on device ${short(key)}….` : null,
    meta?.renews_at ? `Paid up to ${meta.renews_at}.` : null,
    '',
    'To stop these, set alerts.subscribed to false in config/openhearts.json and deploy.',
  ].filter((l) => l !== null).join('\n'));
}

/// A device on [held]'s subscription asking for its licence: online,
/// told at most once in the configured quiet time per subscription, and
/// never for one the config's `notOnline` names.
export async function alertOnline(env, store, key, held, { now = Date.now() } = {}) {
  const alerts = alertsOf(env);
  if (!alerts?.online || !store || !held) return false;
  // A device's row names its account, whose subscription is the one
  // told of; a row from before accounts names the subscription itself.
  const account = typeof held.account === 'string' ? held.account : null;
  const subscription = account ? (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription : held.subscription;
  if (!subscription) return false;
  // The operator's own, and anyone else they would rather not hear of.
  if (alerts.notOnline.includes(await hashOf(subscription))) return false;
  if (!(await fresh(store, 'online', subscription, Math.max(60, Math.round(alerts.quietMinutes * 60))))) return false;
  const meta = await store.get(`SUB#${subscription}`, 'META');
  const devices = (await store.under(account ? `ACCOUNT#${account}` : `SUB#${subscription}`, 'DEVICE#')).length;
  return tell(env, alerts, 'Open Hearts: a subscriber is online', [
    `Device ${short(key)}… on subscription ${short(subscription)}… opened the app at ${new Date(now).toISOString()}.`,
    `${meta?.source ?? 'unknown'} subscription, ${devices} device${devices === 1 ? '' : 's'}, paid up to ${meta?.renews_at ?? held.licensed_until ?? 'unknown'}.`,
    '',
    `Told at most once in ${alerts.quietMinutes} minutes for a subscription. To stop these, set alerts.online to false in config/openhearts.json and deploy.`,
  ].join('\n'));
}

/// The object's side: the mail sent, where the relay binds EMAIL and
/// says who it is from (OH_MAIL_FROM). {status, body}.
export async function sendAlert(op, env) {
  if (!ours(op.to) || typeof op.subject !== 'string' || typeof op.text !== 'string') {
    return { status: 400, body: { error: 'not an alert' } };
  }
  const from = env.OH_MAIL_FROM;
  if (!env.EMAIL || typeof from !== 'string' || !from.includes('@')) return { status: 503, body: { error: 'no mail here' } };
  await env.EMAIL.send({ to: op.to, from: { email: from, name: 'Open Hearts' }, subject: op.subject.slice(0, 200), text: op.text.slice(0, 4000) });
  return { status: 200, body: { sent: true } };
}
