#!/usr/bin/env bash
# Builds the deal for both hosts: a cdylib for the Dart VM (tests, the
# service, the verifier) and a wasm for the browser, copied to where
# the app serves it. Offline: the reference crate is vendored or cached.
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --offline
cargo build --release --offline --target wasm32-unknown-unknown
cp target/wasm32-unknown-unknown/release/deal.wasm ../../app/web/deal.wasm
ls -la target/release/libdeal.* ../../app/web/deal.wasm
