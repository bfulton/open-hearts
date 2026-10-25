// The service's configuration that is not secret: config/openhearts.json,
// committed, reviewed and the same for every deployment. Secrets stay on
// the Pages project (docs/explanation/service.md).
//
// The handlers read their settings off env by their OH_ names, as the
// tests and the local rig hand them in, so the file is laid under env
// rather than read in each handler: a name set on the project or by a
// test still wins, except the price, which is the file's alone.
//
// A preview is a deployment of its own (docs/how-to/deploy.md): its
// environment says so (OH_DEPLOYMENT, on the Pages project's preview
// environment and the preview relay's), and it takes the file as a
// preview has it ([configFor]).

/// [config] as [deployment] runs it: production's as written; a
/// preview's with the service key previews have (preview.serviceKey),
/// and none at all while there is none. Never production's: a preview
/// runs whatever branch was deployed to it, so what it signs is good on
/// previews and nowhere else, and it takes nothing production signed.
export function configFor(config, deployment) {
  if (deployment !== 'preview') return config;
  const { preview, ...rest } = config ?? {};
  return { ...rest, serviceKey: preview?.serviceKey ?? null };
}

/// The file's fields as the env names the handlers read. A field left
/// null is left out, so a handler finds it missing, as before.
export function configEnv(config) {
  const { apple = {}, google = {}, alerts = {}, arachnid = {}, photodna = {}, ncmec = {} } = config ?? {};
  const on = (flag) => (flag === true ? 'on' : null);
  const named = {
    OH_SERVICE_KEY: config?.serviceKey,
    OH_TURN_KEY_ID: config?.turnKeyId,
    OH_STRIPE_PRICE: config?.stripePrice,
    OH_PRICE: priceOf(config),
    OH_APPLE_BUNDLE_ID: apple.bundleId,
    OH_APPLE_PRODUCT: apple.product,
    // Apple's token names the bundle on an iPhone and the Services ID
    // on the web; either is this app.
    OH_APPLE_AUDIENCE: [apple.servicesId, apple.bundleId].filter(Boolean).join(',') || null,
    OH_PLAY_PACKAGE: google.package,
    OH_PLAY_PRODUCT: google.product,
    OH_GOOGLE_AUDIENCE: google.webClientId,
    OH_PLAY_PUSH_AUDIENCE: google.playPushAudience,
    OH_PLAY_PUSH_EMAIL: google.playPushEmail,
    // The operator's own alerts (alerts.mjs).
    OH_ALERTS_TO: alerts.to,
    OH_ALERT_SUBSCRIBED: on(alerts.subscribed),
    OH_ALERT_WAITING: on(alerts.waiting),
    OH_ALERT_PICTURES: on(alerts.pictures),
    // Where the relay orders a termination (service/do/known.mjs).
    OH_APP_ORIGIN: config?.appOrigin,
    // Arachnid Shield's PDQ call, PhotoDNA's MatchHash call
    // (checkers.mjs), and NCMEC's reporting service and who its reports
    // name as reporting (known.mjs); the credentials are secrets.
    OH_ARACHNID_ENDPOINT: arachnid.endpoint,
    OH_PHOTODNA_ENDPOINT: photodna.endpoint,
    OH_NCMEC_ENDPOINT: ncmec.endpoint,
    OH_NCMEC_FIRST_NAME: ncmec.reporter?.firstName,
    OH_NCMEC_LAST_NAME: ncmec.reporter?.lastName,
    OH_NCMEC_EMAIL: ncmec.reporter?.email,
  };
  return Object.fromEntries(Object.entries(named).filter(([, v]) => typeof v === 'string' && v));
}

/// The price the terms state, as the checkout reads it (stripe.mjs,
/// statedPrice): "599 usd". Null for none.
const priceOf = (config) => {
  const { amount, currency } = config?.price ?? {};
  return Number.isInteger(amount) && typeof currency === 'string' ? `${amount} ${currency}` : null;
};

/// env with the file beneath it, as the deployment env names runs it
/// ([configFor]), but for the price, which is the file's alone: it is
/// what the terms state, and no setting on the project sells at another.
export function withConfig(env, config) {
  const laid = configEnv(configFor(config, env?.OH_DEPLOYMENT));
  const { OH_PRICE: _, ...rest } = env;
  return { ...laid, ...rest };
}

/// What a phone build is compiled with, out of the same file
/// (`--dart-define-from-file`, build_phone.sh): the service key it takes
/// a licence from, the sign-in providers' identifiers, and the store
/// products. The web build is given the first three by deploy.sh.
export function appDefines(config) {
  const { apple = {}, google = {} } = config ?? {};
  const named = {
    OH_SERVICE_KEY: config?.serviceKey,
    OH_APP_ORIGIN: config?.appOrigin,
    OH_APPLE_SERVICE_ID: apple.servicesId,
    OH_GOOGLE_CLIENT_ID: google.webClientId,
    OH_APPLE_PRODUCT: apple.product,
    OH_PLAY_PRODUCT: google.product,
  };
  return Object.fromEntries(Object.entries(named).filter(([, v]) => typeof v === 'string' && v));
}
