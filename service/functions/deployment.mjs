// The service's configuration that is not secret: config/openhearts.json,
// committed, reviewed and the same for every deployment. Secrets stay on
// the Pages project (docs/06-service.md).
//
// The handlers read their settings off env by their OH_ names, as the
// tests and the local rig hand them in, so the file is laid under env
// rather than read in each handler: a name set on the project or by a
// test still wins.

/// The file's fields as the env names the handlers read. A field left
/// null is left out, so a handler finds it missing, as before.
export function configEnv(config) {
  const { apple = {}, google = {} } = config ?? {};
  const named = {
    OH_SERVICE_KEY: config?.serviceKey,
    OH_TURN_KEY_ID: config?.turnKeyId,
    OH_STRIPE_PRICE: config?.stripePrice,
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
  };
  return Object.fromEntries(Object.entries(named).filter(([, v]) => typeof v === 'string' && v));
}

/// env with the file beneath it.
export const withConfig = (env, config) => ({ ...configEnv(config), ...env });
