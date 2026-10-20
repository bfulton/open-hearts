# check.sh suites, tiers and CI jobs

This page lists what `./check.sh` runs in each mode, what each suite and browser suite runs, how tests are split into tiers, and what each CI job runs.

For why the checks are split this way, see [how Open Hearts is tested](../explanation/testing.md).

## Modes

| Command | What it runs |
|---|---|
| `./check.sh quick [base]` | The suites that the paths changed since `base` belong to, each at its fast tier. `base` defaults to `origin/main`. Changed paths are those in the commits since the merge base, the index, the working tree and untracked files. See [What quick runs](#what-quick-runs). |
| `./check.sh full` | Every suite, at every tier, in lanes. See [What full runs](#what-full-runs). |
| `./check.sh <suite>...` | The suites named, side by side. |
| `./check.sh list` | Prints the suite names. |
| `./check.sh`, `-h` or `--help` | Prints the usage, and exits with 2. |

- With `CHECK_PLAN` set to any non-empty value, `check.sh` prints the lanes it would run, and runs nothing.
- Each suite's output is in `build/check/<suite>.log`. A table of suites, results and times follows the run. The exit code is the verdict.
- The suites `engine`, `deal`, `table`, `table_slow`, `app`, `app_analyze` and `crypto` run at the lowest priority (`patient` in `check.sh`).
- Before any of `engine`, `deal`, `table`, `table_slow`, `service`, `service_js` or `service_object`, the step `deps` runs `dart pub get` in `packages/engine`, `packages/deal`, `packages/table_sim`, `packages/table` and `service`, as CI does: `dart analyze` doesn't fetch dependencies itself, and the three service suites, side by side in one package, would each fetch them at once. It has a row in the table and a log, `build/check/deps.log`.
- `<cores>` below is the machine's core count.

## Suites

Each suite is a `suite_<name>` function in `check.sh`, run from the repository's root.

| Suite | Runs |
|---|---|
| `engine` | `dart analyze --fatal-infos` and `dart test -j <cores>` in `packages/engine` |
| `deal` | `dart analyze --fatal-infos` and `dart test -j <cores>` in `packages/deal` |
| `table` | `dart analyze --fatal-infos` and `dart test -j <cores>` in `packages/table_sim`, then `dart analyze --fatal-infos` and `dart test -j <cores> -x slow` in `packages/table`: the fast tier |
| `table_slow` | `dart test -j <cores> -t slow` in `packages/table`: the slow tier |
| `service` | `dart analyze --fatal-infos` and `dart test -j <cores>` in `service`, against the Dart relay |
| `service_js` | The `service` tests with `OH_RELAY=js`: against the relay the Cloudflare object runs |
| `service_object` | The `service` tests with `OH_RELAY=object`: against that relay under the object's own rules |
| `relay_js` | `node --test service/do/*.test.mjs` |
| `functions` | `node --test service/functions/*.test.mjs` |
| `site` | `node --test site/*.test.mjs`: every page in every language, and the terms and the privacy policy against `site/ledger.json` and main's copy of it |
| `infra` | `node --test infra/*.test.mjs` |
| `ops` | `node --test ops/*.test.mjs`: [the oh command](oh.md), its reference against its table, and each command against fakes of the store, Stripe and the programs it starts |
| `workers` | `node --test` on `e2e/deal_worker.test.mjs`, `e2e/deal_golden.test.mjs`, `e2e/offline_worker.test.mjs`, `e2e/carry.test.mjs` and `crypto/schnorr_wasm/vectors.test.mjs`: the page's workers, against the committed wasm |
| `crypto` | `cargo clippy` with warnings as errors, and `cargo test`, in `crypto/deal` and `crypto/schnorr`; `cargo test` in `crypto/vendor`; `cargo clippy` for the wasm target in `crypto/schnorr_wasm` |
| `scripts` | `bash -n` on `check.sh`, `deploy.sh`, `build_phone.sh`, `oh`, `e2e/*.sh`, `crypto/*.sh`, `app/ios/*.sh` and `service/bench/build.sh`; `node --check` on `e2e/*.mjs` and `app/tool/*.mjs`; `CHECK_PLAN=1 ./check.sh full`, which fails if a suite is in none of its lanes; and, when Python has `yaml`, a parse of `.github/workflows/*.yml` |
| `docs` | `node --test docs/links.test.mjs`, then `node docs/links.mjs` |
| `app_analyze` | `flutter analyze` in `app` |
| `app` | `flutter test -j <cores>` in `app`, then `flutter test --platform chrome test/web`. Chrome is `CHROME_EXECUTABLE`, else one on the `PATH`, else one in macOS's Applications, else Playwright's Chromium. |
| `e2e_build` | `./e2e/build.sh` |
| `e2e_flows` | `node e2e/flows.mjs` |
| `e2e_run` | `node e2e/run.mjs` |
| `e2e_escrow` | `node e2e/escrow.mjs` |
| `e2e_offline` | `node e2e/offline.mjs` |
| `e2e_site` | `node e2e/site.mjs` |
| `e2e_move` | `node e2e/move.mjs` |

## What quick runs

`quick` reads each changed path against this list in order, and the first match wins.

| Changed path | Suites added |
|---|---|
| `app/lib/`, `app/test/`, `app/web/`, `app/worker/`, `app/pubspec.yaml`, `app/analysis_options.yaml`, `app/l10n.yaml` | `app_analyze`, `app`; `workers` for `app/web/` and `app/worker/`; and `site` for `app/lib/net/buying.dart`, whose price the site's tests hold to the config |
| `packages/engine/` | `engine` |
| `packages/deal/` | `deal` |
| `packages/table/`, `packages/table_sim/` | `table` |
| `service/do/` | `relay_js`, `service_js`, `service_object` |
| `service/functions/` | `functions`, `ops` |
| `service/tool/*.mjs` | `functions`, `ops` |
| Any other path under `service/` | `service` |
| `site/` | `site`, `e2e_site`, `ops` |
| `config/` | `site`, `functions`, `infra`, `ops` |
| `infra/` | `infra`, `ops` |
| `ops/`, `oh` | `ops` |
| `e2e/*.test.mjs` | `workers` |
| Any other path under `e2e/`, any other `*.sh` file, `.github/` | `scripts` |
| Any other path under `crypto/` | `crypto`, `deal`, `workers` |

`quick` always adds `docs`.

For the `app` suite, `quick` passes `-x slow`, and runs only the test files that `node app/tool/affected_tests.mjs` names for the changed app files:

- When it prints `all`, every test file runs.
- When it names only files in `app/test/web/`, the VM tests are skipped and the Chrome run still happens.
- When it names none, the `app` suite is dropped, and `app_analyze` still runs.

## What full runs

`full` runs five lanes side by side. Within a lane, steps run one after another, and suites joined by a comma run together. A failed `e2e_build` ends its lane, and the suites after it are reported as skipped. `full` refuses to run, and exits with 2, if a suite that `list` prints is in no lane; the `scripts` suite checks this with `CHECK_PLAN`.

| Lane | Steps |
|---|---|
| 1 | `table`, then `table_slow` |
| 2 | `app_analyze`, then `app` (every tier) |
| 3 | `engine` and `deal` |
| 4 | `relay_js`, `functions`, `site`, `infra`, `ops`, `workers`, `scripts` and `docs`; then `crypto`, only where `crypto/deal` has been built with cargo here and `cargo` is on the `PATH`. Otherwise `full` says that `crypto` didn't run. |
| 5 | `e2e_build`; then `e2e_move` and `e2e_site`; then `service`, `service_js`, `service_object` and `e2e_escrow`; then `e2e_run` and `e2e_offline`; then `e2e_flows` |


## Tiers and test settings

| Package | `dart_test.yaml` | Tagged `slow` | Fast tier | Slow tier |
|---|---|---|---|---|
| `packages/table` | `concurrency: 4`; declares the tag `slow` | `chaos_sealed_test.dart`, `deal_worker_test.dart`, `game_record_test.dart`, `juror_summoned_again_test.dart`, `late_juror_verdict_test.dart`, `rejoin_test.dart`, `sealed_departures_test.dart`, `sealed_lies_test.dart`, `top_up_test.dart`, `undealt_hand_test.dart`, and the later seeds of `chaos_test.dart` | `dart test -x slow` | `dart test -t slow` |
| `app` | Declares the tag `slow` | `table_fits_test.dart`, `table_fits_live_test.dart`, `table_fits_live_end_test.dart`, `table_fits_wide_test.dart`: the layout matrix in `app/test/fits.dart` | `flutter test -x slow` | `flutter test`, which runs every test |
| `service` | `concurrency: 4` | None | `dart test` | None |
| `packages/engine`, `packages/deal`, `packages/table_sim` | None | None | `dart test` | None |

- `-j` sets how many test files run at once, and overrides `concurrency`. `check.sh` passes the core count. CI passes 4 for the engine, deal and app, and leaves the table and service at their file's `concurrency`.
- The tests in `app/test/web/` are marked `@TestOn('browser')`, so they run only under `--platform chrome`.
- `OH_DEAL_MEMO=off` keeps no deal answers on disk (`packages/deal/lib/memo.dart`).

## Browser suites

The scripts in `e2e/`. Each suite exits non-zero on failure. For what they need installed, see [the e2e README](../../e2e/README.md).

| Script | What it drives | Flags | Suite |
|---|---|---|---|
| `e2e/build.sh` | Builds the app the suites drive into `app/build/e2e`, compiled to take licences from the rig's own service, and compiles the relay and juror that the suites start. Does nothing while its inputs are unchanged. | `--force` builds anyway; other arguments go to `flutter build web` | `e2e_build` |
| `e2e/flows.mjs` | Every flow one device can drive: the front door, game options, a solo game and its record, a room to share, the phone turned. Uses a real pointer as well as the accessibility tree. | `--only <text>`, `--jobs <n>`, `--serial`, `--app-dir <path>` | `e2e_flows` |
| `e2e/run.mjs` | Four browsers at one table over WebRTC; then one closed mid-hand, one stalled and booted, and one gone off its turn and ruled on by the jury | `--app-dir <path>` | `e2e_run` |
| `e2e/escrow.mjs` | One browser and three bot seats held by backup jurors in their own processes. The juror holding a seat goes silent, and the others open the seat from the escrow and finish the hand. | `--app-dir <path>` | `e2e_escrow` |
| `e2e/offline.mjs` | The network, the relays and the site's worker taken away one at a time, or left silent. Solo play must keep working, and every wait must end in words on the screen. Leaves a screenshot of each flow in `app/build/offline/`. | `--only <text>`, `--jobs <n>`, `--serial`, `--app-dir <path>` | `e2e_offline` |
| `e2e/move.mjs` | The hosts as production routes them: `openhearts.game/play/` and the site host's `/api/` answer 404; a device's storage is carried from `openhearts.game` through `/carry`; a key already at the app's host is kept; a device with nothing to carry is not held up; a carry that never answers holds the app up only briefly; a preview serves the app at `/play/` | `--only <text>`, `--app-dir <path>` | `e2e_move` |
| `e2e/site.mjs` | The marketing site in each language: the language redirect, a chosen language kept, and every page fitting a phone | None | `e2e_site` |
| `e2e/shots.mjs` | Not a check. Screenshots of the table at the shapes in [screens](../explanation/screens.md), into `app/build/shots/`. | `--app-dir <path>` | None |
| `e2e/site_shots.mjs` | Not a check. The site's pictures of the game in each language, into `site/public/img/`. | `--app-dir <path>` | None |

- `--only <text>` runs the flows whose names contain the text.
- `--jobs <n>` shares the flows among `n` workers, each with a rig of its own (`jobsAsked` in `e2e/pool.mjs`). `--serial` is one worker, in order.
- `--app-dir <path>` serves another build instead of `app/build/e2e` (`appDir` in `e2e/drive.mjs`).

The suites open the app with these query parameters. Each is read only when the page is served from this machine and the address has `e2e` (`driven` in `app/lib/net/address.dart`), except `relay`, which any build served from this machine reads (`localRelayAt` in `app/lib/net/relays.dart`).

| Parameter | Effect |
|---|---|
| `e2e` | Marks the page as driven by a suite, and builds the accessibility tree from the start. |
| `relay=<port>` | The local relay's port. |
| `pace=<share>` | The share of a table's beats to wait, such as `0.1` (`paceIn`). |
| `target=<points>` | The score the games this device starts play to, such as `1` (`targetIn`). |
| `roomWait=<seconds>` | How long a room waits for one more arrival (`roomWait`). |

## CI jobs

### `.github/workflows/ci.yml`

Runs on pull requests and on pushes to `main`. A newer push to the same pull request cancels the older run; on `main`, every run is kept. The Flutter, Rust, Node and Playwright versions are pinned in the file.

| Job | Runs | Matching `check.sh` suites |
|---|---|---|
| `app` | Builds and tests the Rust crates in `crypto/deal` and `crypto/schnorr`, and tests `crypto/vendor`. Then the engine's and deal's analysis and tests, `flutter analyze`, `flutter test -j 4` (every tier), and `flutter test --platform chrome test/web`. | `engine`, `deal`, `app_analyze`, `app`, and the tests of `crypto` |
| `web` | `flutter build web` as `deploy.sh` makes it, then `app/worker/build.sh` | None |
| `table` | Builds the Rust libraries, then the simulator's analysis and tests in `packages/table_sim`, and `dart test -x slow` and `dart test -t slow` in `packages/table` | `table`, `table_slow` |
| `service` | Builds the Rust libraries, then the `service` tests three ways (`OH_RELAY` unset, `js` and `object`) and `node --test service/do/*.test.mjs` | `service`, `service_js`, `service_object`, `relay_js` |
| `wasm` | `cargo clippy` on `crypto/deal`, `crypto/schnorr` and `crypto/schnorr_wasm`; builds both wasm files with `crypto/deal/build.sh` and `crypto/schnorr_wasm/build.sh`; fails if `app/web/deal.wasm` or `app/web/schnorr.wasm` differ from what was committed | The clippy part of `crypto` |
| `node` | The handlers', site's, infrastructure's and page workers' node tests, `./check.sh scripts` and `./check.sh docs` | `functions`, `site`, `infra`, `workers`, `scripts`, `docs` |
| `e2e` | Three runners: `flows`; `run`; and `escrow`, `offline`, `move` and `site`. Each installs coturn and Playwright, builds with `./e2e/build.sh` (cached by its sources), and runs `node e2e/<suite>.mjs` for each suite. | `e2e_build` and the browser suites |

The `workers` step of the `node` job leaves out `crypto/schnorr_wasm/vectors.test.mjs`, which `crypto/schnorr_wasm/build.sh` runs in the `wasm` job.

### `.github/workflows/ios.yml`

One job, `ios`, on macOS. It runs when started by hand, and on pull requests and pushes to `main` that change a path listed under `paths` in the file. `check.sh` has no matching suite.

| Step | What it checks |
|---|---|
| `crypto/build_ios.sh` | The deal and Schnorr libraries build as XCFrameworks. |
| `flutter test integration_test/native_libs_test.dart` on a simulator, once it has booted, for at most 25 minutes | The libraries load as the app loads them (`app/integration_test/native_libs_test.dart`). When it fails or hangs, the next step prints the end of the Flutter tool's log, the simulator's state, a sample of the app's threads, and the app's log on the simulator. |
| `flutter build ios --release --no-codesign`, without the service key | The release build is refused (`app/ios/release_check.sh`). |
| `node app/tool/defines.mjs`, then the unsigned release build | The release builds with what `config/openhearts.json` names, as `build_phone.sh` makes it. |
| `otool` and `lipo` on the built frameworks | What the release carries. |
