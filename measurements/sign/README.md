# BIP-340 in the browser

Every table event is signed by its author, and on a relay it travels
inside a second signature by whoever sends it; every peer verifies
both, from three other seats, several times a turn. `packages/table`
signs with the pure-Dart `bip340` package: about 11 ms a signature in
the Dart VM, which the service and the tests can afford. The web app is
dart2js, so this measures the same code in Chromium — and next to it a
48 KB wasm build of the `k256` crate (RustCrypto's secp256k1) exposing
`sign` and `verify` on linear memory, no bindgen.

```bash
cd measurements/sign
dart pub get
dart compile js -O2 -o main.dart.js web/main.dart      # the Dart side
(cd wasm && cargo build --release --target wasm32-unknown-unknown)
cp wasm/target/wasm32-unknown-unknown/release/schnorr_wasm.wasm schnorr.wasm
node check.mjs                                         # BIP-340 vectors, then timing under node
node bench.mjs                                         # both, in headless Chromium
```

Headless Chromium 141 on the dev box:

| | sign, ms | verify, ms |
|---|---|---|
| `bip340`, Dart compiled to JavaScript | 104 | 109 |
| `k256`, Rust compiled to wasm | 0.56 | 0.22 |
| for scale: `bip340` in the Dart VM | 11 | 11 |

Two hundred times. A turn at a table costs a peer one signature and
six to eight verifications, so the JavaScript figure is close to a
second of main-thread time per turn, on a fast machine, and the wasm
figure is a couple of milliseconds. The web app signs and verifies
through this wasm, committed as `app/web/schnorr.wasm` (`dart:js_interop`),
which the relay worker also verifies with. The Dart VM uses
`crypto/schnorr`, the same `k256` code as a native library, and falls
back to `bip340` when that is not built.

`check.mjs` proves the wasm against BIP-340's published test vectors —
the signature is bit-identical to the reference, a good signature
verifies, a flipped bit does not — before it times anything.
