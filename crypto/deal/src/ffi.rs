//! The flat interface.
//!
//! Every function takes pointers and lengths into memory the caller
//! owns (from `deal_alloc`), returns the bytes written or -1, and never
//! keeps a reference. The same symbols serve wasm and the VM's FFI.
//!
//! Safety, for every unsafe function here: each pointer is null or
//! valid for as many bytes as the function reads or writes through it
//! (the fixed sizes in lib.rs, or the length or count passed beside
//! it), and no output overlaps an input. A null pointer reads as empty,
//! which fails the call.

use super::*;
use std::slice;

/// Reads the fixed parameters in, so the first deal does not pay for it.
#[no_mangle]
pub extern "C" fn deal_setup() {
    let _ = fixed();
}

#[no_mangle]
pub extern "C" fn deal_alloc(n: usize) -> *mut u8 {
    let mut v = Vec::<u8>::with_capacity(n.max(1));
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    p
}

/// # Safety
/// `p` came from `deal_alloc(n)`.
#[no_mangle]
pub unsafe extern "C" fn deal_free(p: *mut u8, n: usize) {
    drop(Vec::from_raw_parts(p, 0, n.max(1)));
}

unsafe fn input<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() { &[] } else { slice::from_raw_parts(p, n) }
}

unsafe fn output<'a>(p: *mut u8, n: usize) -> &'a mut [u8] {
    if p.is_null() { &mut [] } else { slice::from_raw_parts_mut(p, n) }
}

fn done(r: Option<usize>) -> i32 {
    r.map(|n| n as i32).unwrap_or(-1)
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_keygen(secret: *const u8, out: *mut u8) -> i32 {
    done(keygen(input(secret, SCALAR), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_key_proof(secret: *const u8, name: *const u8, name_len: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(key_proof(input(secret, SCALAR), input(name, name_len), input(seed, 32), output(out, KEY_PROOF)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_key(pk: *const u8, name: *const u8, name_len: usize, proof: *const u8) -> i32 {
    verify_key(input(pk, POINT), input(name, name_len), input(proof, KEY_PROOF)) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_aggregate(pks: *const u8, count: usize, out: *mut u8) -> i32 {
    done(aggregate(input(pks, count * POINT), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_initial_deck(joint: *const u8, out: *mut u8) -> i32 {
    done(initial_deck(input(joint, POINT), output(out, DECK_BYTES)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_shuffle(joint: *const u8, deck_in: *const u8, seed: *const u8, deck_out: *mut u8, proof_out: *mut u8, proof_cap: usize) -> i32 {
    done(shuffle(input(joint, POINT), input(deck_in, DECK_BYTES), input(seed, 32), output(deck_out, DECK_BYTES), output(proof_out, proof_cap)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_shuffle(joint: *const u8, deck_in: *const u8, deck_out: *const u8, proof: *const u8, proof_len: usize) -> i32 {
    verify_shuffle(input(joint, POINT), input(deck_in, DECK_BYTES), input(deck_out, DECK_BYTES), input(proof, proof_len)) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_reveal_token(secret: *const u8, masked: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(reveal_token(input(secret, SCALAR), input(masked, MASKED), input(seed, 32), output(out, TOKEN)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_split(secret: *const u8, shares: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(split(input(secret, SCALAR), shares, input(seed, 32), output(out, shares * SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_share_bytes(secret: *const u8, len: usize, n: usize, t: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(share_bytes(input(secret, len), n, t, input(seed, 32), output(out, n * len)))
}

/// The coefficient itself, since it is one byte: negative for a set
/// that is not one.
///
/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_bytes_lagrange(have: *const u8, count: usize, index: u8, at: u8) -> i32 {
    match bytes_lagrange(input(have, count), index, at) {
        Some(c) => c as i32,
        None => -1,
    }
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_bytes_scale(share: *const u8, len: usize, by: u8, out: *mut u8) -> i32 {
    done(bytes_scale(input(share, len), by, output(out, len)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_bytes_sum(parts: *const u8, count: usize, len: usize, out: *mut u8) -> i32 {
    done(bytes_sum(input(parts, count * len), len, output(out, len)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_split_threshold(secret: *const u8, n: usize, t: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(split_threshold(input(secret, SCALAR), n, t, input(seed, 32), output(out, n * SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_lagrange(have: *const u8, count: usize, index: u8, at: u8, out: *mut u8) -> i32 {
    done(lagrange(input(have, count), index, at, output(out, SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_scalar_mul(a: *const u8, b: *const u8, out: *mut u8) -> i32 {
    done(scalar_mul(input(a, SCALAR), input(b, SCALAR), output(out, SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_scalar_sum(parts: *const u8, count: usize, out: *mut u8) -> i32 {
    done(scalar_sum(input(parts, count * SCALAR), output(out, SCALAR)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_point_scale(point: *const u8, scalar: *const u8, out: *mut u8) -> i32 {
    done(point_scale(input(point, POINT), input(scalar, SCALAR), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_share_key(share: *const u8, out: *mut u8) -> i32 {
    done(share_key(input(share, SCALAR), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_share_token(share: *const u8, masked: *const u8, seed: *const u8, out: *mut u8) -> i32 {
    done(share_token(input(share, SCALAR), input(masked, MASKED), input(seed, 32), output(out, TOKEN)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_open_shared(sealed: *const u8, parts: *const u8, count: usize, out: *mut u8) -> i32 {
    done(open_shared(input(sealed, SEALED), input(parts, count * POINT), output(out, POINT)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_token(pk: *const u8, masked: *const u8, token: *const u8) -> i32 {
    verify_token(input(pk, POINT), input(masked, MASKED), input(token, TOKEN)) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_unmask(pks: *const u8, tokens: *const u8, count: usize, masked: *const u8) -> i32 {
    done(unmask(input(pks, count * POINT), input(tokens, count * POINT), input(masked, MASKED)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_reveal_tokens(secret: *const u8, masked: *const u8, count: usize, seed: *const u8, out: *mut u8) -> i32 {
    done(reveal_tokens(
        input(secret, SCALAR),
        input(masked, count * MASKED),
        input(seed, 32),
        output(out, tokens_len(count)),
    ))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_tokens(pk: *const u8, masked: *const u8, count: usize, tokens: *const u8) -> i32 {
    verify_tokens(input(pk, POINT), input(masked, count * MASKED), input(tokens, tokens_len(count))) as i32
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_seal(
    secret: *const u8,
    pk_to: *const u8,
    masked: *const u8,
    seed: *const u8,
    out: *mut u8,
) -> i32 {
    done(seal(
        input(secret, SCALAR),
        input(pk_to, POINT),
        input(masked, MASKED),
        input(seed, 32),
        output(out, SEALED + SEAL_PROOF),
    ))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_verify_seal(pk_owner: *const u8, pk_to: *const u8, masked: *const u8, sealed: *const u8) -> i32 {
    i32::from(verify_seal(
        input(pk_owner, POINT),
        input(pk_to, POINT),
        input(masked, MASKED),
        input(sealed, SEALED + SEAL_PROOF),
    ))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_shared_secret(secret: *const u8, pk: *const u8, out: *mut u8) -> i32 {
    done(shared_secret(input(secret, SCALAR), input(pk, POINT), output(out, 32)))
}

/// # Safety
///
/// The flat interface's contract (above).
#[no_mangle]
pub unsafe extern "C" fn deal_open(secret: *const u8, sealed: *const u8, out: *mut u8) -> i32 {
    done(open(input(secret, SCALAR), input(sealed, SEALED), output(out, POINT)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The flat interface writes what the function behind it writes,
    /// and a null pointer fails the call rather than being read.
    #[test]
    fn the_flat_interface_is_the_function_behind_it() {
        let secret = seed(1);
        let mut pk = [0u8; POINT];
        assert_eq!(keygen(&secret, &mut pk), Some(POINT));
        let mut flat = [0u8; POINT];
        // Safety: each pointer is valid for the fixed size the call reads
        // or writes, and none overlaps another.
        assert_eq!(unsafe { deal_keygen(secret.as_ptr(), flat.as_mut_ptr()) }, POINT as i32);
        assert_eq!(flat, pk);
        assert_eq!(unsafe { deal_keygen(std::ptr::null(), flat.as_mut_ptr()) }, -1, "a null secret fails the call");
    }
}
