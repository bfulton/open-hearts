# Sourced by the builds of the wasm the app serves (deal/build.sh,
# schnorr_wasm/build.sh). `wasm_build` builds for the wasm target with
# no path of the machine that built it inside and no name section, so
# the same sources and toolchain give the same bytes anywhere and CI
# can check the committed wasm is what its sources build. The flags go
# to that one cargo run only, unit-separated (CARGO_ENCODED_RUSTFLAGS)
# so a path with a space in it stays one argument; with --target they
# reach the wasm's own crates and not the build scripts.
wasm_build() {
  local root cargo_home us=$'\x1f'
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  cargo_home=${CARGO_HOME:-$HOME/.cargo}
  CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$root=.$us--remap-path-prefix=$cargo_home=cargo$us-C${us}strip=symbols" \
    cargo build --release --locked --target wasm32-unknown-unknown
}
