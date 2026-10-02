#!/usr/bin/env bash
# The jurors of last resort as a container image (Dockerfile here,
# service/do/bench.mjs runs it): the juror compiled ahead of time, and
# the deal's and Schnorr's native libraries beside it where the juror
# looks for them (crypto/*/target/release under its working directory).
#
# Built on the host and copied in, not built inside the image: both
# crates build offline from the host's cargo cache, and the Dart SDK
# need not be in the image. The host is linux/amd64, which is what
# Cloudflare runs; the image's base matches the host's glibc (Ubuntu
# 24.04).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/stage"
rm -rf "$out"
mkdir -p "$out/crypto/deal/target/release" "$out/crypto/schnorr/target/release"
( cd "$root/crypto/deal" && cargo build --release --offline )
( cd "$root/crypto/schnorr" && cargo build --release --offline )
cp "$root/crypto/deal/target/release/libdeal.so" "$out/crypto/deal/target/release/"
cp "$root/crypto/schnorr/target/release/libschnorr.so" "$out/crypto/schnorr/target/release/"
( cd "$root/service" && dart compile exe bin/juror.dart -o "$out/juror" )
ls -la "$out" "$out/crypto/deal/target/release" "$out/crypto/schnorr/target/release"
