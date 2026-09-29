// The wasm Schnorr as a small JS API: load once, then sign(sk, msg, aux)
// and verify(pk, msg, sig) over Uint8Arrays. Shared by bench.html (in
// the browser) and check.mjs (under node).
export async function loadSchnorr(bytes) {
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const { memory, alloc, reset, sign, verify } = instance.exports;
  reset();
  const sk = alloc(32), msg = alloc(32), aux = alloc(32), sig = alloc(64), pk = alloc(32);
  const mem = () => new Uint8Array(memory.buffer);
  return {
    sign(secret, digest, auxRand) {
      mem().set(secret, sk); mem().set(digest, msg); mem().set(auxRand, aux);
      if (sign(sk, msg, aux, sig) !== 1) throw new Error('sign failed');
      return mem().slice(sig, sig + 64);
    },
    verify(pubkey, digest, signature) {
      mem().set(pubkey, pk); mem().set(digest, msg); mem().set(signature, sig);
      return verify(pk, msg, sig) === 1;
    },
  };
}

export const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, '0')).join('');
export const unhex = (s) => Uint8Array.from(s.match(/../g).map((h) => parseInt(h, 16)));
