//! BIP-340 Schnorr over secp256k1 for the browser, as plain exports on
//! linear memory: no bindgen, no glue. The caller writes the inputs at
//! the offsets it gets from `alloc`, calls, and reads the output.
//!
//! sign(sk, msg, aux, out) — 32-byte secret, 32-byte digest, 32 bytes
//! of auxiliary randomness; writes a 64-byte signature; returns 1 on
//! success. verify(pk, msg, sig) — 32-byte x-only key; returns 1 when
//! the signature is good.
#![no_std]

extern crate alloc;

use alloc::alloc::{alloc as raw_alloc, Layout};
use k256::schnorr::{signature::hazmat::PrehashVerifier, Signature, SigningKey, VerifyingKey};

#[global_allocator]
static ALLOC: dlmalloc_shim::Dl = dlmalloc_shim::Dl;

mod dlmalloc_shim {
    //! The smallest allocator that will do: bump, never free. A call
    //! allocates a few hundred bytes; the page is reset between calls
    //! by the caller reusing the same offsets.
    use core::alloc::{GlobalAlloc, Layout};
    use core::cell::UnsafeCell;
    pub struct Dl;
    const HEAP: usize = 1 << 20;
    struct Heap(UnsafeCell<[u8; HEAP]>, UnsafeCell<usize>);
    unsafe impl Sync for Heap {}
    static H: Heap = Heap(UnsafeCell::new([0; HEAP]), UnsafeCell::new(0));
    unsafe impl GlobalAlloc for Dl {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            let top = &mut *H.1.get();
            let start = (*top + l.align() - 1) & !(l.align() - 1);
            let end = start + l.size();
            if end > HEAP {
                return core::ptr::null_mut();
            }
            *top = end;
            (H.0.get() as *mut u8).add(start)
        }
        unsafe fn dealloc(&self, _p: *mut u8, _l: Layout) {}
    }
    impl Dl {
        pub fn reset() {
            unsafe { *H.1.get() = 0 }
        }
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

/// A scratch buffer for the caller: `n` bytes, 8-aligned, stable until
/// the next `reset`.
#[no_mangle]
pub extern "C" fn alloc(n: usize) -> *mut u8 {
    unsafe { raw_alloc(Layout::from_size_align_unchecked(n, 8)) }
}

/// Forgets every allocation since the last reset (the caller's scratch
/// buffers included): call once per batch, not per call.
#[no_mangle]
pub extern "C" fn reset() {
    dlmalloc_shim::Dl::reset();
}

#[no_mangle]
pub extern "C" fn sign(sk: *const u8, msg: *const u8, aux: *const u8, out: *mut u8) -> i32 {
    let (sk, msg, aux) = unsafe {
        (
            core::slice::from_raw_parts(sk, 32),
            core::slice::from_raw_parts(msg, 32),
            core::slice::from_raw_parts(aux, 32),
        )
    };
    let Ok(key) = SigningKey::from_bytes(sk) else { return 0 };
    let Ok(sig) = key.sign_raw(msg, aux.try_into().unwrap()) else { return 0 };
    let bytes = sig.to_bytes();
    unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr(), out, 64) };
    1
}

#[no_mangle]
pub extern "C" fn verify(pk: *const u8, msg: *const u8, sig: *const u8) -> i32 {
    let (pk, msg, sig) = unsafe {
        (
            core::slice::from_raw_parts(pk, 32),
            core::slice::from_raw_parts(msg, 32),
            core::slice::from_raw_parts(sig, 64),
        )
    };
    let Ok(key) = VerifyingKey::from_bytes(pk) else { return 0 };
    let Ok(sig) = Signature::try_from(sig) else { return 0 };
    key.verify_prehash(msg, &sig).is_ok() as i32
}
