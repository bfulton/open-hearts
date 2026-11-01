# How a change reaches a phone

Any commit can be published and opened on a phone within a minute, and
the running build always says which commit it is. This page explains how
that works. The commands are in
[Deploy the site, app and service](../how-to/deploy.md) and the
[test suites reference](../reference/test-suites.md).

## Two tiers of checks

A change is checked at the tier its size calls for. `./check.sh quick`
runs only the suites the change can reach: the app tests whose imports
reach a changed file, and the fast tier of each changed package.
`./check.sh full` runs every suite, the browser suites too, side by side.
CI runs the same suites on every pull request and on `main`. A newer
push to a pull request cancels the run it supersedes, so CI's answer is
always about the latest commit. Why the suites are split this way is in
[How Open Hearts is tested](testing.md).

## One upload, routed by host

`deploy.sh` assembles the marketing site, the service's handlers and the
Flutter web build into one directory and uploads it to one Cloudflare
Pages project. Because they ship together, the site, the app and the
service are always the same commit. The worker routes each request by
its host ([where the app is](service.md#where-the-app-is)): in
production, `openhearts.game` serves the site, and
`play.openhearts.game` serves the app at its root with the handlers at
`/api/`. A preview has no play host, so it serves the same build at
`/play/`, and plays live on the preview relay with the people the
operator invites ([previews](service.md#previews)).

Every Pages branch gets a stable alias. A working branch publishes to
`dev`, so the latest push is always at the same address, and `main`
publishes to production. A production deploy refuses to run without the
service's public key, since a build without it has live play shut for
everyone ([the licence](service.md#licence)). Before uploading,
`deploy.sh` loads the staged worker, so a missing module fails on your
machine rather than at Cloudflare.

## Knowing which build is running

The build's identity is compiled in, as the defines `OH_BUILD_TAG` (the
short commit hash) and `OH_BUILD_DATE` (the UTC date) that
`app/lib/build_info.dart` reads. `deploy.sh` passes both to the web
build, with `OH_UPDATE_CHECK` to turn the update check on, and writes
`play/build-info.json` with the same hash. `build_phone.sh` and the
`ios` workflow get both from `app/tool/defines.mjs`. A build without
them, such as a local run, a test or CI, says `dev`.

- The About page shows the hash and the date.
- The remote config's `update` notice compares the date, so it reaches
  phone builds as well as the web. A phone build's date is the day it
  was built, before store review, not the day the store published it.
- A deployed web build fetches `build-info.json` at launch and whenever
  it returns to the foreground. If the published hash differs from its
  own, it shows a tap-to-reload pill. Local runs, tests and CI build
  without `OH_UPDATE_CHECK`, so the pill never appears there.
- `site/public/_headers` marks the entry points `no-store`, so a cached
  bootstrap cannot load an old build.
- A hash ending in `+` was deployed from a tree with uncommitted
  changes.

## Offline

Solo play needs only the device. The page registers its own service
worker, `app/web/offline_worker.js`, from `app/web/flutter_bootstrap.js`.
The worker fetches from the network first and keeps a copy of each file.
It falls back to the copy only when the network fails, so online
behaviour is unchanged and offline the last loaded build opens.
`build-info.json` and the service's handlers are never cached. At
`play.openhearts.game` the worker's scope is the whole host; at a
preview it is `/play/`. The `offline` browser suite checks this
([test suites](../reference/test-suites.md)).

## Why the wasm is committed

The deal's and the signatures' WebAssembly (`app/web/deal.wasm`,
`app/web/schnorr.wasm`) is committed, so building the web app needs no
Rust. Built with the Rust version CI pins, the wasm is the same bytes
from any checkout, and CI checks that what is committed is what its
sources build. A reviewer can therefore trust that the committed wasm is
the reviewed Rust.
