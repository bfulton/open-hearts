# Open Hearts

An open-source Hearts game for phones and the web. Playing solo against
the bots is free, works offline, and has no ads. Live play against other
people is a paid subscription. Each live table is dealt by a protocol
that lets every player verify the deal was fair and keeps each hand
private to the person holding it.

**Play:** <https://play.openhearts.game/>

## How it is built

| | |
|---|---|
| [`packages/engine/`](packages/engine/) | The rules of Hearts and the bots, in pure Dart with no Flutter, no I/O and no clock. The app, the table protocol and the service all use it |
| [`packages/table/`](packages/table/) | The live table protocol: signed events, seats coming and going, the jury, ratings. Runs over an abstract transport and clock, with a simulator for tests |
| [`packages/deal/`](packages/deal/) | The verifiable deal as Dart sessions over the Rust primitives |
| [`crypto/`](crypto/) | Rust: the deal (`crypto/deal`, built for the Dart VM and as wasm) and BIP-340 signatures for the VM (`crypto/schnorr`) |
| [`app/`](app/) | The Flutter app, one codebase for web, Android and iOS |
| [`service/`](service/) | The Cloudflare worker's handlers (licences, the shop, TURN), the relay, the backup jurors, and a local relay for tests |
| [`e2e/`](e2e/) | Browser suites that drive the built app through its accessibility tree |
| [`site/`](site/) | The marketing site: page templates, their words in each language, and the build that joins them |
| [`config/`](config/openhearts.json) | What is not secret about this deployment: the service's public key, store and sign-in identifiers, the Stripe price |
| [`infra/`](infra/), [`observability/`](observability/) | Cloudflare, Stripe and New Relic configuration, checked and applied by script |
| [`measurements/`](measurements/README.md) | Benchmarks behind the design's numbers |

Solo play runs entirely on the device. Live play is four devices talking
directly to each other over WebRTC, with our relay
(`relay.openhearts.game`, one Cloudflare Durable Object per tag) for
introductions, as a fallback path, and for storing rooms and results.
Bots at a live table are played by *jurors*: other players online,
picked at random, or the service's backup jurors when nobody else is
online. No player sees a bot's cards, and the juror playing a bot's seat
sees only that hand, never enough to work out a person's; what that
guarantees, and where it rests on trusting us, is in
[doc 03](docs/03-fair-deal.md#what-is-guaranteed-and-what-is-not). The deal is Barnett–Smart mental poker with a
Bayer–Groth shuffle argument. Every seat shuffles with a proof, and the
whole hand is audited and can be replayed once it ends.

Design docs: [01 dev loop](docs/01-dev-loop.md) ·
[02 multiplayer](docs/02-multiplayer.md) ·
[03 fair deal](docs/03-fair-deal.md) ·
[04 live play](docs/04-live-play.md) ·
[05 screens](docs/05-form-factors.md) ·
[06 service](docs/06-service.md) ·
[07 table states](docs/07-states.md) ·
[08 relay](docs/08-own-relays.md) ·
[09 testing](docs/09-testing.md) ·
[security model](docs/security-review.md)

## Building and testing

You need Flutter (stable), which brings Dart. The deal and native
signatures also need stable Rust with the `wasm32-unknown-unknown`
target. The browser suites need Node and a global Playwright with
Chromium. Run `dart pub get` (`flutter pub get` in `app/`) in a package
before testing it.

```bash
crypto/deal/build.sh                 # the deal: a cdylib for the VM, and app/web/deal.wasm
crypto/schnorr/build.sh              # signatures for the VM (optional: pure Dart is the fallback)

./check.sh quick                     # what you changed, at each package's fast tier
./check.sh full                      # everything below, side by side, with a table of times

cd packages/engine && dart test      # rules and bots, including 200 seeded games
cd packages/deal && dart test        # the deal's primitives and a four-seat deal
cd packages/table && dart test       # the protocol on a simulated network (-x slow: the fast tier)
cd service && dart test              # the local relay, and hands played over real sockets
cd service && OH_RELAY=js dart test  # the same suite against the relay the Durable Object runs
cd app && flutter test               # widgets

node --test service/do/*.test.mjs service/functions/*.test.mjs infra/*.test.mjs
node --test e2e/deal_worker.test.mjs e2e/deal_golden.test.mjs e2e/offline_worker.test.mjs e2e/carry.test.mjs

cd app && flutter run -d chrome      # run the app locally
```

The deal's wasm is committed at `app/web/deal.wasm`, so the web build
needs no Rust. VM tests that deal a sealed hand load the cdylib from
`crypto/deal/target/release/`, and keep its answers beside it in
`crypto/deal/target/memo/` ([doc 09](docs/09-testing.md)). The browser
suites run from the repository root, each start a local relay on a port
of their own, and run the service's handlers in-process
([e2e/README.md](e2e/README.md)):

```bash
./e2e/build.sh
node e2e/flows.mjs     # every flow one device can drive, three at a time
node e2e/run.mjs       # four browsers at one table
node e2e/escrow.mjs    # a bot seat's juror goes, and the escrow opens the seat
node e2e/offline.mjs   # no network, relay or worker: solo still plays
node e2e/move.mjs      # openhearts.game/play/ to play.openhearts.game: nothing left at the old address, and the device carried over
node e2e/shots.mjs     # screenshots at the shapes docs/05 names
```

### Phone releases

`./build_phone.sh ios` or `./build_phone.sh android` makes a store
build. It builds the deal's native libraries, then the release, compiled
with what `config/openhearts.json` names (`app/tool/defines.mjs`): the
service key the app takes a licence from, the sign-in identifiers and the
store products. A release built without the service key is refused, by
Xcode (`app/ios/release_check.sh`) and by Gradle, since it would have
live play shut.

Android needs the NDK, the Rust Android targets, and a signing key named
in `app/android/key.properties` (`storeFile`, `storePassword`,
`keyAlias`, `keyPassword`), which is never checked in. Debug builds need
neither the libraries nor the key.

iOS needs a Mac with Xcode and the Rust targets `aarch64-apple-ios`,
`aarch64-apple-ios-sim` and `x86_64-apple-ios`. The libraries go into
`app/ios/Frameworks` as XCFrameworks (`crypto/build_ios.sh`), which the
Runner target embeds and signs, so Xcode builds nothing without them,
debug included. The `ios` workflow (`.github/workflows/ios.yml`) builds
them on a Mac runner, checks them on a simulator
(`app/integration_test/native_libs_test.dart`), and builds the release
unsigned, once without the key to see it refused.

### Deploying

`./deploy.sh` builds the site and the web app and publishes them to
Cloudflare Pages. It needs `CLOUDFLARE_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`
([doc 01](docs/01-dev-loop.md)). A build accepts licences only from the
service key it was compiled with. Mint the key pair once with
`cd service && dart run bin/service_key.dart`, put the public half in
`config/openhearts.json` as `serviceKey`, and set the secret half as the
Pages secret `OH_SERVICE_SECRET`. A build without the key has live play shut.
The relay deploys separately: `cd service/do && npx wrangler@4 deploy`.
Everything that is not secret is in `config/openhearts.json`; [doc 06](docs/06-service.md) lists the secrets.

### Languages

English, Spanish, Brazilian Portuguese, German and French, picked from
the device's language (`?lang=de` overrides it). Strings live in
`app/lib/l10n/app_*.arb`, and `app/test/l10n_test.dart` lays out every
page in every language. To add a language, add one more `.arb` file.

### The bots

`packages/engine/lib/src/bot.dart` uses named heuristics rather than
search. Each persona comes in nine strengths, rated by
`packages/table/tool/ladder.dart`. The benchmark seats the same bot four
times, so wins by seat should come out flat:

```bash
cd packages/engine && dart run tool/bot_stats.dart --games 2000
```

`tool/blunders.dart` lists plays that took avoidable points, and
`tool/knobs.dart` measures what each strength setting is worth.

## Licence

MIT. See [LICENSE](LICENSE).
