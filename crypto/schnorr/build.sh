#!/usr/bin/env bash
# Builds the Schnorr cdylib for the Dart VM (the house, the service's
# tools, the tests). --locked: the versions Cargo.lock names, and no
# others.
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --locked
ls -la target/release/libschnorr.*
