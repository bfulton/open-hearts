# End to end

Four real browsers at one table, driven through the app's accessibility
tree: host a room, join it by code, play a hand over WebRTC, then the
departure cells only a real browser can show — one closed mid-hand, one
stalled on its turn and booted, one that leaves — with the local relay
and the built web app served from this machine.

```bash
./e2e/build.sh
cd .. && node e2e/run.mjs
```

And beside it, one browser alone against three bot seats the jury
holds, for the thing four browsers cannot stage: the juror holding a
seat is taken off the air and the jurors that are left open the seat
from the escrow between themselves. One browser, because the jury has
to be known — a jury is drawn from whoever is online, and a person
seated is not eligible for her own table, so the jury is exactly the
bench of jurors of last resort, which runs one process per juror so a
single one can be silenced.

```bash
cd .. && node e2e/escrow.mjs
```

Needs Dart on the path (for the relay) and a global Playwright install
with Chromium (`npm i -g playwright && npx playwright install chromium`).
The relay is started on port 7447, which is where a build served from
localhost looks for it: the app's relays are the build's, never typed
in (`app/lib/net/relays.dart`).
The app is opened with `?e2e=1`, which turns its semantics tree on; the
runner finds buttons, cards and the state pills by their labels and
clicks them there, so what it exercises is the screen a person sees.
