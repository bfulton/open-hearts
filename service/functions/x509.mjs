// Certificates, as little of X.509 as the App Store's chain needs.

import { un64 } from './rows.mjs';

/// One DER element at [at]: its tag, where its content starts and ends.
function derAt(b, at) {
  if (at + 2 > b.length) throw new Error('short');
  const tag = b[at];
  let len = b[at + 1];
  let body = at + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4) throw new Error('length');
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[body++];
  }
  const end = body + len;
  if (end > b.length) throw new Error('overrun');
  return { tag, start: at, body, end };
}

function derKids(b, node) {
  const out = [];
  for (let at = node.body; at < node.end; ) {
    const kid = derAt(b, at);
    out.push(kid);
    at = kid.end;
  }
  return out;
}

function oidOf(b, node) {
  if (node.tag !== 0x06) throw new Error('not an oid');
  const parts = [Math.floor(b[node.body] / 40), b[node.body] % 40];
  let v = 0;
  for (let i = node.body + 1; i < node.end; i++) {
    v = v * 128 + (b[i] & 0x7f);
    if (!(b[i] & 0x80)) {
      parts.push(v);
      v = 0;
    }
  }
  return parts.join('.');
}

function timeOf(b, node) {
  const t = new TextDecoder().decode(b.subarray(node.body, node.end));
  const m = node.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(t) : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(t);
  if (!m) throw new Error('time');
  let y = Number(m[1]);
  if (node.tag === 0x17) y += y < 50 ? 2000 : 1900;
  return Date.UTC(y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
}

const CURVES = { '1.2.840.10045.3.1.7': { namedCurve: 'P-256', size: 32 }, '1.3.132.0.34': { namedCurve: 'P-384', size: 48 } };
const ECDSA_WITH = { '1.2.840.10045.4.3.2': 'SHA-256', '1.2.840.10045.4.3.3': 'SHA-384' };

/// A certificate, read for what a chain check needs; throws on anything
/// it cannot read, which is a certificate that is not taken.
export function certOf(der) {
  const b = der instanceof Uint8Array ? der : new Uint8Array(der);
  const cert = derAt(b, 0);
  if (cert.end !== b.length) throw new Error('trailing');
  const [tbs, sigAlg, sigVal] = derKids(b, cert);
  const t = derKids(b, tbs);
  let i = t[0].tag === 0xa0 ? 1 : 0;
  i++; // serial
  i++; // the signature algorithm again
  const issuer = t[i++];
  const validity = derKids(b, t[i++]);
  const subject = t[i++];
  const spki = t[i++];
  const [keyAlg] = derKids(b, spki);
  const [, curveOid] = derKids(b, keyAlg);
  const extensions = new Map();
  const ext = t.find((n) => n.tag === 0xa3);
  if (ext) {
    for (const e of derKids(b, derKids(b, ext)[0])) {
      const parts = derKids(b, e);
      extensions.set(oidOf(b, parts[0]), b.subarray(parts.at(-1).body, parts.at(-1).end));
    }
  }
  // basicConstraints: SEQUENCE { cA BOOLEAN DEFAULT FALSE, ... }
  let ca = false;
  const bc = extensions.get('2.5.29.19');
  if (bc && bc.length > 2) {
    const seq = derAt(bc, 0);
    const first = derKids(bc, seq)[0];
    ca = !!first && first.tag === 0x01 && bc[first.body] !== 0;
  }
  return {
    tbs: b.subarray(tbs.start, tbs.end),
    sigHash: ECDSA_WITH[oidOf(b, derKids(b, sigAlg)[0])] ?? null,
    signature: b.subarray(sigVal.body + 1, sigVal.end),
    spki: b.subarray(spki.start, spki.end),
    curve: CURVES[oidOf(b, curveOid)] ?? null,
    issuer: b.subarray(issuer.start, issuer.end),
    subject: b.subarray(subject.start, subject.end),
    notBefore: timeOf(b, validity[0]),
    notAfter: timeOf(b, validity[1]),
    extensions,
    ca,
  };
}

/// An ECDSA signature as DER (SEQUENCE of r and s) to the r‖s WebCrypto
/// verifies, each padded to the curve's [size].
function rawSignature(der, size) {
  const seq = derAt(der, 0);
  const out = new Uint8Array(size * 2);
  derKids(der, seq).forEach((n, k) => {
    let v = der.subarray(n.body, n.end);
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new Error('integer');
    out.set(v, k * size + size - v.length);
  });
  return out;
}

const sameBytes = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

/// Whether [child] was signed by [parent]'s key, and names it as issuer.
export async function signedBy(child, parent) {
  if (!child.sigHash || !parent.curve || !sameBytes(child.issuer, parent.subject)) return false;
  try {
    const key = await crypto.subtle.importKey('spki', parent.spki, { name: 'ECDSA', namedCurve: parent.curve.namedCurve }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: child.sigHash }, key, rawSignature(child.signature, parent.curve.size), child.tbs);
  } catch {
    return false;
  }
}

/// Apple Root CA - G3, as Apple publishes it
/// (apple.com/certificateauthority/AppleRootCA-G3.cer; SHA-256
/// 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79).
export const APPLE_ROOT_G3 = Uint8Array.from(atob('MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA=='), (c) => c.charCodeAt(0));

/// The roots an App Store chain may end at: Apple's, unless a test says
/// otherwise — no test can make a certificate Apple signed.
let appleRoots = [APPLE_ROOT_G3];
export const trustAppleRoots = (roots) => (appleRoots = roots);
export const forgetAppleRoots = () => (appleRoots = [APPLE_ROOT_G3]);

/// Apple marks the certificates it signs the App Store's data with:
/// the WWDR intermediate, and the leaf that signs.
const APPLE_INTERMEDIATE = '1.2.840.113635.100.6.2.1';
const APPLE_STORE_LEAF = '1.2.840.113635.100.6.11.1';

/// What an App Store JWS says, once its chain ends at one of [roots] and
/// its signature is the leaf's; null when it does not check out. The
/// certificates are checked at the moment the payload says it was
/// signed, which is how Apple's own library checks them: what Apple
/// signed while a certificate was good stays signed after it expires.
export async function appleSigned(jws, { roots = appleRoots, now = Date.now() } = {}) {
  try {
    const parts = String(jws ?? '').split('.');
    if (parts.length !== 3) return null;
    const header = JSON.parse(new TextDecoder().decode(un64(parts[0])));
    if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) return null;
    const ders = header.x5c.map((c) => Uint8Array.from(atob(c), (ch) => ch.charCodeAt(0)));
    if (!roots.some((r) => sameBytes(r, ders[2]))) return null;
    const [leaf, middle, root] = ders.map(certOf);
    const payload = JSON.parse(new TextDecoder().decode(un64(parts[1])));
    const at = Number.isFinite(payload.signedDate) ? payload.signedDate : now;
    // Not signed in the future, whatever the payload claims.
    if (at > now + 5 * 60000) return null;
    for (const c of [leaf, middle, root]) if (at < c.notBefore || at > c.notAfter) return null;
    if (!middle.ca || !middle.extensions.has(APPLE_INTERMEDIATE) || !leaf.extensions.has(APPLE_STORE_LEAF)) return null;
    if (!(await signedBy(middle, root)) || !(await signedBy(leaf, middle))) return null;
    if (leaf.curve?.namedCurve !== 'P-256') return null;
    const key = await crypto.subtle.importKey('spki', leaf.spki, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, un64(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    return ok ? payload : null;
  } catch {
    return null;
  }
}

/// A checked App Store transaction, as this service reads it: the
/// subscription, when it runs to, whether it has ended, and whom it
/// was bought for. {status, body} when it is not one of ours.
export async function appleTransaction(jws, env, { roots, now = Date.now() } = {}) {
  const bundle = env.OH_APPLE_BUNDLE_ID;
  const product = env.OH_APPLE_PRODUCT;
  if (!bundle || !product) return { status: 503, body: { error: 'the store is not set up yet' } };
  const t = await appleSigned(jws, { roots, now });
  if (!t) return { status: 401, body: { error: 'not from the store' } };
  // Another app's, another product's, or not a subscription at all.
  if (t.bundleId !== bundle || t.productId !== product || t.type !== 'Auto-Renewable Subscription') {
    return { status: 401, body: { error: 'not from the store' } };
  }
  if (typeof t.originalTransactionId !== 'string' || !/^\d{1,32}$/.test(t.originalTransactionId) || !Number.isFinite(t.expiresDate)) {
    return { status: 401, body: { error: 'not from the store' } };
  }
  return {
    subscription: `apple:${t.originalTransactionId}`,
    until: t.expiresDate,
    gone: t.revocationDate != null,
    account: typeof t.appAccountToken === 'string' ? t.appAccountToken.toLowerCase() : null,
    created: Number.isFinite(t.signedDate) ? Math.floor(t.signedDate / 1000) : null,
    txn_ref: typeof t.transactionId === 'string' ? t.transactionId : null,
  };
}
