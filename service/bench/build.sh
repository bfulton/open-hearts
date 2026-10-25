#!/usr/bin/env bash
# The backup jurors as a container image (Dockerfile here,
# service/do/bench.mjs runs it): the juror compiled ahead of time, and
# the deal's and Schnorr's native libraries beside it where the juror
# looks for them (crypto/*/target/release under its working directory).
#
# Built on the host and copied in, not built inside the image: both
# crates build from their lockfiles with the host's cargo, and the Dart
# SDK need not be in the image. The host is linux/amd64, which is what
# Cloudflare runs; the image's base matches the host's glibc (Ubuntu
# 24.04).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# Wrangler runs this before every deploy of the relay worker. Production
# is deployed from main as it was reviewed, and only when nothing else
# stands in the way (ops/gate.mjs), whether or not oh started it. The
# preview relay (wrangler.toml, [env.preview]) runs this with --preview,
# and is built from any branch, as a preview of the site is. A
# `wrangler deploy --dry-run`, which publishes nothing, may set
# OH_RELAY_DRY_RUN=1 to build from anywhere.
if [ "${1:-}" != --preview ] && [ "${OH_RELAY_DRY_RUN:-}" != 1 ]; then
  node "$root/ops/gate.mjs" relay
fi
out="$here/stage"
rm -rf "$out"
mkdir -p "$out/crypto/deal/target/release" "$out/crypto/schnorr/target/release"
( cd "$root/crypto/deal" && cargo build --release --locked )
( cd "$root/crypto/schnorr" && cargo build --release --locked )
cp "$root/crypto/deal/target/release/libdeal.so" "$out/crypto/deal/target/release/"
cp "$root/crypto/schnorr/target/release/libschnorr.so" "$out/crypto/schnorr/target/release/"
( cd "$root/service" && dart compile exe bin/juror.dart -o "$out/juror" )
ls -la "$out" "$out/crypto/deal/target/release" "$out/crypto/schnorr/target/release"
