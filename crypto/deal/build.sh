#!/usr/bin/env bash
# Builds the deal for both hosts: a cdylib for the Dart VM (tests, the
# service, the verifier) and a wasm for the browser, copied to where
# the app serves it. --locked: the versions Cargo.lock names, and no
# others.
set -euo pipefail
cd "$(dirname "$0")"
source ../wasm.sh
cargo build --release --locked
cargo build --release --locked --target wasm32-unknown-unknown
cp target/wasm32-unknown-unknown/release/deal.wasm ../../app/web/deal.wasm
ls -la target/release/libdeal.* ../../app/web/deal.wasm
