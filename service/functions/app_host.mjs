// Where the app is: its host, and the static assets served under it.
//
// One Pages project, one deployment, routed by host (docs/explanation/service.md,
// "Where the app is"). The build's /play/ directory is the app:
//
//   play.openhearts.game   the app at the root: /room/ABCD is the build's
//                          /play/ index, /main.dart.js its /play/main.dart.js
//   openhearts.game        the site, and nothing of the app: /play/… is not
//                          found, and /carry is the one page the app may
//                          frame
//   anything else          a preview (dev.open-hearts.pages.dev): the site
//                          at the root and the app at /play/, as before,
//                          with the app's base moved there and the site's
//                          links to the app pointed at it
//
// /api/ is the handlers on the app's host and on a preview, and not on
// the site's: the app calls its own origin's, and so does everything
// else that calls the service — Stripe, the stores, the monitors.

/// The app's own host.
export const APP_HOST = 'play.openhearts.game';

/// For a host the site is served at, the host its app is served at —
/// production's, and the browser rig's stand-in for it (e2e/drive.mjs)
/// — or null where the app is served beside the site, at /play/.
export function appHostFor(host) {
  if (host === 'openhearts.game') return APP_HOST;
  if (host === 'openhearts.localhost') return 'play.openhearts.localhost';
  return null;
}

/// Whether [host] serves the app at its root.
export const isAppHost = (host) => host === APP_HOST || host === 'play.openhearts.localhost';

/// Whether [path], as the app has it, is a page of the app rather than
/// one of its files: an address with no extension, `/subscription` or
/// `/room/ABCD` (app/lib/router.dart), or the front door. Each is
/// answered with the app, which reads the address and opens the page.
/// Decided by the path, not by a file being missing: the site has no
/// 404 page, so a missing file comes back as the site's front page
/// rather than as missing.
export function appPage(path) {
  const last = path.slice(path.lastIndexOf('/') + 1);
  return !last.includes('.');
}

/// The build's base, as Flutter writes it into the page: `/`, for the
/// app at the root of its host.
const ROOT_BASE = '<base href="/">';

/// [response] with [text] for its body: its status and headers, less
/// those that described the old body.
function withBody(response, text) {
  const headers = new Headers(response.headers);
  for (const h of ['content-length', 'content-encoding', 'etag']) headers.delete(h);
  return new Response(text, { status: response.status, statusText: response.statusText, headers });
}

/// The app's page as a preview serves it, at /play/: the same build,
/// its base moved there, so its files and its pages' addresses are
/// found under /play/.
async function underPlay(response) {
  if (response.status !== 200 || !(response.headers.get('content-type') ?? '').includes('text/html')) return response;
  const page = await response.text();
  return withBody(response, page.replace(ROOT_BASE, '<base href="/play/">'));
}

/// The site's page as a preview or the rig serves it: its links to the
/// app point at that host's app, not production's.
async function linkedTo(response, app) {
  if (response.status !== 200 || !(response.headers.get('content-type') ?? '').includes('text/html')) return response;
  const page = await response.text();
  return withBody(response, page.replaceAll(`https://${APP_HOST}/`, app));
}

const notFound = () => new Response('not found\n', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });

/// /carry, the page that hands the device's storage on to the app at its
/// own host (site/public/carry.html, app/web/carry.js): framed by that
/// host and nothing else, where every other page is framed by nobody.
function framedBy(response, origin) {
  const headers = new Headers(response.headers);
  headers.delete('x-frame-options');
  headers.set('content-security-policy', `frame-ancestors ${origin}`);
  headers.set('cache-control', 'no-store');
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

/// Everything that is not /api/: the site, and the app.
export async function serveStatic(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const port = url.port ? `:${url.port}` : '';
  if (isAppHost(url.hostname)) {
    const asset = appPage(path) ? '/play/' : `/play${path}`;
    return env.ASSETS.fetch(new Request(new URL(asset + url.search, url), request));
  }
  const appHost = appHostFor(url.hostname);
  if (appHost) {
    // The build's /play/ is the app's host's to serve: from here it would
    // be the app at another origin, with no device in it.
    if (path === '/play' || path.startsWith('/play/')) return notFound();
    const app = `${url.protocol}//${appHost}${port}`;
    const response = await env.ASSETS.fetch(request);
    if (path === '/carry' || path === '/carry.html') return framedBy(response, app);
    return appHost === APP_HOST ? response : linkedTo(response, `${app}/`);
  }
  // A preview.
  if (path.startsWith('/play/')) {
    const inApp = path.slice('/play'.length);
    return underPlay(await env.ASSETS.fetch(appPage(inApp) ? new Request(new URL(`/play/${url.search}`, url), request) : request));
  }
  return linkedTo(await env.ASSETS.fetch(request), `${url.origin}/play/`);
}
