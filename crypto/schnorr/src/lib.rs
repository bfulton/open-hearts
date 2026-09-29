//! BIP-340 Schnorr over secp256k1 for the Dart VM, over FFI: the same
//! functions as the browser's wasm (measurements/sign/wasm), with std.
//!
//! schnorr_sign(sk, msg, aux, out) — 32-byte secret, 32-byte digest,
//! 32 bytes of auxiliary randomness; writes a 64-byte signature and
//! returns 1 on success. schnorr_verify(pk, msg, sig) — 32-byte x-only
//! key, 32-byte digest, 64-byte signature; returns 1 when good.

use k256::schnorr::{signature::hazmat::PrehashVerifier, Signature, SigningKey, VerifyingKey};

/// # Safety
/// Every pointer must be readable for its length; `out` writable for 64.
#[no_mangle]
pub unsafe extern "C" fn schnorr_sign(sk: *const u8, msg: *const u8, aux: *const u8, out: *mut u8) -> i32 {
    let (sk, msg, aux) = (
        std::slice::from_raw_parts(sk, 32),
        std::slice::from_raw_parts(msg, 32),
        std::slice::from_raw_parts(aux, 32),
    );
    let Ok(key) = SigningKey::from_bytes(sk) else { return 0 };
    let Ok(sig) = key.sign_raw(msg, aux.try_into().unwrap()) else { return 0 };
    std::ptr::copy_nonoverlapping(sig.to_bytes().as_ptr(), out, 64);
    1
}

/// # Safety
/// Every pointer must be readable for its length.
#[no_mangle]
pub unsafe extern "C" fn schnorr_verify(pk: *const u8, msg: *const u8, sig: *const u8) -> i32 {
    let (pk, msg, sig) = (
        std::slice::from_raw_parts(pk, 32),
        std::slice::from_raw_parts(msg, 32),
        std::slice::from_raw_parts(sig, 64),
    );
    let Ok(key) = VerifyingKey::from_bytes(pk) else { return 0 };
    let Ok(sig) = Signature::try_from(sig) else { return 0 };
    key.verify_prehash(msg, &sig).is_ok() as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_verifies_bip340_vector_zero() {
        // BIP-340 test vector 0: secret 3, aux zero, message zero.
        let sk = {
            let mut b = [0u8; 32];
            b[31] = 3;
            b
        };
        let msg = [0u8; 32];
        let aux = [0u8; 32];
        let mut sig = [0u8; 64];
        assert_eq!(unsafe { schnorr_sign(sk.as_ptr(), msg.as_ptr(), aux.as_ptr(), sig.as_mut_ptr()) }, 1);
        let expected = hex_literal("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0");
        assert_eq!(sig.to_vec(), expected);
        let pk = hex_literal("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9");
        assert_eq!(unsafe { schnorr_verify(pk.as_ptr(), msg.as_ptr(), sig.as_ptr()) }, 1);
        sig[0] ^= 1;
        assert_eq!(unsafe { schnorr_verify(pk.as_ptr(), msg.as_ptr(), sig.as_ptr()) }, 0);
    }

    fn hex_literal(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }
}
