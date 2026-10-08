# The verifiable deal's cost

Times one deal — four shuffle-and-remask proofs, their verification, and
opening a hand — with the reference implementation of Barnett–Smart and
a Bayer–Groth shuffle argument
([geometryxyz/mental-poker](https://github.com/geometryxyz/mental-poker)),
as the deal builds it — vendored and ported to arkworks 0.6
(crypto/vendor) — natively and as WebAssembly.

    cd measurements/shuffle
    cargo run --release                                   # native
    cargo build --release --target wasm32-unknown-unknown --lib  # wasm
    node bench.mjs                                        # wasm under V8

`bench.html` hosts the same benchmark in a browser. When the wasm has
been built, `deploy.sh` publishes it at `/measure/shuffle/` on the dev
site, so it can be run on a phone.
