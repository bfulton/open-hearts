use crate::{Affine, Projective};
use ark_algebra_test_templates::*;
use ark_ec::AffineRepr;

test_group!(g; Projective; sw);

#[test]
fn test_generator() {
    let generator = Affine::generator();
    assert!(generator.is_on_curve());
    assert!(generator.is_in_correct_subgroup_assuming_on_curve());
}
