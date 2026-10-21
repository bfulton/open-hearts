// The PhotoDNA module, as this repository builds the relay: none. The
// module that makes a picture's PhotoDNA Edge Hashes is Microsoft's,
// licensed to Open Hearts under terms that keep it confidential, so it
// is not here: the relay's deploy fetches it from where it is kept
// privately and builds with it in this one's place (`oh deploy relay`,
// ops/photodna.mjs; wrangler.toml, `alias`). Everywhere else — the
// tests, CI, anyone's clone — the relay builds with this, and asks
// PhotoDNA nothing (known.mjs).
//
// What the module exports in its place: edgeHashes(rgb, width, height),
// the picture's hashes, base64, at most five; [] for a picture of one
// colour; throwing an error with `unhashable` set for a picture too
// small to hash, and one without for anything else.

export const edgeHashes = null;
