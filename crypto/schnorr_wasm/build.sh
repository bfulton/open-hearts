#!/usr/bin/env bash
# Builds BIP-340 for the browser and the relay worker, copied to where
# the app serves it (app/web/schnorr.wasm), and checks it against
# BIP-340's test vectors. --locked: the versions Cargo.lock names, and
# no others.
set -euo pipefail
cd "$(dirname "$0")"
source ../wasm.sh
wasm_build
cp target/wasm32-unknown-unknown/release/schnorr_wasm.wasm ../../app/web/schnorr.wasm
node --test vectors.test.mjs
ls -la ../../app/web/schnorr.wasm
