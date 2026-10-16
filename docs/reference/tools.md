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
| `packages/table/tool/chaos.dart` | Walks random faults through simulated tables over many seeds, optionally with the verifiable deal run for real. Prints every broken invariant with the faults that led there, and exits non-zero if there was one. | `--seeds <n>`; `--sealed <n>` also walks the first `n` seeds sealed; `--sealed-only <a,b,…>` walks just those sealed seeds; `--structure` reads every side against the state machines; `--jurors <n>` with `--sweep` draws from more strangers than a jury; `--workers` makes the deal's slow calls in a worker with a browser's timing; `--twins` takes accounts up on second devices. |
| `packages/table/tool/explore.dart` | Runs a short sealed game once per event, peer and change (a copy lost, or late), to find ordering faults that random walks miss. | `--scenario <name>` (one of `scenarios` in the file); `--changes lose,late`; `--hold <ms,…>` how late a late copy is; `--fault-at <ms,…>` when the scenario's own fault comes; `--shard <i>/<n>`; `--limit <n>`; `--first` stops at the first failure; `--whole` plays the hand out and checks the whole record; `--structure`; `--census` counts the events by kind and stops; `--at <n>` or `--match <text>` replays one run with every client's trace. |
| `packages/table/tool/walk.dart` | Walks one chaos seed with every client's trace printed. | `--seed <n>`; `--seeded` uses the seeded deal rather than the sealed one. |
| `packages/table/tool/ladder.dart` | Calibrates the bots' strength ladder: every persona at every level, rated from pairwise results. Prints each level's mean and the `priors` line for `packages/engine/lib/src/persona.dart`. | `--tables <n>` |
| `packages/table/tool/time_to_deal.dart` | Measures how long a sealed hand takes to deal, and what the jury's own waits cost in it, on the simulator's virtual clock. | `--seeds <n>`; `--jury <n>` |
| `packages/table/tool/jury_size.dart` | Works out how big a jury has to be, across a range of juror failure rates. | `--target <p>`, the most hands that may fail to go on; `--juror-p50 <seconds>`, a juror's median time online. |
| `packages/table/tool/wire_in_sim.dart` | Counts a hand's bytes on the wire on the simulator, where the count is exact: two people and two bot seats the jury holds. | `--jury <n,…>` jury sizes; `--seeds <n>` hands to average; `--away` takes a seat offline and back; `--slow` gives the network a relay's latency; `--quiet` takes a bot seat's juror offline. |
| `packages/table/tool/wire_breakdown.dart` | Shows where a hand's bytes go, by event, round and field, and what they would be compressed. | None |
| `packages/table/tool/juror_wire.dart` | Shows what a juror holding bot seats says in a hand, in bytes, as JSON for a relay and as a frame for a channel. | None |
| `packages/table/tool/game_fixture.dart` | Writes a finished sealed game's record to standard output, for the browser suite's look at a kept game. | None; redirect the output, such as `> game.json`. |
| `packages/table/tool/kept_records.dart` | Writes the kept-game fixtures in `packages/table/test/fixtures/` with the deal library of their day, for the test that later libraries still read them. The fixtures are not to be written again. | An optional path to a `libdeal` library. |

## Service tools

Run the Dart tools from `service` as `dart run bin/<name>.dart` or `dart run tool/<name>.dart`, and the Node tools from the repository's root.

| File | What it does | Main flags |
|---|---|---|
| `service/bin/service.dart` | Runs the local relay, and optionally a juror in the same process. With `OH_RELAY=js`, runs the relay the Cloudflare object runs. | `--port <n>` (`0` for any free port); `--quiet`; `--juror` |
| `service/bin/juror.dart` | Runs the backup jurors: quiet on the relay until a table calls for jurors, then online to serve it. Reads `OH_JUROR_SECRET` and `OH_SERVICE_KEY`. Ends on SIGTERM. | `--relay <url,…>` where the jurors follow tables; `--presence <url,…>` where they announce themselves and hear calls; `--jurors <n>`; `--port <n>` answers `GET /ping`, `GET /status` and `POST /wake?table=…` |
| `service/bin/service_key.dart` | Mints the service's signing pair, and prints both halves once. Run by `./oh key mint`. | None |
| `service/tool/forget.mjs` | Not run by itself: forgets an account (`forget`), for `./oh account delete`. Marks it forgotten in `OH_RECORDS` (`forgottenKey`), takes its name off its kept games (`anonymizeGames`) and deletes every row the service keeps for it (`forgetAccount`). | Not applicable |
| `service/tool/suspend.mjs` | Not run by itself: how an account stands (`standing`), what an act would do (`wouldDo`), and an order carried out in the account's turn (`carry`), for `./oh account`. | Not applicable |
| `service/tool/find.mjs` | Not run by itself: finds accounts by name or email (`findAccounts`), or by a device's key (`accountOf`), for `./oh account`. | Not applicable |
| `service/tool/kv.mjs` | Not run by itself: `OH_STORE` through Cloudflare's API, behind the same calls as the worker's store, for `./oh`. | Not applicable |
| `service/tool/r2.mjs` | Not run by itself: `OH_RECORDS` through Cloudflare's API, for `./oh account`. | Not applicable |
| `service/tool/bench_check.dart` | Times the backup jurors, wherever they were started, against a real table: a relay here, two people here, two bot seats. | `--port <n>`; `--hands <n>`; `--relay <url>` uses a relay that is already running. |
| `service/tool/wire_over_socket.dart` | Counts the bytes a sealed hand puts on a real socket, with the relay's compression on and off. | An optional first argument: how long each decision takes, in milliseconds. |
| `service/do/host.mjs` | Hosts the relay that the Cloudflare object runs on a plain Node socket, one relay per path. | `--port <n>`; `--object` holds each tag to the object's own rules; `--gate <service key>` asks every socket who it is; `--keep <n>`; `--stats <path>`; `--control`; `--quiet` |

## Build and deploy scripts

| File | What it does | Main flags |
|---|---|---|
| `deploy.sh` | Builds the site, the app and the handlers, and uploads them to the Pages project as one deployment. Run by `./oh deploy site` and `./oh deploy prune`. Refuses production without `serviceKey` in `config/openhearts.json`, or when `ops/gate.mjs` finds anything in the way. Needs `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. | `[label]`: the Pages branch, which defaults to `main` on `main` and `dev` elsewhere; `--prune [keep]` deletes older previews; `--prune -n` lists them only. |
| `build_phone.sh` | Builds the native libraries, then a store release compiled with what `config/openhearts.json` names. Run by `./oh phone`. | `ios` or `android`; further arguments go to `flutter build`. |
| `crypto/deal/build.sh` | Builds the deal library for the Dart VM, and the wasm, copied to `app/web/deal.wasm`. | None |
| `crypto/schnorr/build.sh` | Builds the Schnorr library for the Dart VM. | None |
| `crypto/schnorr_wasm/build.sh` | Builds BIP-340 for the browser and the relay, copies it to `app/web/schnorr.wasm`, and checks it against BIP-340's test vectors. | None |
| `crypto/wasm.sh` | Not run by itself: sourced by the two wasm builds. Its `wasm_build` builds the same bytes on any machine. | Not applicable |
| `crypto/build_android.sh` | Builds the deal and Schnorr libraries for Android's ABIs, into the app's `jniLibs`. Needs the Android NDK and the Rust targets. | None |
| `crypto/build_ios.sh` | Builds the deal and Schnorr libraries as XCFrameworks, into `app/ios/Frameworks`. Needs a Mac with Xcode and the Rust targets. | None |
| `site/build.mjs` | Builds the site into a directory, once in each language. `deploy.sh` runs it. | `<out>` |
| `app/worker/build.sh` | Compiles the review worker beside a built app. `deploy.sh` and `e2e/build.sh` run it. | `<build directory>` |
| `service/bench/build.sh` | Builds the backup jurors' container image. The relay's `wrangler deploy` runs it. | None |

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
| `app/tool/defines.mjs` | Writes the phone build's `--dart-define-from-file` from `config/openhearts.json` (`appDefines`). Refuses a file with no `serviceKey` or `appOrigin`. `build_phone.sh` runs it. | `<out.json>` |
| `app/tool/icons.mjs` | Draws every icon and launch image the app and the site ship from `app/tool/icon.svg`. Run it from `app`. | None |

## Docs tools

| File | What it does | Main flags |
|---|---|---|
| `docs/links.mjs` | Checks every Markdown file's relative links, anchors and repository paths in code, and every tracked file's mentions of a doc. Prints each stale reference and exits non-zero if there is one. `./check.sh docs` runs it. | None |
