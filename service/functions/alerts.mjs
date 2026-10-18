// The operator told, by email, while there are few enough subscribers
// to hear about one at a time (config/openhearts.json, `alerts`): each
// subscription as it is bought, and each subscriber who, finding the
// pool empty, chose to wait for a person rather than play bots — so
// that someone can come and play. (And, once a day, the new pictures
// subscribers put out, `pictures`, which the relay worker sends itself:
// service/do/review.mjs.) Each is written down for a while
// under its subscription, so a webhook delivered twice, or a wait
// chosen twice in a few minutes, is told once.
//
// The mail goes from the relay worker, which holds the EMAIL binding (a
// Pages project cannot bind one), through an object of the Household
// class with a name of its own, so no household's queue waits on it.
// What it says is which store or pool, a few characters of the
// subscription and the device, and dates: nobody's email or name.

/// The Household object the mail goes through.
export const ALERTS_OBJECT = 'operator-alerts';

/// Where alerts may go: the service's own domain, which forwards. The
/// object takes the address from its caller, and is no relay for mail
/// to anybody else.
const ours = (to) => typeof to === 'string' && /^[^@\s]+@openhearts\.game$/.test(to);

/// How long a subscription's subscribe alert is remembered: longer than
/// Stripe goes on redelivering a webhook.
const SUBSCRIBED_DAYS = 30;

/// How long a subscriber's wait is remembered: a person waits five
/// minutes at most, and one who goes back to waiting has been told of.
const WAITING_MINUTES = 10;

/// What `alerts` in the config says, off env (deployment.mjs): null
/// when nobody is to be told.
export function alertsOf(env) {
  const to = env.OH_ALERTS_TO;
  if (!ours(to)) return null;
  return { to, subscribed: env.OH_ALERT_SUBSCRIBED === 'on', waiting: env.OH_ALERT_WAITING === 'on', pictures: env.OH_ALERT_PICTURES === 'on' };
}

const short = (s) => String(s ?? '').slice(0, 8);

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

/// A subscriber's device [key], on [account], waiting for a person in
/// [pool] for a game to [target]: told at most once in a few minutes a
/// subscription.
export async function alertWaiting(env, store, { key, account, pool, target, now = Date.now() }) {
  const alerts = alertsOf(env);
  if (!alerts?.waiting || !store || !account) return false;
  const subscription = (await store.get(`ACCOUNT#${account}`, 'META'))?.subscription;
  if (!subscription) return false;
  if (!(await fresh(store, 'waiting', subscription, WAITING_MINUTES * 60))) return false;
  return tell(env, alerts, 'Open Hearts: someone is waiting for a person', [
    `Device ${short(key)}… on subscription ${short(subscription)}… is waiting in the ${pool} pool for a game to ${target}, since ${new Date(now).toISOString()}.`,
    'They wait five minutes at most, and then play bots.',
    '',
    'To stop these, set alerts.waiting to false in config/openhearts.json and deploy.',
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
