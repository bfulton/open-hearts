use crate::*;
use ark_algebra_test_templates::*;
use ark_ff::{BigInt, MontConfig};

test_field!(fr; Fr; mont_prime_field);
// Not the FFT tests for the base field: its two-adicity is 192, more
// than they count to (https://github.com/arkworks-rs/algebra/issues/313),
// as in arkworks 0.3.
test_field!(fq; Fq);

// Open Hearts: the constants arkworks 0.3 spelled out, which 0.6 derives.
// An element is held in Montgomery form, and a random one is drawn as
// raw limbs in that form, so these being the same is what makes a value
// drawn from the same seed the same value.
#[test]
fn the_montgomery_constants_are_the_ones_arkworks_0_3_spelled_out() {
    assert_eq!(FqConfig::R, BigInt::new([0xffffffffffffffe1, 0xffffffffffffffff, 0xffffffffffffffff, 0x07fffffffffffdf0]));
    assert_eq!(FqConfig::R2, BigInt::new([0xfffffd737e000401, 0x00000001330fffff, 0xffffffffff6f8000, 0x07ffd4ab5e008810]));
    assert_eq!(FqConfig::INV, 18446744073709551615);
    assert_eq!(FqConfig::GENERATOR.0, BigInt::new([0xffffffffffffffa1, 0xffffffffffffffff, 0xffffffffffffffff, 0x07fffffffffff9b0]));
    assert_eq!(FqConfig::TWO_ADIC_ROOT_OF_UNITY.0, BigInt::new([0x4106bccd64a2bdd8, 0xaaada25731fe3be9, 0x0a35c5be60505574, 0x07222e32c47afc26]));
    assert_eq!(FrConfig::R, BigInt::new([0x51925a0bf4fca74f, 0xc75ec4b46df16bee, 0x0000000000000008, 0x07fffffffffffdf1]));
    assert_eq!(FrConfig::R2, BigInt::new([0x6021b3f1ea1c688d, 0x509cf64d14ce60b9, 0xbaf0ab4cf78bbabb, 0x07d9e57c2333766e]));
    assert_eq!(FrConfig::INV, 13504954208620504625);
    assert_eq!(FrConfig::GENERATOR.0, BigInt::new([0xb7e9c9a083695b8f, 0xe71a2941b404df66, 0x000000000000001a, 0x07fffffffffff9b1]));
    assert_eq!(FrConfig::TWO_ADIC_ROOT_OF_UNITY.0, BigInt::new([0xccd44835b8c9a5e0, 0xf0224db95cf64643, 0xfffffffffffffff6, 0x000000000000021f]));
}
