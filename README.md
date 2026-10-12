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
| [`packages/table/`](packages/table/) | The live table protocol: signed events, seats coming and going, the jury, ratings. Runs over an abstract transport and clock |
| [`packages/table_sim/`](packages/table_sim/) | The table over a simulated network, for tests and tools: a virtual clock, fake signatures, seats that lie, the chaos walk. Nothing that ships includes it |
| [`packages/deal/`](packages/deal/) | The verifiable deal as Dart sessions over the Rust primitives |
| [`crypto/`](crypto/) | Rust: the deal (`crypto/deal`, built for the Dart VM and as wasm) and BIP-340 signatures for the VM (`crypto/schnorr`) and the browser (`crypto/schnorr_wasm`) |
| [`app/`](app/) | The Flutter app, one codebase for web, Android and iOS |
| [`service/`](service/) | The Cloudflare worker's handlers (licences, the shop, TURN), the relay, the backup jurors, and a local relay for tests |
| [`e2e/`](e2e/) | Browser suites that drive the built app through its accessibility tree |
| [`site/`](site/) | The marketing site: page templates, their words in each language, and the build that joins them |
| [`config/`](config/openhearts.json) | What is not secret about this deployment: the service's public key, store and sign-in identifiers, the Stripe price |
| [`infra/`](infra/), [`observability/`](observability/) | Cloudflare, Stripe and New Relic configuration, checked and applied by script |

Solo play runs entirely on the device. Live play is four devices
talking directly to each other over WebRTC, with our relay for
introductions, as a fallback path, and for storing rooms and results
([multiplayer](docs/explanation/multiplayer.md),
[the relay](docs/explanation/relay.md)). Bots at a live table are played
by *jurors*: other players online, picked at random, with our backup
jurors making up the number when too few are online. No player sees a
bot's cards, and the juror playing a bot's seat sees only that hand,
never enough to work out a person's. The deal is Barnett–Smart mental
poker with a Bayer–Groth shuffle argument: every seat shuffles with a
proof, and the whole hand is audited and can be replayed once it ends.
What that guarantees, and where it rests on trusting us, is in
[the fair deal](docs/explanation/fair-deal.md#what-is-guaranteed-and-what-is-not).

## Start here

- **Build and test it:** [Get started](docs/tutorials/getting-started.md)
  takes a fresh clone to passing tests and the app running in Chrome.
- **Everything else:** the [documentation](docs/README.md) has how-to
  guides, reference and the design explained.
- **Contribute:** [CONTRIBUTING.md](CONTRIBUTING.md). To report a
  vulnerability, see [SECURITY.md](SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE).

## Third-party code

Code from others that ships in this repository, each under its own
licence beside it:

- **The deal's proof crates** (`crypto/vendor/`): Geometry's
  mental-poker and proof-toolbox, ported to arkworks 0.6. MIT or
  Apache-2.0.
- **ZXing** (`app/web/zxing/`): the QR scanner's decoder on the web,
  `@zxing/library` 0.23.0. Apache-2.0.
- **New Relic's browser agent** (`app/web/observability.js`): its loader,
  as New Relic serves it, on play.openhearts.game only. Apache-2.0
  (`app/web/nr-loader-full-1.323.0.min.js.LICENSE.txt`).
