// Signing, for the tests only: a relay never signs anything, but a
// test has to be a client, and a client's every event is signed.
//
// The keys are BIP-340's own test vectors. A secret key alone is no
// use here — the wasm signs and verifies and does not derive a public
// key, and deriving one would mean a second implementation of the
// curve — so the pairs come from the specification, where they are
// published together.

import { idOf } from './relay.mjs';

/// Secret and public keys from BIP-340's test vectors, in the order
/// they appear there. Four is more people than any test here seats.
export const keys = [
  {
    secret: '0000000000000000000000000000000000000000000000000000000000000003',
    public: 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9',
  },
  {
    secret: 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef',
    public: 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659',
  },
  {
    secret: 'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9',
    public: 'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8',
  },
  {
    secret: '0b432b2677937381aef05bb02a66ecd012773062cf3fa2549e44f58ed2401710',
    public: '25d1dff95105f5253c4022f628a996ad3a0d95fbf21d468a1b33f8c160d8f517',
  },
];

/// A signer over the same wasm the relay verifies with.
export async function signing(bytes) {
  const { memory, alloc, reset, sign } = (await WebAssembly.instantiate(bytes, {})).instance.exports;
  reset();
  const sk = alloc(32);
  const msg = alloc(32);
  const aux = alloc(32);
  const sig = alloc(64);
  const put = (at, hex) => {
    const mem = new Uint8Array(memory.buffer);
    for (let i = 0; i < hex.length; i += 2) mem[at + i / 2] = parseInt(hex.slice(i, i + 2), 16);
  };
  return {
    /// A signed event, the way NIP-01 builds one: the id is the hash of
    /// what it carries, and the signature is over the id.
    async event(key, { kind, content = '', tags = [], created_at = 1000 }) {
      const id = await idOf(key.public, created_at, kind, tags, content);
      put(sk, key.secret);
      put(msg, id);
      put(aux, '0'.repeat(64));
      if (sign(sk, msg, aux, sig) !== 1) throw new Error('sign failed');
      const bytes = new Uint8Array(memory.buffer).slice(sig, sig + 64);
      return {
        id,
        pubkey: key.public,
        created_at,
        kind,
        tags,
        content,
        sig: [...bytes].map((b) => b.toString(16).padStart(2, '0')).join(''),
      };
    },
  };
}
