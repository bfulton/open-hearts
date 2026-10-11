// A certificate chain shaped like the App Store's — a P-384 root, an
// intermediate carrying Apple's WWDR mark, a P-256 leaf carrying the
// App Store's signing mark — and the variants store.test.mjs holds the
// chain check to, made fresh with new keys each time the tests load,
// so no key is kept in the repository. "Not Apple" is in every name.
// Beside them, Apple's real WWDR G6 intermediate, which the pinned
// root must verify.
//
// Each certificate is base64 DER, as an x5c entry carries it; the
// leaf's key is PKCS#8 PEM.

const enc = new TextEncoder();
const concat = (parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
};
const lengthOf = (n) => {
  if (n < 0x80) return [n];
  const bytes = [];
  for (; n; n = Math.floor(n / 256)) bytes.unshift(n & 0xff);
  return [0x80 | bytes.length, ...bytes];
};

// ---- as much DER as a certificate needs ----------------------------------

const tlv = (tag, ...parts) => {
  const body = concat(parts);
  return concat([Uint8Array.of(tag, ...lengthOf(body.length)), body]);
};
const seq = (...parts) => tlv(0x30, ...parts);
const set = (...parts) => tlv(0x31, ...parts);
const bool = (yes) => tlv(0x01, Uint8Array.of(yes ? 0xff : 0));
const octets = (bytes) => tlv(0x04, bytes);
const nothing = Uint8Array.of(0x05, 0x00);

function oid(text) {
  const [a, b, ...rest] = text.split('.').map(Number);
  const bytes = [40 * a + b];
  for (const v of rest) {
    const part = [v & 0x7f];
    for (let x = Math.floor(v / 128); x; x = Math.floor(x / 128)) part.unshift((x & 0x7f) | 0x80);
    bytes.push(...part);
  }
  return tlv(0x06, Uint8Array.from(bytes));
}

/// A non-negative INTEGER from big-endian [bytes].
function int(bytes) {
  let b = Uint8Array.from(bytes);
  let i = 0;
  while (i < b.length - 1 && b[i] === 0 && !(b[i + 1] & 0x80)) i++;
  b = b.subarray(i);
  return tlv(0x02, b[0] & 0x80 ? concat([Uint8Array.of(0), b]) : b);
}

function time(ms) {
  const d = new Date(ms);
  const two = (n) => String(n).padStart(2, '0');
  const rest = `${two(d.getUTCMonth() + 1)}${two(d.getUTCDate())}${two(d.getUTCHours())}${two(d.getUTCMinutes())}${two(d.getUTCSeconds())}Z`;
  const y = d.getUTCFullYear();
  return y < 2050 ? tlv(0x17, enc.encode(String(y).slice(2) + rest)) : tlv(0x18, enc.encode(String(y) + rest));
}

const named = (...parts) => seq(...parts.map(([type, value]) => set(seq(oid(type), tlv(0x0c, enc.encode(value))))));
const CN = '2.5.4.3';
const OU = '2.5.4.11';
const O = '2.5.4.10';

const HASH_OF = { 'P-256': 'SHA-256', 'P-384': 'SHA-384' };
const ECDSA_WITH = { 'SHA-256': '1.2.840.10045.4.3.2', 'SHA-384': '1.2.840.10045.4.3.3' };

const extension = (type, value, critical = false) => seq(oid(type), ...(critical ? [bool(true)] : []), octets(value));
const ca = (yes) => extension('2.5.29.19', yes ? seq(bool(true)) : seq(), true);
const WWDR_MARK = extension('1.2.840.113635.100.6.2.1', nothing);
const STORE_MARK = extension('1.2.840.113635.100.6.11.1', nothing);

const pair = (curve) => crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: curve }, true, ['sign', 'verify']);

let serial = 1;

/// A certificate for [key] under [subject], signed by [by] (a pair and
/// its curve) as [issuer], good from [from] to [to].
async function certificate({ subject, issuer, key, by, curve, from, to, extensions }) {
  const hash = HASH_OF[curve];
  const algorithm = seq(oid(ECDSA_WITH[hash]));
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', key.publicKey));
  const tbs = seq(tlv(0xa0, int([2])), int([0, serial++]), algorithm, issuer, seq(time(from), time(to)), subject, spki, tlv(0xa3, seq(...extensions)));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash }, by.privateKey, tbs));
  const half = raw.length / 2;
  const signature = seq(int(raw.subarray(0, half)), int(raw.subarray(half)));
  return Buffer.from(seq(tbs, algorithm, tlv(0x03, Uint8Array.of(0), signature))).toString('base64');
}

// ---- the chain, and what is wrong with each variant ---------------------

const DAY = 86400000;
const now = Date.now();
const [rootKey, otherKey, midKey, leafPair] = await Promise.all([pair('P-384'), pair('P-384'), pair('P-384'), pair('P-256')]);

const rootName = named([CN, 'Test Root CA - G3'], [O, 'Not Apple']);
const midName = named([CN, 'Test WWDR'], [OU, 'G6'], [O, 'Not Apple']);
const leafName = named([CN, 'Test App Store Signing'], [O, 'Not Apple']);

const asRoot = (key) => ({ subject: rootName, issuer: rootName, key, by: key, curve: 'P-384', from: now - 30 * DAY, to: now + 7000 * DAY, extensions: [ca(true)] });
const underRoot = (extra) => ({ subject: midName, issuer: rootName, key: midKey, by: rootKey, curve: 'P-384', from: now - 20 * DAY, to: now + 5000 * DAY, ...extra });
const underMid = (extensions) => ({ subject: leafName, issuer: midName, key: leafPair, by: midKey, curve: 'P-384', from: now - 10 * DAY, to: now + 3000 * DAY, extensions });

export const root = await certificate(asRoot(rootKey));
/// A root of the same name and another key.
export const other = await certificate(asRoot(otherKey));
export const mid = await certificate(underRoot({ extensions: [ca(true), WWDR_MARK] }));
export const midplain = await certificate(underRoot({ extensions: [ca(true)] }));
export const midother = await certificate(underRoot({ by: otherKey, extensions: [ca(true), WWDR_MARK] }));
export const midnotca = await certificate(underRoot({ extensions: [ca(false), WWDR_MARK] }));
export const midrenamed = await certificate(underRoot({ subject: named([CN, 'Test WWDR Renamed'], [O, 'Not Apple']), extensions: [ca(true), WWDR_MARK] }));
export const leaf = await certificate(underMid([ca(false), STORE_MARK]));
export const leafplain = await certificate(underMid([ca(false)]));
export const leafKey = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(await crypto.subtle.exportKey('pkcs8', leafPair.privateKey)).toString('base64')}\n-----END PRIVATE KEY-----`;

export const appleWwdrG6 = 'MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=';
