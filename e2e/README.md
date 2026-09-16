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

Needs Dart on the path (for the relay) and a global Playwright install
with Chromium (`npm i -g playwright && npx playwright install chromium`).
The relay is started on port 7447, which is where a build served from
localhost looks for it: the app's relays are the build's, never typed
in (`app/lib/net/relays.dart`).
The app is opened with `?e2e=1`, which turns its semantics tree on; the
runner finds buttons, cards and the state pills by their labels and
clicks them there, so what it exercises is the screen a person sees.
