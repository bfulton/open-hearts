# Measurements

Numbers the design depends on, taken rather than guessed. Each one is a
small harness that can be re-run when something changes.

## The bot as a circuit

`packages/engine/lib/src/oblivious.dart` is the bot rewritten without a
branch on secret data, and `packages/engine/tool/circuit_count.dart`
counts its AND gates:

    cd packages/engine && dart run tool/circuit_count.dart

## The verifiable deal

`shuffle/` times one deal — four shuffle-and-remask proofs, their
verification, and opening a hand — using the reference implementation
of Barnett–Smart with a Bayer–Groth shuffle argument
([geometryxyz/mental-poker](https://github.com/geometryxyz/mental-poker)),
natively and as WebAssembly.

    cd measurements/shuffle
    cargo run --release                                   # native
    cargo build --release --target wasm32-unknown-unknown # wasm
    node bench.mjs                                        # wasm under V8

`bench.html` is the same host for a browser. `deploy.sh` publishes it
with the wasm at `/measure/shuffle/` when the wasm has been built, so
the number that matters — a phone's — is one tap away on the dev site.
