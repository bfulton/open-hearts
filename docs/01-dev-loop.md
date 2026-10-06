# 01 — The development loop

Any commit can be published and opened on a phone within a minute, and
the running build always says which commit it is.

## Publishing

```bash
./deploy.sh [label]          # needs CLOUDFLARE_TOKEN and CLOUDFLARE_ACCOUNT_ID
./deploy.sh --prune [keep]   # delete older preview deployments (-n: dry run)
```

`deploy.sh` assembles one directory and uploads it to the Cloudflare
Pages project `open-hearts`:

| Path | What |
|---|---|
| `/` | `site/`, built in each language by `site/build.mjs` |
| `/api/` | the service's handlers, `service/functions/` published as `_worker.js` ([doc 06](06-service.md)) |
| `/play/` | the Flutter web build, `--base-href /` |
| `/measure/shuffle/` | the deal benchmark, when its wasm has been built ([measurements](../measurements/README.md)) |

The worker routes by host ([doc 06](06-service.md#where-the-app-is)).
In production the site is `openhearts.game` and the app is the root of
`play.openhearts.game`, served from the build's `/play/` directory;
`openhearts.game/play/…` redirects there, path and query kept. A preview
has no play host, so it serves the same build at `/play/`, its worker
moving the page's base there.

The label names the Pages branch, and every branch gets a stable alias.
It defaults to `dev` on any working branch, so the latest push is always
at `https://dev.open-hearts.pages.dev/play/`, and to `main` (production,
`openhearts.game` and `play.openhearts.game`) on `main`. A production deploy refuses to run without
the service's public key (`serviceKey` in `config/openhearts.json`),
since a build without it has live play shut for everyone. Before uploading, the script loads the staged worker, so a
missing module fails locally instead of at Cloudflare.

## Knowing which build is running

The build's identity is compiled in. `deploy.sh` generates
`app/lib/build_info.g.dart` with the short sha, the date and the update
check turned on, and restores the committed placeholder afterwards. It
also writes `play/build-info.json` with the same sha.

- The About page shows the sha and date.
- A deployed build fetches `build-info.json` at launch and whenever it
  returns to the foreground. If the published sha differs from its own,
  it shows a tap-to-reload pill. Local runs, tests and CI keep the
  placeholder, so the pill never appears there.
- `site/public/_headers` marks the entry points `no-store`, so a cached
  bootstrap cannot load an old build.
- A sha ending in `+` was deployed from a dirty tree.

## Offline

Solo play needs only the device. The page registers its own service
worker, `app/web/offline_worker.js`, from `app/web/flutter_bootstrap.js`.
The worker fetches from the network first and keeps a copy of each file.
It falls back to the copy only when the network fails, so online
behaviour is unchanged and offline the last loaded build opens.
`build-info.json` and the service's handlers are never cached.
`node e2e/offline.mjs` checks this in a browser. At
`play.openhearts.game` the worker's scope is the whole host; at a
preview it is `/play/`.

## The move to play.openhearts.game

The app used to be at `openhearts.game/play/`, and a browser that played
there keeps its device — key, licence, name, records, settings — in that
origin's storage. On its first load at `play.openhearts.game` with no key,
`app/web/carry.js` asks a hidden frame of `openhearts.game/carry` for
those entries and writes them before the app starts, waiting 10 s at
most for that page and 2 s for its answer ([doc 06](06-service.md#the-device-carried-over)). The old origin
keeps its copy, so rolling back to serving the app at `/play/` loses
nobody. `node e2e/move.mjs` drives the redirect, the carry and a preview
in a browser, on the rig's stand-ins for the two hosts
(`openhearts.localhost` and `play.openhearts.localhost`).

## Credentials

The Cloudflare token needs Pages: Edit. The relay worker deploys
separately, from `service/do/wrangler.toml`.
