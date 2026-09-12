# Vendored proof crates

Two crates from Geometry's [proof-toolbox](https://github.com/geometryresearch/proof-toolbox)
at commit `ada5873`, the revision the reference
[mental-poker](https://github.com/geometryxyz/mental-poker) (`b1313f3`)
pins, copied here under their own licence (`COPYRIGHT.md`,
`LICENSE-APACHE`, `LICENSE-MIT`).

Vendored for one fix, marked `// Open Hearts:` where made:

- `proof-essentials/src/zkp/proofs/schnorr_identification/prover.rs` and
  `.../chaum_pedersen_dl_equality/prover.rs`: a point written into the
  proof transcript is normalised to affine first. ark-ec 0.3 hashes a
  projective point's Jacobian coordinates, which a serialisation round
  trip does not preserve, so a proof verified straight from memory
  passed while the same proof verified from its bytes failed. Every
  proof here crosses a wire.
- `proof-essentials/Cargo.toml`: the `getrandom` `js` feature is
  dropped on wasm. The deal takes every random value as a seed the
  caller drew, and the feature pulled wasm-bindgen imports into a
  module the app loads bare.

`starknet-curve` is unchanged; it is here because the reference crate
names it by an ssh URL that cannot be fetched from a build machine.
