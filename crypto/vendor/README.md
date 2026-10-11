# Vendored proof crates

The deal's cryptography (docs/03-fair-deal.md) is Geometry's reference
implementation of Barnett–Smart mental poker with a Bayer–Groth shuffle
argument, on the Starknet curve. All three crates are vendored here,
each under its own licence, because upstream is unmaintained and was
written against arkworks 0.3:

- `barnett-smart-card-protocol`: [mental-poker](https://github.com/geometryxyz/mental-poker)
  at `b1313f3` (its licence is in its directory; its examples are left
  out).
- `proof-essentials` and `starknet-curve`: Geometry's
  [proof-toolbox](https://github.com/geometryresearch/proof-toolbox) at
  `ada5873`, the revision mental-poker pins (licence: `COPYRIGHT.md`,
  `LICENSE-APACHE`, `LICENSE-MIT` here).

They build and test together as a workspace:

    cd crypto/vendor && cargo test --release

## What is changed, marked `// Open Hearts:` where made

**Ported from arkworks 0.3 to 0.6**, keeping every byte a device sends
or keeps as 0.3 made it. Keys, masked cards, shuffles and their
arguments, every proof, and the Fiat–Shamir transcripts the proofs'
challenges are hashed from are byte for byte the same, so a device on
the older library and one on this can sit at one table, and every game
kept by the older library still verifies. The deal's golden vectors
hold this (crypto/deal/tests/golden.rs: 634 calls recorded from the 0.3
library, replayed natively, over FFI from Dart, and in the browser's
wasm), as do two sealed games the 0.3 library kept
(packages/table/test/kept_records_test.dart).

- `proof-essentials/src/to_bytes.rs`: arkworks 0.3's `ToBytes` and
  `to_bytes!`, which 0.4 removed and every transcript here hashes
  through, kept with 0.3's encodings: integers little-endian, strings
  and sequences as their bytes with no length, a field element as its
  canonical limbs, an affine point as x, y and an infinity byte (the
  point at infinity as 0.3 held it, (0, 1, true)), a projective point as
  its normal form (Z one; (1, 1, 0) at infinity). `TranscriptCurve` is a
  curve whose points have those bytes, and is what the generic code
  takes where it took `ProjectiveCurve`.
- `proof-essentials/src/zkp/fiat_shamir.rs`: ark-marlin 0.3's
  `FiatShamirRng` (ChaCha20, keyed by a running hash of everything
  absorbed), since ark-marlin was never carried past 0.3.
- The API moves: `ProjectiveCurve`/`AffineCurve` to `CurveGroup`/
  `AffineRepr`; a sum of affine points is projective in 0.6 and is
  normalised where 0.3 normalised it; `p.mul(s.into_repr())` is `p * s`;
  the Pedersen MSM takes exactly as many bases as scalars (0.3 zipped
  the key down to the vector's length); serialisation is
  `serialize_compressed`/`deserialize_compressed`, which encodes a
  point's x with the same two flag bits 0.3 did (bit 7: y the larger of
  the two roots; bit 6: infinity) and reads them the same way.
- `starknet-curve`: the fields are derived (`MontConfig`) from the same
  modulus and generator; their tests hold the derived Montgomery
  constants to the ones 0.3 spelled out, which is what makes a value
  drawn from the same seed the same value. The point at infinity keeps
  a flag of its own (`ZeroFlag = bool`). The unused r1cs gadgets are left
  out.
- Dropped as unused: proof-essentials' merlin transcript module and
  criterion bench (measurements/shuffle is the benchmark), and the
  dependencies only they or 0.3 needed (ark-marlin, ark-crypto-primitives,
  merlin, anyhow). Blake2 is 0.10 (the same BLAKE2b-512 and BLAKE2s-256).

**A point is normalised before it is written into a proof's transcript**
(`proof-essentials/src/zkp/proofs/schnorr_identification/prover.rs` and
`.../chaum_pedersen_dl_equality/prover.rs`). ark-ec 0.3 hashed a
projective point's Jacobian coordinates, which a serialisation round
trip does not preserve, so a proof verified straight from memory passed
while the same proof verified from its bytes failed. Every proof here
crosses a wire. (`to_bytes.rs` now writes the normal form whatever
coordinates it is given; the normalisation stays, so a proof holds what
it always held.)

**No `getrandom` `js` feature on wasm** (`proof-essentials/Cargo.toml`).
The deal takes every random value as a seed the caller drew, and the
feature pulled wasm-bindgen imports into a module the app loads bare.
