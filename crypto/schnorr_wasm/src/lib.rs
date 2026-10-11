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
static ALLOC: bump::Bump = bump::Bump;

mod bump {
    //! The smallest allocator that will do: a megabyte, handed out from
    //! the bottom up and never freed one piece at a time. `sign` and
    //! `verify` allocate nothing on it (twenty thousand of each leave
    //! the top where it was); what it holds is the caller's scratch
    //! buffers, and [`Bump::reset`] starts it over.
    use core::alloc::{GlobalAlloc, Layout};
    use core::cell::UnsafeCell;
    pub struct Bump;
    const HEAP: usize = 1 << 20;
    struct Heap(UnsafeCell<[u8; HEAP]>, UnsafeCell<usize>);
    // Wasm here is one thread: nothing shares the heap.
    unsafe impl Sync for Heap {}
    static H: Heap = Heap(UnsafeCell::new([0; HEAP]), UnsafeCell::new(0));
    unsafe impl GlobalAlloc for Bump {
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
    impl Bump {
        /// # Safety
        ///
        /// Nothing allocated before it may be used after it.
        pub unsafe fn reset() {
            *H.1.get() = 0;
        }
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

/// A scratch buffer for the caller: `n` bytes, 8-aligned, stable until
/// the next `reset`; null when there is no room.
#[no_mangle]
pub extern "C" fn alloc(n: usize) -> *mut u8 {
    match Layout::from_size_align(n, 8) {
        Ok(layout) if n > 0 => unsafe { raw_alloc(layout) },
        _ => core::ptr::null_mut(),
    }
}

/// Forgets every allocation since the last reset, the caller's scratch
/// buffers included: callers reset once, when they load the module.
///
/// # Safety
///
/// No buffer from before it may be used after it.
#[no_mangle]
pub unsafe extern "C" fn reset() {
    bump::Bump::reset();
}

/// # Safety
///
/// `sk`, `msg` and `aux` point to 32 readable bytes each, and `out` to
/// 64 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn sign(sk: *const u8, msg: *const u8, aux: *const u8, out: *mut u8) -> i32 {
    let sk = core::slice::from_raw_parts(sk, 32);
    let msg = core::slice::from_raw_parts(msg, 32);
    let aux: &[u8; 32] = &*(aux as *const [u8; 32]);
    let Ok(key) = SigningKey::from_bytes(sk) else { return 0 };
    let Ok(sig) = key.sign_raw(msg, aux) else { return 0 };
    core::ptr::copy_nonoverlapping(sig.to_bytes().as_ptr(), out, 64);
    1
}

/// # Safety
///
/// `pk` and `msg` point to 32 readable bytes each, and `sig` to 64.
#[no_mangle]
pub unsafe extern "C" fn verify(pk: *const u8, msg: *const u8, sig: *const u8) -> i32 {
    let pk = core::slice::from_raw_parts(pk, 32);
    let msg = core::slice::from_raw_parts(msg, 32);
    let sig = core::slice::from_raw_parts(sig, 64);
    let Ok(key) = VerifyingKey::from_bytes(pk) else { return 0 };
    let Ok(sig) = Signature::try_from(sig) else { return 0 };
    key.verify_prehash(msg, &sig).is_ok() as i32
}
