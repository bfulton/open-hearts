# 01 — The development loop

The constraint this repo is shaped around: **development is driven from a
phone.** Not "works on a phone" — driven from one. That rules out
anything whose feedback arrives in a terminal.

## What happens on every commit

```
./deploy.sh
```

1. Copies `site/` into `build/publish/`.
2. Generates `app/lib/build_info.g.dart` with the short commit sha,
   the date and the update check on, builds the Flutter web app with
   `--base-href /play/` into `build/publish/play/`, and restores the
   committed placeholder — the one whose sha is "dev" — whatever
   happens.
3. Writes `build/publish/play/build-info.json` stamped with the same
   sha.
4. Copies the deal benchmark to `build/publish/measure/shuffle/` when
   its wasm has been built ([measurements](../measurements/README.md)),
   so the number that matters comes from a phone.
5. Uploads the lot to Cloudflare Pages as a **branch deployment**.

Cloudflare gives every branch a stable alias host, so the URL does not
change between commits:

| | |
|---|---|
| Working branches | `https://dev.open-hearts.pages.dev/play` |
| `main` (production) | `https://open-hearts.pages.dev/play` — and the custom domain |

The label defaults to `dev` on any branch other than `main`. One short
host, bookmarkable, always the last push. Pass a label to override:
`./deploy.sh my-experiment` publishes to
`https://my-experiment.open-hearts.pages.dev`.

About 45 seconds end to end, most of it the Flutter build. Uploads are
content-addressed, so a redeploy typically re-uploads under ten files.

## Knowing which build you are looking at

A phone keeps a page alive for days. Without help, "did my change land?"
is a hard refresh and a guess. So:

- the running build's sha and date are on the About page, off the menu;
- the generated `build_info.g.dart` turns the check on, and only a
  deployed build has it. The app then fetches `build-info.json` at
  launch and on every return to the foreground, and shows a
  tap-to-reload pill when the published sha differs from its own;
- `_headers` marks the entry points `no-store` so a cached bootstrap
  cannot lie about this.

The build's identity has to be compiled in — a build cannot fetch its
own sha — so it is generated into a source file rather than passed as
a flag; and the check is a generated value rather than inferred from a
real-looking tag, since inferring it turns the pill on in CI, where it
floats over the widget tests and eats their taps.

A build stamped `abc1234+` was deployed from a dirty tree: it contains
work newer than the commit it names.

## With no network

None of the above may cost a phone the game when it has no signal.
Solo play needs nothing but the device, yet with every entry point
`no-store` and Flutter's own service worker now a stub that
unregisters itself, nothing kept the app: opened again in airplane
mode, a tab or a home-screen icon was the browser's "no internet"
page. So the page registers a service worker of its own,
`app/web/offline_worker.js`, once its first frame is up, and tells it
what that load fetched. It goes to the network first, always, and
keeps a copy of each file as it comes; only when the network fails
does it answer from the copy. Online nothing above changes — every
file is asked for afresh, a new deploy is what loads, and a cached
bootstrap still cannot lie about the build. Offline, the last build
that loaded is the one that opens. `build-info.json` is never kept,
so the pill says nothing rather than something stale, and nor are the
service's handlers. The registration is in `app/web/flutter_bootstrap.js`,
which also stops Flutter's loader registering its stub over it.

`node e2e/offline.mjs` holds all of this to account in a browser:
opened offline from what was kept and a hand played, and, with the
network, the relays or the site's worker taken away or left never
answering, every wait ending in words within a time it writes down.

## Credentials

`deploy.sh` needs `CLOUDFLARE_TOKEN` (Pages: Edit) and
`CLOUDFLARE_ACCOUNT_ID`. Nothing else, and no `wrangler.toml` — the
project name is in the script.
