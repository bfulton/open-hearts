# Run the browser suites

Use this guide to run the suites in `e2e/` that drive the built web app in a headless Chromium, with a local relay, the backup jurors, the service's handlers and a TURN server on your machine.

## Before you begin

- Install Node, Flutter and Rust. CI pins the versions in `.github/workflows/ci.yml`. The suites run the relay and the backup jurors with Dart, so Dart must be on your `PATH` (Flutter's own is fine).
- Install Playwright globally, with Chromium. The suites load it from the global `node_modules` (`e2e/browser.mjs`). To install the version CI pins:

  ```bash
  npm i -g "$(grep -o 'playwright@[0-9.]*' .github/workflows/ci.yml)" && npx playwright install chromium
  ```

  On a Linux machine without Chromium's system libraries, add `--with-deps` to the second command.

- Install coturn, so that `turnserver` is on your `PATH`. Every suite that serves the app starts one on `127.0.0.1` (`startTurn` in `e2e/drive.mjs`), and stops with an error if it is missing. Only `e2e/site.mjs` runs without it.

  ```bash
  sudo apt-get install coturn
  ```

- Fetch the app's and the service's packages:

  ```bash
  (cd app && flutter pub get) && (cd service && dart pub get)
  ```

- Build the deal and Schnorr libraries, which the relay and the jurors load:

  ```bash
  (cd crypto/deal && cargo build --release --locked) && (cd crypto/schnorr && cargo build --release --locked)
  ```

- Run every command from the repository root.

## Run the suites

1. Build the app the way the suites expect it:

   ```bash
   ./e2e/build.sh
   ```

   This builds the app into `app/build/e2e`, compiled to take licences from the rig's own service key, and compiles the relay and the backup juror ahead of time. When nothing it is made from has changed, it says the build is up to date and stops. To build again anyway, add `--force`.

1. Run the suite you want. Each exits with 0 when every check passed:

   | Command | What it drives |
   |---|---|
   | `node e2e/flows.mjs` | Every flow one device can drive. |
   | `node e2e/run.mjs` | Four browsers at one table. |
   | `node e2e/escrow.mjs` | One browser and three bot seats; a juror is taken off the air. |
   | `node e2e/offline.mjs` | The network taken away a piece at a time. |
   | `node e2e/move.mjs` | The site's and the app's hosts: old addresses, the device carried over, previews. |
   | `node e2e/site.mjs` | The marketing site in each language. It needs no app build. |
   | `node e2e/shots.mjs` | Screenshots of the table at each screen shape, into `app/build/shots/`. |
   | `node e2e/site_shots.mjs` | The site's pictures of the game, into `site/public/img/`. Run it after a change to the menu. |

   For what each suite checks, see [check.sh suites, tiers and CI jobs](../reference/test-suites.md).

1. Narrow or widen a run with these flags:

   | Flag | Suites | Effect |
   |---|---|---|
   | `--only "<text>"` | `flows.mjs`, `offline.mjs`, `move.mjs` | Run only the flows whose name contains the text, such as `--only "a hand alone"`. |
   | `--jobs N` | `flows.mjs`, `offline.mjs` | Share the flows among N workers, each with a rig of its own. The default is 3 (`jobsAsked` in `e2e/pool.mjs`). |
   | `--serial` | `flows.mjs`, `offline.mjs` | Run the flows one after another, in the order they are written. The same as `--jobs 1`. |
   | `--app-dir <path>` | Every suite that serves the app | Drive a build other than `app/build/e2e`. |

1. Optional: run the in-page workers' tests, which need no browser:

   ```bash
   node --test e2e/deal_worker.test.mjs e2e/deal_golden.test.mjs e2e/offline_worker.test.mjs e2e/carry.test.mjs
   ```

Suites can run at the same time: each starts its relay on a free port of its own and names it in every address it opens. `./check.sh full` runs them in waves after `./e2e/build.sh`.

## Check it worked

1. Each suite prints a verdict for each flow or check, and its exit code is the overall verdict:

   ```bash
   node e2e/run.mjs; echo "exit $?"
   ```

1. When a suite fails, read its logs in `app/build/logs/`: the relay's (`relay-<suite>.log`, or `relay-<suite>-<worker>.log` for a suite run on several workers) and the TURN server's (`turn-<suite>.log`). `offline.mjs` also leaves a screenshot of where each flow ended in `app/build/offline/`.

## Learn more

- [How Open Hearts is tested](../explanation/testing.md#what-keeps-it-fast): why the suites run side by side, at a tenth of the tables' pace, on the least table clocks.
- [Multiplayer without a game server](../explanation/multiplayer.md#through-turn-never-direct): why the suites' data channels go through TURN.
