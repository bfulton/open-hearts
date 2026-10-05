# End to end

Browser suites that drive the built web app through its accessibility
tree, with the local relay and the service's handlers running on this
machine. The app is opened with `?e2e=1`, which builds the semantics tree
from the start. The suites find buttons, cards and state pills by their
labels, so they exercise the screen a person sees. `flows.mjs` also
taps with a real pointer, so a tap landing in the wrong place shows up.

Run everything from the repository root, after building the app the way
the suites expect it:

```bash
./e2e/build.sh                          # app/build/e2e, served at / and keyed to the rig's service
node e2e/flows.mjs                      # every flow one device can drive
node e2e/flows.mjs --only "a hand alone"
node e2e/run.mjs                        # four browsers at one table
node e2e/escrow.mjs                     # one browser and three bot seats; a juror is taken off the air
node e2e/offline.mjs                    # the network taken away a piece at a time
node e2e/offline.mjs --only "airplane"
node e2e/shots.mjs                      # screenshots at docs/05's shapes, in app/build/shots/
node e2e/longpress_copy.mjs             # long-press Copy on an iPhone user agent
node --test e2e/deal_worker.test.mjs e2e/offline_worker.test.mjs
```

Every suite takes `--app-dir <path>` to use a different build. The exit
code is the verdict.

- **`run.mjs`**: four headless Chromium contexts, four devices and four
  keys. They host a room, join it by code, and play a hand over WebRTC.
  Then come the departures only a real browser can show: one browser
  closed mid-hand, one stalled on its turn and booted, and one that
  leaves.
- **`escrow.mjs`**: one person and three bot seats held by the jury.
  A juror can only be drawn from whoever is online, and a seated player
  cannot be a juror at her own table, so the jury is exactly the bench of
  jurors of last resort. The suite runs each juror as its own process.
  It silences the juror holding a seat and checks that the remaining
  jurors open the seat from the escrow and finish the hand.
- **`offline.mjs`**: takes away the whole network (mid-session, and
  from a cold start off the offline worker's copy), the relays (gone, or
  open and silent), and the site's worker (refusing, failing, or never
  answering). Solo play must keep working, and every wait must end in
  words on the screen. The suite records how long each wait took, and
  leaves a screenshot of each flow in `app/build/offline/`.

## Requirements

Dart on the path (for the relay and the jurors), and a global Playwright
with Chromium:

```bash
npm i -g playwright && npx playwright install chromium
```

The relay starts on port 7447, where a build served from localhost looks
for it (`app/lib/net/relays.dart`). `e2e/build.sh` compiles the app
against BIP-340's published test key pair, which the in-process handlers
sign licences with, so the suites go through the real licence check.
