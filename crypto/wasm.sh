# Sourced by the builds of the wasm the app serves (deal/build.sh,
# schnorr_wasm/build.sh). Flags for the wasm target only: no path of
# the machine that built it inside, and no name section, so the same
# sources and toolchain give the same bytes anywhere and CI can check
# the committed wasm is what its sources build.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cargo_home=${CARGO_HOME:-$HOME/.cargo}
export CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS="--remap-path-prefix=$root=. --remap-path-prefix=$cargo_home=cargo -C strip=symbols"
