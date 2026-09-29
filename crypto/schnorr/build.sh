#!/usr/bin/env bash
# Builds the Schnorr cdylib for the Dart VM (the service's relay and
# juror, the tests). Offline: k256 is in the cargo cache.
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --offline
ls -la target/release/libschnorr.*
