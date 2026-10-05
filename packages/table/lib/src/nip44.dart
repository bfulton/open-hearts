/// NIP-44 version 2: a message sealed to one key, readable by the two
/// ends of a shared secret and nobody else.
///
/// What a relay carries of WebRTC signalling — an offer, an
/// answer, an ICE candidate with a player's address in it — is sealed
/// this way to the recipient's table key (relay_transport.dart). The
/// scheme is the one Nostr clients use for direct messages, so it is
/// specified, vectored and reviewed elsewhere: a conversation key from
/// the ECDH point of the two keys, per-message keys by HKDF from a
/// random nonce, ChaCha20 over the padded text, an HMAC over nonce and
/// ciphertext. Written out here in Dart — the ciphers are short and
/// the app already carries SHA-256 — and pinned to the published
/// vectors in test/nip44_test.dart.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

abstract final class Nip44 {
  static const version = 2;
  static const minPlaintext = 1;
  static const maxPlaintext = 65535;

  /// The conversation key of two ends: HKDF-extract, salted with the
  /// scheme's name, of the x coordinate of their shared point.
  static Uint8List conversationKey(Uint8List sharedX) {
    if (sharedX.length != 32) throw ArgumentError('a shared point is 32 bytes');
    return _hmac(Uint8List.fromList(utf8.encode('nip44-v2')), sharedX);
  }

  /// The keys of one message: 76 bytes of HKDF-expand with the nonce
  /// as info — a ChaCha20 key, its nonce, and an HMAC key.
  static ({Uint8List chachaKey, Uint8List chachaNonce, Uint8List hmacKey}) messageKeys(Uint8List conversationKey, Uint8List nonce) {
    if (conversationKey.length != 32) throw ArgumentError('a conversation key is 32 bytes');
    if (nonce.length != 32) throw ArgumentError('a nonce is 32 bytes');
    final okm = _hkdfExpand(conversationKey, nonce, 76);
    return (
      chachaKey: Uint8List.sublistView(okm, 0, 32),
      chachaNonce: Uint8List.sublistView(okm, 32, 44),
      hmacKey: Uint8List.sublistView(okm, 44, 76),
    );
  }

  /// How long [length] bytes of text are once padded: 32 up to 32,
  /// then to a multiple of a chunk that grows with the text.
  static int paddedLength(int length) {
    if (length < minPlaintext) throw ArgumentError('a text is at least one byte');
    if (length <= 32) return 32;
    final nextPower = 1 << ((length - 1).bitLength);
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * ((length - 1) ~/ chunk + 1);
  }

  /// Seals [plaintext] under [conversationKey]: base64 of the version,
  /// a fresh nonce, the ciphertext and its MAC. A [nonce] given is for
  /// a test against a vector.
  static String encrypt(Uint8List conversationKey, String plaintext, {Uint8List? nonce, Random? random}) {
    final text = Uint8List.fromList(utf8.encode(plaintext));
    final n = nonce ?? _randomBytes(32, random ?? Random.secure());
    if (n.length != 32) throw ArgumentError('a nonce is 32 bytes');
    final keys = messageKeys(conversationKey, n);
    final padded = _pad(text);
    final ciphertext = _chacha20(keys.chachaKey, keys.chachaNonce, padded);
    final mac = _hmac(keys.hmacKey, Uint8List.fromList([...n, ...ciphertext]));
    return base64.encode([version, ...n, ...ciphertext, ...mac]);
  }

  /// Opens a payload sealed under [conversationKey]. Throws a
  /// [FormatException] for anything that is not a sound message from
  /// the other end: a version this does not speak, a length out of
  /// range, a MAC that does not hold, padding that does not add up.
  static String decrypt(Uint8List conversationKey, String payload) {
    if (payload.isEmpty || payload.length < 132 || payload.length > 87472) {
      throw const FormatException('nip44: payload length out of range');
    }
    if (payload.startsWith('#')) throw const FormatException('nip44: unknown version');
    Uint8List bytes;
    try {
      bytes = base64.decode(payload);
    } on FormatException {
      throw const FormatException('nip44: not base64');
    }
    if (bytes.length < 99 || bytes.length > 65603) throw const FormatException('nip44: payload length out of range');
    if (bytes[0] != version) throw const FormatException('nip44: unknown version');
    final n = Uint8List.sublistView(bytes, 1, 33);
    final ciphertext = Uint8List.sublistView(bytes, 33, bytes.length - 32);
    final mac = Uint8List.sublistView(bytes, bytes.length - 32);
    final keys = messageKeys(conversationKey, n);
    final expected = _hmac(keys.hmacKey, Uint8List.fromList([...n, ...ciphertext]));
    if (!_constantTimeEquals(expected, mac)) throw const FormatException('nip44: invalid MAC');
    final padded = _chacha20(keys.chachaKey, keys.chachaNonce, ciphertext);
    return utf8.decode(_unpad(padded));
  }

  // ---- padding ----------------------------------------------------------

  static Uint8List _pad(Uint8List text) {
    final length = text.length;
    if (length < minPlaintext || length > maxPlaintext) throw ArgumentError('a text is 1 to 65535 bytes, not $length');
    final out = Uint8List(2 + paddedLength(length));
    out[0] = length >> 8;
    out[1] = length & 0xff;
    out.setRange(2, 2 + length, text);
    return out;
  }

  static Uint8List _unpad(Uint8List padded) {
    if (padded.length < 2) throw const FormatException('nip44: invalid padding');
    final length = (padded[0] << 8) | padded[1];
    if (length < minPlaintext || length > maxPlaintext) throw const FormatException('nip44: invalid padding');
    if (padded.length != 2 + paddedLength(length)) throw const FormatException('nip44: invalid padding');
    return Uint8List.sublistView(padded, 2, 2 + length);
  }

  // ---- keys -------------------------------------------------------------

  static Uint8List _hmac(Uint8List key, Uint8List data) => Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

  /// HKDF-expand with SHA-256: T(i) = HMAC(prk, T(i-1) || info || i).
  static Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
    final out = BytesBuilder(copy: false);
    var last = Uint8List(0);
    for (var i = 1; out.length < length; i++) {
      last = _hmac(prk, Uint8List.fromList([...last, ...info, i]));
      out.add(last);
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }

  static Uint8List _randomBytes(int n, Random random) => Uint8List.fromList([for (var i = 0; i < n; i++) random.nextInt(256)]);

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ---- ChaCha20 (RFC 8439): a 32-byte key, a 12-byte nonce, the block
  // counter from zero. ---------------------------------------------------

  static Uint8List _chacha20(Uint8List key, Uint8List nonce, Uint8List data) {
    if (key.length != 32 || nonce.length != 12) throw ArgumentError('chacha20: a 32-byte key and a 12-byte nonce');
    final out = Uint8List(data.length);
    final state = Uint32List(16);
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    final k = ByteData.sublistView(key);
    for (var i = 0; i < 8; i++) {
      state[4 + i] = k.getUint32(i * 4, Endian.little);
    }
    final nd = ByteData.sublistView(nonce);
    state[13] = nd.getUint32(0, Endian.little);
    state[14] = nd.getUint32(4, Endian.little);
    state[15] = nd.getUint32(8, Endian.little);
    final block = Uint32List(16);
    final stream = Uint8List(64);
    final sd = ByteData.sublistView(stream);
    for (var offset = 0, counter = 0; offset < data.length; offset += 64, counter++) {
      state[12] = counter;
      block.setAll(0, state);
      for (var round = 0; round < 10; round++) {
        _quarter(block, 0, 4, 8, 12);
        _quarter(block, 1, 5, 9, 13);
        _quarter(block, 2, 6, 10, 14);
        _quarter(block, 3, 7, 11, 15);
        _quarter(block, 0, 5, 10, 15);
        _quarter(block, 1, 6, 11, 12);
        _quarter(block, 2, 7, 8, 13);
        _quarter(block, 3, 4, 9, 14);
      }
      for (var i = 0; i < 16; i++) {
        sd.setUint32(i * 4, (block[i] + state[i]) & 0xffffffff, Endian.little);
      }
      final n = min(64, data.length - offset);
      for (var i = 0; i < n; i++) {
        out[offset + i] = data[offset + i] ^ stream[i];
      }
    }
    return out;
  }

  static void _quarter(Uint32List s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl(s[b] ^ s[c], 7);
  }

  // A logical shift right: on the web an int past 2^31 would otherwise
  // sign-extend.
  static int _rotl(int x, int n) => ((x << n) & 0xffffffff) | (x >>> (32 - n));
}
