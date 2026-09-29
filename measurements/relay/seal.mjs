// The dart2js build under node, which is V8 — the engine Chrome runs:
//
//   dart compile js -O2 -o seal.js seal.dart && node seal.mjs
//
// dart2js writes for a browser, where `self` is the global object and
// carries `crypto`. Node has the crypto and not the name, so one line
// makes it browser enough to run this, and nothing in the measurement
// is a shim.
import { createRequire } from 'node:module';

globalThis.self = globalThis;
createRequire(import.meta.url)('./seal.js');
