# Command-line tools

This page lists every command-line tool in the repository, with what it does and its main flags, as each tool's usage header in its own file states them.

The browser suites and `check.sh` are in [check.sh suites, tiers and CI jobs](test-suites.md).

## Engine tools

Run each from `packages/engine` as `dart run tool/<name>.dart`. Flags take `--name value` or `--name=value` (`packages/engine/lib/args.dart`). Each flag's default is in its tool's file.

| File | What it does | Main flags |
|---|---|---|
| `packages/engine/tool/arena.dart` | Plays the persona roster against each other and prints each persona's seats, win share and mean score. | `--games <n>`; `--roster "<name>,<name>,…"` seats a chosen field. |
| `packages/engine/tool/blunders.dart` | Looks for self-destructive plays in bot-versus-bot games, judged with hindsight, and counts them by persona and kind. | `--tables <n>`; `--show <n>` prints that many whole tricks to look at. |
| `packages/engine/tool/bot_stats.dart` | Plays the bot against itself and reports wins by seat, which should be flat, and moons shot. | `--games <n>`; `--persona <name>` seats four of one persona. |
| `packages/engine/tool/knobs.dart` | Seats a bot that differs from Westley by one setting against three Westleys, and reports what that setting is worth. | `--games <n>` |
| `packages/engine/tool/replay.dart` | Replays a solo game record, the line the app's Copy button makes (`oh2:…` or `oh1:…`), and prints every trick. | The record, as the only argument. |

## Table tools

Run each from `packages/table` as `dart run tool/<name>.dart`. The flags work as for the engine tools.

| File | What it does | Main flags |
|---|---|---|
| `packages/table/tool/chaos.dart` | Walks random faults through simulated tables over many seeds, on the simulator's referee, optionally with the verifiable deal run for real. Prints every broken invariant with the faults that led there, and exits non-zero if there was one. | `--seeds <n>`; `--sealed <n>` also walks the first `n` seeds sealed; `--sealed-only <a,b,…>` walks just those sealed seeds; `--workers` makes the deal's slow calls in a worker with a browser's timing; `--traces` prints every side's trace; `--tally` counts how games ended, how seats were given up and the faults thrown. |
| `packages/table/tool/explore.dart` | Runs a short sealed game once for each event it sends, with that one event dropped, late or sent twice, to find ordering faults that random walks miss. | `--scenario <name>`: `deal`, `four`, `leave`, `pass`, `reload` or `house` (each says what it plays when the name is wrong); `--changes drop,late,twice`; `--hold <ms>` how late a late event is; `--shard <i>/<n>`; `--limit <n>`; `--first` stops at the first failure; `--census` lists the events the scenario sends and stops; `--at <n>` runs the one change to event `n`, with every side's trace. |
| `packages/table/tool/ladder.dart` | Calibrates the bots' strength ladder: every persona at every level, rated from pairwise results. Prints each level's mean and the `priors` line for `packages/engine/lib/src/persona.dart`. | `--tables <n>` |
| `packages/table/tool/game_fixture.dart` | Writes a finished sealed game's record to standard output, as it is kept: four people at a refereed table, the rig's house, real keys and licences. For the browser suite's look at a kept game, and the kept-game fixture `packages/table/test/fixtures/refereed_four.json.gz`. | None; redirect the output, such as `> game.json`. |

## Service tools

Run the Dart tools from `service` as `dart run bin/<name>.dart` or `dart run tool/<name>.dart`, and the Node tools from the repository's root.

| File | What it does | Main flags |
|---|---|---|
| `service/bin/house.dart` | Runs the house: woken for a table (`POST /wake?table=…`), it follows the table's log from the start, deals and plays its bot seats, holds half of each person's escrow and says it when that person goes, and says how the game came out, in the log and on the results tag. Woken for a pool (`POST /wake?pool=…`), it seats the pool a round at a time, with bots chosen by the ratings it folds from the results tag, until nobody has waited there for a minute. A wake's JSON body, `{"timing": …}`, says the operator's clocks for the tables it seats; a wake without one leaves them as they were. Reads `OH_HOUSE_SECRET`, and `OH_HOUSE_KEY` and `OH_SERVICE_KEY` where set; a secret that is not `OH_HOUSE_KEY`'s does not start. Ends on SIGTERM. | `--relay <url,…>`, with `{tag}` where the table's tag goes; `--port <n>` answers `GET /ping`, `GET /status` and `POST /wake?table=…` or `?pool=…`; `--pace <0..1>` the share of each bot's thinking time it takes before it says the bot's card (1, the default; the browser suites pass their app's pace), never longer than the quickest person at the table takes over a card |
| `service/bin/service_key.dart` | Mints a signing pair and prints it as one line of JSON, for `./oh key mint`, `./oh house key` and `./oh preview secrets`, which set its secret without showing it. | None |
| `service/tool/forget.mjs` | Not run by itself: forgets an account (`forget`), for `./oh account delete`. Marks it forgotten in `OH_RECORDS` (`forgottenKey`), takes its name off its kept games (`anonymizeGames`) and deletes every row the service keeps for it (`forgetAccount`). | Not applicable |
| `service/tool/suspend.mjs` | Not run by itself: how an account stands (`standing`), what an act would do (`wouldDo`), and an order carried out in the account's turn (`carry`), for `./oh account`. | Not applicable |
| `service/tool/find.mjs` | Not run by itself: finds accounts by name or email (`findAccounts`), or by a device's key (`accountOf`), for `./oh account`. | Not applicable |
| `service/tool/kv.mjs` | Not run by itself: `OH_STORE` through Cloudflare's API, behind the same calls as the worker's store, for `./oh`. | Not applicable |
| `service/tool/r2.mjs` | Not run by itself: `OH_RECORDS` through Cloudflare's API, for `./oh account`. | Not applicable |
| `service/tool/house_check.dart` | Times the house, wherever it was started (in its image, limited to the Cloudflare instance it runs on, say), against a real table: a relay here, two people here, two bot seats. The relay wakes the house on its port as the deployed object does. Reads `OH_HOUSE_SECRET`. | `--port <n>` the relay's; `--hands <n>`; `--house <url>` where the house answers (`http://127.0.0.1:8080`, the image's port, by default). |
| `service/tool/wire_over_socket.dart` | Counts the bytes a sealed hand puts on a real socket to the relay, each way, and what the log is made of, entry by entry: two people and two bots, the house in the same process. | An optional first argument: how long each decision takes, in milliseconds. |
| `service/do/host.mjs` | Hosts the relay that the Cloudflare object runs on a plain Node socket, one relay per path, each table's tag refereeing its log. | `--port <n>`; `--object` holds each tag to the object's own rules; `--gate <service key>` asks every socket who it is; `--house <key>` is the house it carries on its key alone and referees sealed tables for, saying `{"wanted": <table>}` on stdout when a table wants it; `--keep <n>`; `--stats <path>`; `--control`; `--quiet` |

## Build and deploy scripts

| File | What it does | Main flags |
|---|---|---|
| `deploy.sh` | Builds the site, the app and the handlers, and uploads them to the Pages project as one deployment. Run by `./oh deploy site`, which deletes old deployments before a production deploy (as `./oh deploy prune` does). Refuses production without `serviceKey` and `houseKey` in `config/openhearts.json`, or when `ops/gate.mjs` finds anything in the way. A preview's app is built with the previews' keys (`preview.serviceKey`, `preview.houseKey`) and the preview relay. Needs `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. | `[label]`: the Pages branch, which defaults to `main` on `main` and `dev` elsewhere. |
| `build_phone.sh` | Builds the native libraries, then a store release compiled with what `config/openhearts.json` names. Run by `./oh phone`. Refuses when `ops/gate.mjs` finds anything in the way: a store release is built from `main` as it was reviewed. | `ios` or `android`; further arguments go to `flutter build`. |
| `crypto/deal/build.sh` | Builds the deal library for the Dart VM, and the wasm, copied to `app/web/deal.wasm`. | None |
| `crypto/schnorr/build.sh` | Builds the Schnorr library for the Dart VM. | None |
| `crypto/schnorr_wasm/build.sh` | Builds BIP-340 for the browser and the relay, copies it to `app/web/schnorr.wasm`, and checks it against BIP-340's test vectors. | None |
| `crypto/wasm.sh` | Not run by itself: sourced by the two wasm builds. Its `wasm_build` builds the same bytes on any machine. | Not applicable |
| `crypto/build_android.sh` | Builds the deal and Schnorr libraries for Android's ABIs, into the app's `jniLibs`. Needs the Android NDK and the Rust targets. | None |
| `crypto/build_ios.sh` | Builds the deal and Schnorr libraries as XCFrameworks, into `app/ios/Frameworks`. Needs a Mac with Xcode and the Rust targets. | None |
| `site/build.mjs` | Builds the site into a directory, once in each language, with the sitemap that lists it. `deploy.sh` runs it. | `<out>` |
| `app/worker/build.sh` | Compiles the review worker beside a built app. `deploy.sh` and `e2e/build.sh` run it. | `<build directory>` |
| `service/bench/build.sh` | Builds the house's container image. The relay's `wrangler deploy` runs it. | None |
| `ops/wrangler/wrangler` | Runs Wrangler at the version `ops/wrangler/package.json` names, with its whole dependency tree as `package-lock.json` locks it, installed beside it with `npm ci` the first time and whenever the lockfile changes. `deploy.sh` and `./oh` run Wrangler through it. | Wrangler's own |

## Accounts and monitoring

| File | What it does | Main flags |
|---|---|---|
| `infra/apply.mjs` | Compares the Cloudflare and Stripe accounts with `infra/cloudflare.mjs` and `infra/stripe.mjs`, and with `--apply` makes them match. Each line is `would …`, `by hand:`, `unread:` or `ok`. | `--apply`; `--only cloudflare` or `--only stripe` |
| `observability/apply.mjs` | Compares the New Relic account with `observability/monitoring.mjs`, and with `--apply` makes it match. Also writes the browser agent's loader to `app/web/observability.js`. | `--apply` |

For the environment variables both read, see [Environment variables](configuration.md#environment-variables).

## App tools

| File | What it does | Main flags |
|---|---|---|
| `app/tool/affected_tests.mjs` | Prints the app's test files whose imports reach a changed file, or `all`. `./check.sh quick` runs it. | The changed paths, from the repository's root. |
| `app/tool/defines.mjs` | Writes the phone build's `--dart-define-from-file` from `config/openhearts.json` (`appDefines`), with the build's commit and date (`OH_BUILD_TAG`, `OH_BUILD_DATE`). Refuses a file with no `serviceKey`, `houseKey` or `appOrigin`. `build_phone.sh` and the `ios` workflow run it. | `<out.json>` |
| `app/tool/icons.mjs` | Draws every icon and launch image the app and the site ship from `app/tool/icon.svg`. Run it from `app`. | None |

## Docs tools

| File | What it does | Main flags |
|---|---|---|
| `docs/links.mjs` | Checks every Markdown file's relative links, anchors and repository paths in code, and every tracked file's mentions of a doc. Prints each stale reference and exits non-zero if there is one. `./check.sh docs` runs it. | None |
